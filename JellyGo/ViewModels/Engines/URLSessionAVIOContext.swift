#if canImport(KSPlayer)
import Foundation
import KSPlayer

/// Feeds FFmpeg (KSMEPlayer) from URLSession instead of FFmpeg's own HTTPS stack.
///
/// Why: the FFmpegKit build bundled with KSPlayer ships nettle compiled with
/// `--disable-assembler`, so FFmpeg's gnutls decrypts AES-GCM in plain C. Profiling showed
/// ~20-28 % of the app's CPU in `gcm_gf_mul` / `nettle_aes_encrypt` while streaming over HTTPS.
/// URLSession uses the system TLS stack, which runs AES/GHASH on the CPU's crypto units.
///
/// How: the file is fetched in bounded byte ranges (`Range: bytes=a-b`), not one open-ended
/// request. A finished range leaves its keep-alive connection free, so the next range — or the
/// first range after a seek — reuses it instead of paying a new TCP + TLS handshake. (The first
/// version streamed `bytes=N-` and had to cancel it on every seek; on HTTP/1.1 that closes the
/// connection, and opening an MKV alone seeks 5-6 times.) Ranges start small (256 KB) and
/// double while reads stay sequential, up to 4 MB, so header/index probes and seeks are cheap
/// and steady playback uses few requests. Up to 8 MB is kept ahead of the read position.
nonisolated final class URLSessionAVIOContext: AbstractAVIOContext, @unchecked Sendable {
    // FFmpeg error codes (macros are not visible to Swift).
    private static let errorEOF: Int32 = -541_478_725      // AVERROR_EOF
    private static let errorIO: Int32 = -5                  // AVERROR(EIO)
    private static let errorExit: Int32 = -1_414_092_869    // AVERROR_EXIT

    private let url: URL
    private let headers: [String: String]
    private let minSegment = 256 * 1024
    private let maxSegment = 4 * 1024 * 1024
    private let readAhead = 8 * 1024 * 1024
    /// A superseded range still in flight is left to finish (keeping its connection) unless
    /// more than this much of it is still to come.
    private let abandonCancelThreshold: Int64 = 1024 * 1024
    private let readTimeout: TimeInterval = 30
    private let maxRetries = 3

    private let condition = NSCondition()
    private var session: URLSession!
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "jellygo.avio"
        return q
    }()

    // State below is guarded by `condition`.
    private var generation = 0            // bumps on every seek outside the buffer
    private var chunks: [Data] = []
    private var headOffset = 0            // bytes already consumed from chunks[0]
    private var buffered = 0              // unread bytes in `chunks`
    private var position: Int64 = 0       // file offset of the next byte FFmpeg will read
    private var fetchOffset: Int64 = 0    // where the next range request starts
    private var segmentSize = 256 * 1024
    private var totalSize: Int64 = -1
    private var gotSize = false
    private var active: URLSessionDataTask?        // range for the current generation
    private var activeLength: Int64 = 0            // bytes requested by `active`
    private var activeReceived: Int64 = 0
    private var failed = false
    private var retries = 0
    private var closed = false

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
        super.init(bufferSize: 256 * 1024)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = readTimeout
        config.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: config,
                             delegate: SessionDelegate(owner: self),
                             delegateQueue: delegateQueue)
    }

    // MARK: AbstractAVIOContext

    override func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        if atEnd { return Self.errorEOF }
        fillAhead()
        let deadline = Date().addingTimeInterval(readTimeout)
        while buffered == 0 && !closed {
            if atEnd { return Self.errorEOF }
            if failed {
                guard retries < maxRetries else { return Self.errorIO }
                retries += 1
                failed = false
                log("retry #\(retries) at \(fetchOffset)")
                fillAhead()
            }
            if !condition.wait(until: deadline) {
                log("read timed out at \(position)")
                return Self.errorIO
            }
        }
        if closed { return Self.errorExit }

        let out = UnsafeMutablePointer(mutating: buffer)
        var written = 0
        let want = Int(size)
        while written < want, let head = chunks.first {
            let n = min(head.count - headOffset, want - written)
            head.withUnsafeBytes { raw in
                (out + written).update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + headOffset, count: n)
            }
            written += n
            headOffset += n
            if headOffset == head.count { chunks.removeFirst(); headOffset = 0 }
        }
        buffered -= written
        position += Int64(written)
        retries = 0
#if DEBUG
        statOut += written; statReads += 1; stat()
#endif
        fillAhead()
        return Int32(written)
    }

    override func seek(offset: Int64, whence: Int32) -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        let target: Int64
        switch whence {
        case 0: target = offset                                  // SEEK_SET
        case 1: target = position + offset                       // SEEK_CUR
        case 2:                                                  // SEEK_END
            if !gotSize { fillAhead(); waitForSize() }
            guard totalSize >= 0 else { return -1 }
            target = totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        if target == position { return target }
        // Forward inside what is already downloaded: drop bytes, keep everything else.
        if target > position, target - position <= Int64(buffered) {
            var skip = Int(target - position)
            while skip > 0, let head = chunks.first {
                let n = min(head.count - headOffset, skip)
                skip -= n
                headOffset += n
                buffered -= n
                if headOffset == head.count { chunks.removeFirst(); headOffset = 0 }
            }
            position = target
            return target
        }
        log("seek -> \(target)")
        restart(at: target)
        return target
    }

    override func fileSize() -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        if !gotSize && !closed {
            fillAhead()
            waitForSize()
        }
        return totalSize
    }

    override func close() {
        condition.lock()
        closed = true
        active?.cancel()
        active = nil
        chunks.removeAll()
        buffered = 0
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
    }

    // MARK: Range requests (call with `condition` locked)

    private var atEnd: Bool { gotSize && totalSize >= 0 && position >= totalSize }

    /// Starts the next range if nothing is in flight and the read-ahead window has room.
    private func fillAhead() {
        guard !closed, active == nil, !failed, buffered < readAhead else { return }
        if gotSize, totalSize >= 0, fetchOffset >= totalSize { return }
        var end = fetchOffset + Int64(segmentSize) - 1
        if gotSize, totalSize > 0 { end = min(end, totalSize - 1) }
        var request = URLRequest(url: url)
        request.setValue("bytes=\(fetchOffset)-\(end)", forHTTPHeaderField: "Range")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let t = session.dataTask(with: request)
        t.taskDescription = String(generation)
        active = t
        activeLength = end - fetchOffset + 1
        activeReceived = 0
        t.resume()
    }

    /// Seek outside the buffer: drop it and start a small range at the new offset. The range
    /// in flight is left to complete (its connection then goes back to the pool) unless a lot
    /// of it is still coming.
    private func restart(at offset: Int64) {
        if let old = active, activeLength - activeReceived > abandonCancelThreshold { old.cancel() }
        generation += 1
        active = nil
        chunks.removeAll()
        headOffset = 0
        buffered = 0
        failed = false
        retries = 0
        position = offset
        fetchOffset = offset
        segmentSize = minSegment
        fillAhead()
    }

    private func waitForSize() {
        let deadline = Date().addingTimeInterval(readTimeout)
        while !gotSize && !failed && !closed {
            if !condition.wait(until: deadline) { break }
        }
    }

    private func isCurrent(_ t: URLSessionTask) -> Bool {
        t.taskDescription == String(generation) && !closed
    }

    private func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[AVIO] \(message())")
#endif
    }

#if DEBUG
    private var statIn = 0, statOut = 0, statReads = 0
    private var statStart = Date()
    private func stat() {
        let dt = Date().timeIntervalSince(statStart)
        guard dt >= 2 else { return }
        log(String(format: "in %.2f MB/s  out %.2f MB/s  reads %d  buffered %.1f MB  segment %d KB",
                   Double(statIn) / dt / 1e6, Double(statOut) / dt / 1e6, statReads,
                   Double(buffered) / 1e6, segmentSize / 1024))
        statIn = 0; statOut = 0; statReads = 0; statStart = Date()
    }
#endif

    // MARK: URLSession callbacks (delegate queue)

    fileprivate func didReceive(response: URLResponse, task t: URLSessionTask) -> Bool {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard isCurrent(t) else { return true }   // superseded: let it drain, keep connection
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            failed = true
            active = nil
            log("bad response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return false
        }
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            totalSize = total
            gotSize = true
        } else if http.statusCode == 200 {
            // Server ignored Range and sends the whole file: only usable from byte 0.
            if http.expectedContentLength > 0 { totalSize = http.expectedContentLength; gotSize = true }
            if fetchOffset != 0 {
                failed = true
                active = nil
                log("server ignored Range")
                return false
            }
            activeLength = .max
        }
        return true
    }

    fileprivate func didReceive(data: Data, task t: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        guard isCurrent(t) else { return }
        chunks.append(data)
        buffered += data.count
        fetchOffset += Int64(data.count)
        activeReceived += Int64(data.count)
#if DEBUG
        statIn += data.count; stat()
#endif
        condition.broadcast()
    }

    fileprivate func didComplete(task t: URLSessionTask, error: Error?) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard isCurrent(t), t === active else { return }
        active = nil
        if let error, (error as NSError).code != NSURLErrorCancelled {
            failed = true
            log("range failed at \(fetchOffset): \((error as NSError).code)")
            return
        }
        // Sequential reading continues: grow the next range.
        segmentSize = min(segmentSize * 2, maxSegment)
        fillAhead()
    }
}

/// URLSession retains its delegate; this small object keeps the context from being retained
/// in a cycle (FFmpeg owns the context's lifetime through KSPlayer).
nonisolated private final class SessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    weak var owner: URLSessionAVIOContext?
    init(owner: URLSessionAVIOContext) { self.owner = owner }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = owner?.didReceive(response: response, task: dataTask) ?? false
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        owner?.didReceive(data: data, task: dataTask)
    }

#if DEBUG
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        for m in metrics.transactionMetrics {
            print("[AVIO] range done protocol=\(m.networkProtocolName ?? "?") reused=\(m.isReusedConnection)")
        }
    }
#endif

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.didComplete(task: task, error: error)
    }
}
#endif
