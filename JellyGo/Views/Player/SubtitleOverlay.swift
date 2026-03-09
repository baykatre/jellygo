import SwiftUI
import Combine

// MARK: - SRT Parser

struct SubtitleEntry {
    let index: Int
    let start: Double   // seconds
    let end: Double     // seconds
    let text: String
}

enum SRTParser {
    static func parse(_ content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let blocks = content.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .newlines)
            guard lines.count >= 3 else { continue }

            guard let idx = Int(lines[0].trimmingCharacters(in: .whitespaces)) else { continue }

            let timeParts = lines[1].components(separatedBy: " --> ")
            guard timeParts.count == 2 else { continue }
            guard let start = parseTime(timeParts[0]),
                  let end = parseTime(timeParts[1]) else { continue }

            let text = lines[2...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\{\\\\[^}]+\\}", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            entries.append(SubtitleEntry(index: idx, start: start, end: end, text: text))
        }
        return entries.sorted { $0.start < $1.start }
    }

    private static func parseTime(_ str: String) -> Double? {
        // Format: 00:01:23,456 or 00:01:23.456
        let cleaned = str.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - VTT Parser

enum VTTParser {
    static func parse(_ content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        var idx = 1

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            // Look for timestamp lines: "00:01:23.456 --> 00:01:25.789"
            if line.contains(" --> ") {
                let timeParts = line.components(separatedBy: " --> ")
                if timeParts.count >= 2,
                   let start = parseTime(timeParts[0]),
                   let end = parseTime(timeParts[1].components(separatedBy: " ").first ?? timeParts[1]) {
                    i += 1
                    var textLines: [String] = []
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        textLines.append(lines[i].trimmingCharacters(in: .whitespaces))
                        i += 1
                    }
                    let text = textLines.joined(separator: "\n")
                        .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        entries.append(SubtitleEntry(index: idx, start: start, end: end, text: text))
                        idx += 1
                    }
                    continue
                }
            }
            i += 1
        }
        return entries.sorted { $0.start < $1.start }
    }

    private static func parseTime(_ str: String) -> Double? {
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.components(separatedBy: ":")
        // VTT can be HH:MM:SS.mmm or MM:SS.mmm
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        }
        return nil
    }
}

// MARK: - ASS/SSA Parser

enum ASSParser {
    static func parse(_ content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let lines = content.components(separatedBy: .newlines)
        var idx = 1

        for line in lines {
            // Dialogue lines: "Dialogue: 0,0:01:23.45,0:01:25.67,StyleName,,0,0,0,,Text here"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Dialogue:") else { continue }

            let afterPrefix = String(trimmed.dropFirst("Dialogue:".count)).trimmingCharacters(in: .whitespaces)
            let parts = afterPrefix.components(separatedBy: ",")
            // Need at least 10 comma-separated fields (Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text)
            guard parts.count >= 10 else { continue }

            guard let start = parseTime(parts[1]),
                  let end = parseTime(parts[2]) else { continue }

            // Text is everything from the 10th field onwards (index 9+), may contain commas
            let text = parts[9...].joined(separator: ",")
                // Remove ASS override tags like {\an8}, {\pos(x,y)}, {\fad(100,200)}, etc.
                .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
                // Replace \N and \n with newline
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else { continue }
            entries.append(SubtitleEntry(index: idx, start: start, end: end, text: text))
            idx += 1
        }
        return entries.sorted { $0.start < $1.start }
    }

    private static func parseTime(_ str: String) -> Double? {
        // ASS format: H:MM:SS.CC (centiseconds)
        let cleaned = str.trimmingCharacters(in: .whitespaces)
        let parts = cleaned.components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

// MARK: - Subtitle Manager

@MainActor
final class SubtitleManager: ObservableObject {
    @Published var currentText: String = ""
    @Published var entries: [SubtitleEntry] = []
    @Published var isLoaded = false

    var delaySecs: Double = 0

    private var lastIndex = 0

    /// Fetch and parse subtitle from URL. Returns true on success.
    @discardableResult
    func load(from url: URL, token: String) async -> Bool {
        var req = URLRequest(url: url)
        req.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? -1
            print("[SubtitleManager] Fetch status=\(httpStatus) bytes=\(data.count) url=\(url.lastPathComponent)")
            guard httpStatus >= 200 && httpStatus < 300 else {
                print("[SubtitleManager] HTTP error \(httpStatus) — skipping")
                return false
            }
            guard let content = String(data: data, encoding: .utf8), !content.isEmpty else {
                print("[SubtitleManager] Failed to decode subtitle data as UTF-8")
                return false
            }
            let preview = String(content.prefix(200))
            print("[SubtitleManager] Content preview: \(preview)")
            // Try SRT, then VTT, then ASS/SSA
            var parsed = SRTParser.parse(content)
            if parsed.isEmpty {
                parsed = VTTParser.parse(content)
            }
            if parsed.isEmpty {
                parsed = ASSParser.parse(content)
            }
            guard !parsed.isEmpty else {
                print("[SubtitleManager] Parsed 0 entries — subtitle format not recognized")
                return false
            }
            entries = parsed
            isLoaded = true
            lastIndex = 0
            print("[SubtitleManager] Parsed \(entries.count) entries")
            if let first = entries.first {
                print("[SubtitleManager] First entry: [\(first.start)-\(first.end)] \(first.text.prefix(50))")
            }
            return true
        } catch {
            print("[SubtitleManager] Fetch failed: \(error.localizedDescription)")
            return false
        }
    }

    func loadLocal(from url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        // Try SRT → VTT → ASS (file may contain any format despite .srt extension)
        var parsed = SRTParser.parse(content)
        if parsed.isEmpty { parsed = VTTParser.parse(content) }
        if parsed.isEmpty { parsed = ASSParser.parse(content) }
        guard !parsed.isEmpty else { return }
        entries = parsed
        isLoaded = true
        lastIndex = 0
    }

    private var updateLogCount = 0
    func update(currentSeconds: Double) {
        guard isLoaded, !entries.isEmpty else {
            return
        }
        updateLogCount += 1
        if updateLogCount <= 3 {
            print("[SubtitleManager] update called: t=\(currentSeconds) entries=\(entries.count) delay=\(delaySecs)")
        }
        let t = currentSeconds + delaySecs

        // Quick search from last known position
        // Most subtitle lookups are sequential, so start near lastIndex
        if lastIndex < entries.count {
            let e = entries[lastIndex]
            if t >= e.start && t <= e.end {
                if currentText != e.text { currentText = e.text }
                return
            }
        }

        // Binary search for the right entry
        var lo = 0, hi = entries.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let e = entries[mid]
            if t < e.start {
                hi = mid - 1
            } else if t > e.end {
                lo = mid + 1
            } else {
                lastIndex = mid
                if currentText != e.text { currentText = e.text }
                return
            }
        }

        // No subtitle at this time
        if !currentText.isEmpty { currentText = "" }
    }

    func clear() {
        entries = []
        currentText = ""
        isLoaded = false
        lastIndex = 0
    }
}

// MARK: - Subtitle Overlay View

struct SubtitleOverlayView: View {
    @ObservedObject var manager: SubtitleManager

    var body: some View {
        if !manager.currentText.isEmpty {
            VStack {
                Spacer()
                Text(manager.currentText)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 2, x: 0, y: 1)
                    .shadow(color: .black, radius: 4, x: 0, y: 2)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 6)
                    .background(
                        Color.black.opacity(0.6)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    )
                    .padding(.bottom, 40)
                    .padding(.horizontal, 60)
            }
            .allowsHitTesting(false)
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }
}
