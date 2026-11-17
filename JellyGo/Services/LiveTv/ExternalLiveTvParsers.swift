import Foundation
import zlib

// Pure, actor-free logic for external Live TV lists: M3U playlists, XMLTV guides, gzip,
// and channel ↔ guide matching. Everything here runs off the main thread.

// MARK: - Models

nonisolated struct M3UChannel: Codable, Hashable, Sendable {
    var name: String
    var url: String
    var tvgId: String?
    var tvgName: String?
    var tvgLogo: String?
    var groupTitle: String?
    var channelNumber: String?
    var userAgent: String?
    var referrer: String?
}

nonisolated struct M3UPlaylist: Sendable {
    var channels: [M3UChannel] = []
    /// Guide addresses announced by the playlist header (`url-tvg` / `x-tvg-url`).
    var epgURLs: [String] = []
    /// Entries skipped because they point at movies / series (VOD), not live channels.
    var skippedVOD = 0
    /// `#EXTINF` lines without a stream address, or address lines that are not URLs.
    var malformedLines = 0
}

nonisolated struct EPGProgram: Codable, Hashable, Sendable {
    var start: Date
    var stop: Date
    var title: String
    var subtitle: String?
    var desc: String?
}

// MARK: - M3U

nonisolated enum M3UParser {

    /// File extensions / path segments that mark VOD entries (movies, series episodes).
    private static let vodExtensions: Set<String> = ["mp4", "mkv", "avi", "mov", "m4v", "wmv", "webm", "mpg", "mpeg"]
    private static let vodPathMarkers = ["/movie/", "/movies/", "/series/", "/vod/"]

    static func parse(data: Data) -> M3UPlaylist {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        let text = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .isoLatin1)
            ?? ""
        return parse(text: text)
    }

    static func parse(text: String) -> M3UPlaylist {
        var result = M3UPlaylist()
        var pendingInfo: (attrs: [String: String], name: String)?
        var pendingUA: String?
        var pendingReferrer: String?
        var pendingGroup: String?

        // `\r\n` is a single Character in Swift, so split on `isNewline`, not on "\n".
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if hasPrefixCI(line, "#EXTM3U") {
                    let attrs = parseAttributes(Substring(line.dropFirst(7)))
                    for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                        if let v = attrs[key] {
                            for part in v.split(separator: ",") {
                                let u = part.trimmingCharacters(in: .whitespaces)
                                if !u.isEmpty, !result.epgURLs.contains(u) { result.epgURLs.append(u) }
                            }
                        }
                    }
                } else if hasPrefixCI(line, "#EXTINF:") {
                    if pendingInfo != nil { result.malformedLines += 1 }   // previous entry had no URL
                    pendingInfo = parseExtInf(Substring(line.dropFirst(8)))
                } else if hasPrefixCI(line, "#EXTVLCOPT:") {
                    let opt = line.dropFirst(11)
                    if let eq = opt.firstIndex(of: "=") {
                        let key = opt[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                        let value = opt[opt.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        if key == "http-user-agent" { pendingUA = value }
                        if key == "http-referrer" || key == "http-referer" { pendingReferrer = value }
                    }
                } else if hasPrefixCI(line, "#EXTGRP:") {
                    let g = line.dropFirst(8).trimmingCharacters(in: .whitespaces)
                    if !g.isEmpty { pendingGroup = g }
                }
                continue
            }

            // Address line. Kodi style "url|User-Agent=..&Referer=.." carries headers too.
            var address = line
            var pipeUA: String?
            var pipeRef: String?
            if let pipe = address.firstIndex(of: "|") {
                let opts = address[address.index(after: pipe)...]
                address = String(address[..<pipe])
                for pair in opts.split(separator: "&") {
                    guard let eq = pair.firstIndex(of: "=") else { continue }
                    let k = pair[..<eq].lowercased()
                    let v = String(pair[pair.index(after: eq)...]).removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                    if k == "user-agent" { pipeUA = v }
                    if k == "referer" || k == "referrer" { pipeRef = v }
                }
            }

            guard address.contains("://"), URL(string: address) != nil else {
                result.malformedLines += 1
                pendingInfo = nil; pendingUA = nil; pendingReferrer = nil; pendingGroup = nil
                continue
            }

            defer { pendingInfo = nil; pendingUA = nil; pendingReferrer = nil; pendingGroup = nil }

            if isVOD(address) {
                result.skippedVOD += 1
                continue
            }

            let attrs = pendingInfo?.attrs ?? [:]
            var name = pendingInfo?.name ?? ""
            if name.isEmpty { name = attrs["tvg-name"] ?? "" }
            if name.isEmpty {
                name = URL(string: address)?.deletingPathExtension().lastPathComponent ?? address
            }

            result.channels.append(M3UChannel(
                name: name,
                url: address,
                tvgId: nonEmpty(attrs["tvg-id"]),
                tvgName: nonEmpty(attrs["tvg-name"]),
                tvgLogo: nonEmpty(attrs["tvg-logo"]),
                groupTitle: nonEmpty(attrs["group-title"]) ?? pendingGroup,
                channelNumber: nonEmpty(attrs["tvg-chno"]) ?? nonEmpty(attrs["channel-number"]),
                userAgent: pipeUA ?? pendingUA ?? nonEmpty(attrs["user-agent"]),
                referrer: pipeRef ?? pendingReferrer
            ))
        }
        if pendingInfo != nil { result.malformedLines += 1 }
        return result
    }

    static func isVOD(_ address: String) -> Bool {
        let lower = address.lowercased()
        let pathPart: Substring
        if let q = lower.firstIndex(where: { $0 == "?" || $0 == "#" }) { pathPart = lower[..<q] } else { pathPart = Substring(lower) }
        for marker in vodPathMarkers where pathPart.contains(marker) { return true }
        if let dot = pathPart.lastIndex(of: "."), let slash = pathPart.lastIndex(of: "/"), dot > slash {
            let ext = String(pathPart[pathPart.index(after: dot)...])
            if vodExtensions.contains(ext) { return true }
        }
        return false
    }

    /// `-1 tvg-id="x" group-title="News, World",Channel Name` → attributes + name.
    /// The name starts after the first comma that is not inside quotes.
    static func parseExtInf(_ body: Substring) -> (attrs: [String: String], name: String) {
        var inQuote = false
        var split: Substring.Index?
        var i = body.startIndex
        while i < body.endIndex {
            let c = body[i]
            if c == "\"" { inQuote.toggle() }
            else if c == ",", !inQuote { split = i; break }
            i = body.index(after: i)
        }
        guard let comma = split else {
            return (parseAttributes(body), "")
        }
        let attrs = parseAttributes(body[..<comma])
        let name = body[body.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        return (attrs, name)
    }

    /// Scans `key="value" key2=value2` pairs; keys are lower-cased. Tolerates junk.
    static func parseAttributes(_ s: Substring) -> [String: String] {
        var out: [String: String] = [:]
        var i = s.startIndex
        let end = s.endIndex
        while i < end {
            while i < end, s[i] == " " || s[i] == "\t" { i = s.index(after: i) }
            let keyStart = i
            while i < end, s[i] != "=", s[i] != " ", s[i] != "\t" { i = s.index(after: i) }
            let key = s[keyStart..<i].lowercased()
            guard i < end, s[i] == "=" else { continue }
            i = s.index(after: i)
            var value = ""
            if i < end, s[i] == "\"" {
                i = s.index(after: i)
                let vStart = i
                while i < end, s[i] != "\"" { i = s.index(after: i) }
                value = String(s[vStart..<i])
                if i < end { i = s.index(after: i) }
            } else {
                let vStart = i
                while i < end, s[i] != " ", s[i] != "\t" { i = s.index(after: i) }
                value = String(s[vStart..<i])
            }
            if !key.isEmpty { out[key] = value.trimmingCharacters(in: .whitespaces) }
        }
        return out
    }

    private static func hasPrefixCI(_ s: String, _ prefix: String) -> Bool {
        s.count >= prefix.count && s.prefix(prefix.count).uppercased() == prefix
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}

// MARK: - XMLTV dates

nonisolated enum XMLTVDate {
    /// Parses `YYYYMMDDhhmmss ±hhmm` (seconds, minutes and zone optional; `±hh:mm`, `Z`,
    /// `UTC`/`GMT` accepted). A time without a zone is read as UTC.
    static func parse(_ raw: String) -> Date? {
        let s = Array(raw.utf8)
        var digits: [Int] = []
        var i = 0
        while i < s.count, s[i] >= 48, s[i] <= 57, digits.count < 14 {
            digits.append(Int(s[i]) - 48); i += 1
        }
        guard digits.count >= 8 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int {
            guard from + len <= digits.count else { return 0 }
            var v = 0
            for k in from..<(from + len) { v = v * 10 + digits[k] }
            return v
        }
        let year = num(0, 4), month = num(4, 2), day = num(6, 2)
        let hour = num(8, 2), minute = num(10, 2), second = num(12, 2)
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }

        // Skip fractional seconds / spaces.
        while i < s.count, s[i] == 46 || (s[i] >= 48 && s[i] <= 57) { i += 1 }
        while i < s.count, s[i] == 32 { i += 1 }

        var offsetSeconds = 0
        if i < s.count {
            let c = s[i]
            if c == 43 || c == 45 {   // + / -
                let sign = c == 45 ? -1 : 1
                i += 1
                var tz: [Int] = []
                while i < s.count, tz.count < 4 {
                    if s[i] >= 48, s[i] <= 57 { tz.append(Int(s[i]) - 48) }
                    else if s[i] != 58 { break }   // allow ':'
                    i += 1
                }
                if tz.count >= 2 {
                    let h = tz[0] * 10 + tz[1]
                    let m = tz.count >= 4 ? tz[2] * 10 + tz[3] : 0
                    offsetSeconds = sign * (h * 3600 + m * 60)
                }
            }
        }

        let days = daysFromCivil(year: year, month: month, day: day)
        let utc = days * 86_400 + hour * 3600 + minute * 60 + second - offsetSeconds
        return Date(timeIntervalSince1970: TimeInterval(utc))
    }

    /// Howard Hinnant's days_from_civil: days since 1970-01-01 for a proleptic Gregorian date.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: - Name normalisation / matching

nonisolated enum LiveTvNameMatcher {
    private static let noiseTokens: Set<String> = [
        "hd", "fhd", "uhd", "sd", "hq", "lq", "4k", "8k", "hevc", "h264", "h265", "x264", "x265",
        "1080", "1080p", "1080i", "720", "720p", "2160p", "576p", "480p", "50fps", "60fps", "fps",
        "backup", "raw", "vip", "plus"
    ]

    /// Lower-cased, diacritics folded, bracketed text / country prefix / quality tags removed,
    /// only letters and digits kept. "TR: Show TV HD (Yedek)" → "showtv".
    static func normalize(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "ı", with: "i").replacingOccurrences(of: "İ", with: "i")
        s = s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)

        // Drop bracketed parts: (…) […] {…}
        var cleaned = ""
        var depth = 0
        for ch in s {
            if ch == "(" || ch == "[" || ch == "{" { depth += 1; continue }
            if ch == ")" || ch == "]" || ch == "}" { depth = max(0, depth - 1); continue }
            if depth == 0 { cleaned.append(ch) }
        }
        s = cleaned

        // Country / provider prefix: "tr:", "tr |", "|tr|", "uk -".
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " |"))
        if let sep = trimmed.firstIndex(where: { $0 == ":" || $0 == "|" }) {
            let head = trimmed[..<sep].trimmingCharacters(in: CharacterSet(charactersIn: " |"))
            if head.count >= 2, head.count <= 3, head.allSatisfy(\.isLetter) {
                s = String(trimmed[trimmed.index(after: sep)...])
            }
        }

        let tokens = s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let kept = tokens.filter { !noiseTokens.contains($0) }
        let joined = (kept.isEmpty ? tokens : kept).joined()
        return joined
    }

    /// Stable 64-bit FNV-1a hash (Swift's `hashValue` changes on every launch).
    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return String(h, radix: 16)
    }
}

// MARK: - XMLTV streaming parser

nonisolated struct XMLTVFilter: Sendable {
    /// Lower-cased `tvg-id`s of the channels we have.
    var wantedIds: Set<String>
    /// Normalised channel names (see `LiveTvNameMatcher.normalize`).
    var wantedNames: Set<String>
    var windowStart: Date
    var windowEnd: Date
}

nonisolated struct XMLTVResult: Codable, Sendable {
    /// Programmes per lower-cased XMLTV channel id, sorted by start.
    var programsByChannel: [String: [EPGProgram]] = [:]
    /// Normalised display names per lower-cased XMLTV channel id (kept channels only).
    var namesByChannel: [String: [String]] = [:]
    var totalProgrammes = 0
    var keptProgrammes = 0
    var channelElements = 0

    mutating func merge(_ other: XMLTVResult) {
        for (k, v) in other.programsByChannel { programsByChannel[k, default: []].append(contentsOf: v) }
        for (k, v) in other.namesByChannel {
            var names = namesByChannel[k] ?? []
            for n in v where !names.contains(n) { names.append(n) }
            namesByChannel[k] = names
        }
        totalProgrammes += other.totalProgrammes
        keptProgrammes += other.keptProgrammes
        channelElements += other.channelElements
    }

    /// Sorts each channel's programmes and removes duplicates (same start) from merged guides.
    mutating func finalize() {
        for (k, v) in programsByChannel {
            var seen = Set<Date>()
            let sorted = v.sorted { $0.start < $1.start }.filter { seen.insert($0.start).inserted }
            programsByChannel[k] = sorted
        }
    }
}

/// SAX-style XMLTV reader: memory use depends on what is kept, not on the file size.
nonisolated final class XMLTVParser: NSObject, XMLParserDelegate {
    private let filter: XMLTVFilter
    private var result = XMLTVResult()

    private var acceptedIds = Set<String>()
    private var currentChannelId: String?
    private var currentChannelNames: [String] = []

    private var inProgramme = false
    private var progChannel = ""
    private var progStart: Date?
    private var progStop: Date?
    private var progTitle: String?
    private var progSubtitle: String?
    private var progDesc: String?

    private var capture: String?   // element name whose text is being collected
    private var text = ""

    private static let maxDescLength = 600

    init(filter: XMLTVFilter) {
        self.filter = filter
    }

    static func parse(data: Data, filter: XMLTVFilter) -> (XMLTVResult, Error?) {
        let delegate = XMLTVParser(filter: filter)
        let parser = XMLParser(data: data)
        return delegate.run(parser)
    }

    /// Streams from a file; the file is never loaded into memory as a whole.
    static func parse(fileURL: URL, filter: XMLTVFilter) -> (XMLTVResult, Error?) {
        guard let stream = InputStream(url: fileURL) else {
            return (XMLTVResult(), CocoaError(.fileReadNoSuchFile))
        }
        let delegate = XMLTVParser(filter: filter)
        let parser = XMLParser(stream: stream)
        return delegate.run(parser)
    }

    private func run(_ parser: XMLParser) -> (XMLTVResult, Error?) {
        parser.delegate = self
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        result.finalize()
        // A truncated / slightly broken file still yields everything read so far.
        let err: Error? = ok ? nil : (parser.parserError ?? CocoaError(.fileReadCorruptFile))
        return (result, (result.keptProgrammes > 0 || result.totalProgrammes > 0) ? nil : err)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "channel":
            currentChannelId = attributeDict["id"]?.lowercased()
            currentChannelNames = []
        case "display-name":
            if currentChannelId != nil { capture = elementName; text = "" }
        case "programme":
            result.totalProgrammes += 1
            let ch = (attributeDict["channel"] ?? "").lowercased()
            progChannel = ch
            progStart = attributeDict["start"].flatMap(XMLTVDate.parse)
            progStop = attributeDict["stop"].flatMap(XMLTVDate.parse)
            progTitle = nil; progSubtitle = nil; progDesc = nil
            inProgramme = isWanted(channel: ch) && inWindow(start: progStart, stop: progStop)
        case "title", "sub-title", "desc":
            if inProgramme { capture = elementName; text = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard capture != nil else { return }
        if capture == "desc", text.count > Self.maxDescLength { return }
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "display-name":
            if capture == "display-name" {
                let n = LiveTvNameMatcher.normalize(text)
                if !n.isEmpty { currentChannelNames.append(n) }
            }
            capture = nil
        case "channel":
            result.channelElements += 1
            if let id = currentChannelId {
                if filter.wantedIds.contains(id) || currentChannelNames.contains(where: filter.wantedNames.contains) {
                    acceptedIds.insert(id)
                    result.namesByChannel[id] = currentChannelNames
                }
            }
            currentChannelId = nil
            currentChannelNames = []
        case "title":
            if capture == "title" {
                if progTitle == nil { progTitle = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                capture = nil
            }
        case "sub-title":
            if capture == "sub-title" {
                if progSubtitle == nil { progSubtitle = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                capture = nil
            }
        case "desc":
            if capture == "desc" {
                if progDesc == nil {
                    let d = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    progDesc = d.count > Self.maxDescLength ? String(d.prefix(Self.maxDescLength)) + "…" : d
                }
                capture = nil
            }
        case "programme":
            if inProgramme, let start = progStart, let stop = progStop, let title = progTitle, !title.isEmpty {
                result.programsByChannel[progChannel, default: []].append(
                    EPGProgram(start: start, stop: stop, title: title,
                               subtitle: progSubtitle?.isEmpty == false ? progSubtitle : nil,
                               desc: progDesc?.isEmpty == false ? progDesc : nil))
                result.keptProgrammes += 1
            }
            inProgramme = false
            capture = nil
        default:
            break
        }
    }

    private func isWanted(channel: String) -> Bool {
        if acceptedIds.contains(channel) || filter.wantedIds.contains(channel) { return true }
        // Some guides use the channel name itself as id and list programmes first.
        return filter.wantedNames.contains(LiveTvNameMatcher.normalize(channel))
    }

    private func inWindow(start: Date?, stop: Date?) -> Bool {
        guard let start, let stop, stop > start else { return false }
        return stop > filter.windowStart && start < filter.windowEnd
    }
}

// MARK: - Guide ↔ channel matching

nonisolated enum EPGMatcher {
    /// Returns the guide key (lower-cased XMLTV channel id) for a channel: `tvg-id` first,
    /// then the normalised name (`tvg-name`, then display name).
    static func guideKey(for channel: M3UChannel, guide: XMLTVResult, nameIndex: [String: String]) -> String? {
        if let id = channel.tvgId?.lowercased(), guide.programsByChannel[id] != nil { return id }
        for candidate in [channel.tvgName, channel.name].compactMap({ $0 }) {
            let n = LiveTvNameMatcher.normalize(candidate)
            guard !n.isEmpty else { continue }
            if let key = nameIndex[n], guide.programsByChannel[key] != nil { return key }
            if guide.programsByChannel[n] != nil { return n }
        }
        return nil
    }

    /// normalised display name → guide key (first one wins).
    static func nameIndex(for guide: XMLTVResult) -> [String: String] {
        var index: [String: String] = [:]
        for (key, names) in guide.namesByChannel {
            for n in names where index[n] == nil { index[n] = key }
        }
        // Guides that use the channel name as id ("Show TV").
        for key in guide.programsByChannel.keys {
            let n = LiveTvNameMatcher.normalize(key)
            if !n.isEmpty, index[n] == nil { index[n] = key }
        }
        return index
    }
}

// MARK: - gzip

nonisolated enum Gzip {
    enum GzipError: Error { case badHeader, corrupt, truncated }

    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F && data[data.startIndex + 1] == 0x8B
    }

    static func isGzipFile(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 2)) ?? Data()
        return isGzip(head)
    }

    static func decompress(_ data: Data) throws -> Data {
        var out = Data()
        var offset = 0
        try inflate(read: { max in
            guard offset < data.count else { return nil }
            let n = min(max, data.count - offset)
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }, write: { out.append($0) })
        return out
    }

    /// Streams `src` (gzip) into `dst` in fixed-size chunks; memory use stays flat.
    static func decompressFile(at src: URL, to dst: URL) throws {
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: dst.path, contents: nil)
        let output = try FileHandle(forWritingTo: dst)
        defer { try? output.close() }
        try inflate(read: { max in
            let d = try? input.read(upToCount: max)
            return (d?.isEmpty ?? true) ? nil : d
        }, write: { try output.write(contentsOf: $0) })
    }

    /// zlib in gzip mode (header, CRC and size checked by zlib). Concatenated members are
    /// supported; bytes after the last member that are not a gzip header are ignored.
    private static func inflate(read: (Int) -> Data?, write: (Data) throws -> Void) throws {
        var strm = z_stream()
        guard inflateInit2_(&strm, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw GzipError.corrupt
        }
        defer { inflateEnd(&strm) }

        let outSize = 256 * 1024
        let out = UnsafeMutablePointer<Bytef>.allocate(capacity: outSize)
        defer { out.deallocate() }

        var checkedHeader = false
        var memberEnded = false
        var anyMember = false
        var stop = false

        while !stop, var chunk = read(256 * 1024) {
            if !checkedHeader {
                guard isGzip(chunk) else { throw GzipError.badHeader }
                checkedHeader = true
            }
            try chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let base = raw.bindMemory(to: Bytef.self).baseAddress else { return }
                strm.next_in = base
                strm.avail_in = uInt(raw.count)
                while true {
                    if memberEnded {
                        guard strm.avail_in > 0 else { return }
                        // Another member must start with the gzip magic.
                        if strm.next_in[0] != 0x1F || (strm.avail_in > 1 && strm.next_in[1] != 0x8B) {
                            stop = true
                            return
                        }
                        inflateReset(&strm)
                        memberEnded = false
                    }
                    strm.next_out = out
                    strm.avail_out = uInt(outSize)
                    let status = zlib.inflate(&strm, Z_NO_FLUSH)
                    let produced = outSize - Int(strm.avail_out)
                    if produced > 0 { try write(Data(bytes: out, count: produced)) }
                    switch status {
                    case Z_STREAM_END:
                        memberEnded = true
                        anyMember = true
                    case Z_OK:
                        // Output full → call again; input drained → ask for the next chunk.
                        if strm.avail_in == 0 && strm.avail_out > 0 { return }
                    case Z_BUF_ERROR:
                        if strm.avail_in == 0 { return }
                        throw GzipError.corrupt
                    default:
                        throw GzipError.corrupt
                    }
                }
            }
        }
        if !checkedHeader { throw GzipError.badHeader }
        if !memberEnded && !stop { throw anyMember ? GzipError.corrupt : GzipError.truncated }
    }
}

// MARK: - URL masking (for logs and on-screen labels)

nonisolated enum LiveTvURLMasker {
    private static let secretKeys: Set<String> = ["username", "user", "password", "pass", "pwd", "token",
                                                  "key", "apikey", "api_key", "auth", "secret", "signature", "sig"]

    /// Hides user info, credential-like query values and Xtream-style `/user/pass/` paths.
    static func mask(_ string: String) -> String {
        guard var c = URLComponents(string: string) else { return "•••" }
        if c.user != nil { c.user = "•••" }
        if c.password != nil { c.password = "•••" }
        if let items = c.queryItems {
            c.queryItems = items.map { item in
                secretKeys.contains(item.name.lowercased()) ? URLQueryItem(name: item.name, value: "•••") : item
            }
        }
        // Xtream: /live/<user>/<pass>/<id>.ts or /<user>/<pass>/<id>
        var parts = c.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 4 {
            let firstReal = parts[1] == "live" ? 2 : 1
            if parts.count > firstReal + 2 {
                parts[firstReal] = "•••"
                parts[firstReal + 1] = "•••"
                c.path = parts.joined(separator: "/")
            }
        }
        return c.string?.removingPercentEncoding ?? c.string ?? "•••"
    }

    /// Short label: host plus a masked path, for lists.
    static func shortLabel(_ string: String) -> String {
        guard let c = URLComponents(string: string), let host = c.host else { return mask(string) }
        return host
    }
}
