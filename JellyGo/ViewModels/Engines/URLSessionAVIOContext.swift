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
/// How: one streaming GET (`Range: bytes=N-`) fills a bounded buffer; FFmpeg's blocking
/// `read` drains it. The download is suspended when the buffer is full and resumed when it
/// drains (backpressure). A seek inside the buffered window just skips bytes; any other seek
/// cancels the request and reopens it at the new offset. The total size comes from
/// `Content-Range` (or `Content-Length`). `close()` wakes any blocked read immediately.
nonisolated final class URLSessionAVIOContext: AbstractAVIOContext, @unchecked Sendable {
    // FFmpeg error codes (macros are not visible to Swift).
    private static let errorEOF: Int32 = -541_478_725      // AVERROR_EOF
    private static let errorIO: Int32 = -5                  // AVERROR(EIO)
    private static let errorExit: Int32 = -1_414_092_869    // AVERROR_EXIT

    private let url: URL
    private let headers: [String: String]
    private let highWater = 8 * 1024 * 1024
    private let lowWater = 4 * 1024 * 1024
    private let readTimeout: TimeInterval = 30

    private let condition = NSCondition()
    private var session: URLSession!
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "jellygo.avio"
        return q
    }()

    // State below is guarded by `condition`.
    private var task: URLSessionDataTask?
    private var generation = 0             // bumps on every (re)open; stale callbacks are dropped
    private var chunks: [Data] = []
    private var headOffset = 0             // bytes already consumed from chunks[0]
    private var buffered = 0               // unread bytes in `chunks`
    private var position: Int64 = 0        // file offset of the next byte FFmpeg will read
    private var totalSize: Int64 = -1
    private var gotResponse = false
    private var finished = false           // current request delivered everything
    private var failed = false
    private var closed = false
    private var suspended = false
    private var reconnects = 0
#if DEBUG
    private var statIn = 0, statOut = 0, statReads = 0, statWaitMs = 0.0
    private var statStart = Date()
    private func stat() {
        let dt = Date().timeIntervalSince(statStart)
        guard dt >= 2 else { return }
        log(String(format: "in %.2f MB/s  out %.2f MB/s  reads %d  wait %.0f ms  buffered %.1f MB  suspended %@",
                   Double(statIn) / dt / 1e6, Double(statOut) / dt / 1e6, statReads, statWaitMs,
                   Double(buffered) / 1e6, suspended ? "yes" : "no"))
        statIn = 0; statOut = 0; statReads = 0; statWaitMs = 0; statStart = Date()
    }
#endif

    init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
        super.init(bufferSize: 256 * 1024)
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Idle timeout per request. The task is suspended while the buffer is full (and
        // while the video is paused), so this must be generous; read() reconnects anyway.
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 7 * 24 * 3600
        session = URLSession(configuration: config,
                             delegate: SessionDelegate(owner: self),
                             delegateQueue: delegateQueue)
    }

    // MARK: AbstractAVIOContext

    override func read(buffer: UnsafePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return 0 }
        condition.lock()
        defer { condition.unlock() }
        if task == nil && !closed { open(at: position) }
        var deadline = Date().addingTimeInterval(readTimeout)
#if DEBUG
        let waitStart = Date()
        defer { statWaitMs += Date().timeIntervalSince(waitStart) * 1000 }
#endif
        while buffered == 0 && !closed {
            if finished || failed {
                // The request ended before the file did (timeout while suspended, dropped
                // connection, server closing idle streams...): reconnect at the current
                // offset instead of reporting an error to FFmpeg.
                let atEnd = totalSize >= 0 && position >= totalSize
                if atEnd || (finished && !failed && totalSize < 0) { return Self.errorEOF }
                guard reconnects < 5 else { return Self.errorIO }
                reconnects += 1
                log("reconnect #\(reconnects) at \(position)")
                open(at: position)
                deadline = Date().addingTimeInterval(readTimeout)
                continue
            }
            if !condition.wait(until: deadline) {
                log("read timed out at \(position)")
                return Self.errorIO
            }
        }
        if closed { return Self.errorExit }
        reconnects = 0

        let out = UnsafeMutablePointer(mutating: buffer)
        var written = 0
        let want = Int(size)
        while written < want, let head = chunks.first {
            let available = head.count - headOffset
            let n = min(available, want - written)
            head.withUnsafeBytes { raw in
                (out + written).update(from: raw.baseAddress!.assumingMemoryBound(to: UInt8.self) + headOffset, count: n)
            }
            written += n
            headOffset += n
            if headOffset == head.count { chunks.removeFirst(); headOffset = 0 }
        }
        buffered -= written
        position += Int64(written)
#if DEBUG
        statOut += written; statReads += 1; stat()
#endif
        if suspended && buffered <= lowWater, let task {
            suspended = false
            task.resume()
        }
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
            if totalSize < 0 { waitForResponse() }
            guard totalSize >= 0 else { return -1 }
            target = totalSize + offset
        default: return -1
        }
        guard target >= 0 else { return -1 }
        if target == position { return target }
        // Forward seek inside what is already downloaded: drop bytes, keep the request.
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
            if suspended && buffered <= lowWater, let task { suspended = false; task.resume() }
            return target
        }
        position = target
        log("seek -> \(target) (reopen)")
        open(at: target)
        return target
    }

    override func fileSize() -> Int64 {
        condition.lock()
        defer { condition.unlock() }
        if totalSize < 0 && !closed {
            if task == nil { open(at: position) }
            waitForResponse()
        }
        return totalSize
    }

    override func close() {
        condition.lock()
        closed = true
        task?.cancel()
        task = nil
        chunks.removeAll()
        buffered = 0
        condition.broadcast()
        condition.unlock()
        session.invalidateAndCancel()
    }

    // MARK: Request handling (call with `condition` locked)

    private func open(at offset: Int64) {
        task?.cancel()
        generation += 1
        chunks.removeAll()
        headOffset = 0
        buffered = 0
        finished = false
        failed = false
        suspended = false
        gotResponse = false
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let t = session.dataTask(with: request)
        t.taskDescription = String(generation)
        task = t
        t.resume()
    }

    private func waitForResponse() {
        let deadline = Date().addingTimeInterval(readTimeout)
        while !gotResponse && !failed && !closed {
            if !condition.wait(until: deadline) { break }
        }
    }

    private func log(_ message: @autoclosure () -> String) {
#if DEBUG
        print("[AVIO] \(message())")
#endif
    }

    private func isCurrent(_ t: URLSessionTask) -> Bool {
        t.taskDescription == String(generation) && !closed
    }

    // MARK: URLSession callbacks (delegate queue)

    fileprivate func didReceive(response: URLResponse, task t: URLSessionTask) -> Bool {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard isCurrent(t) else { return false }
        gotResponse = true
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            failed = true
            log("bad response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            return false
        }
        log("response \(http.statusCode) range=\(http.value(forHTTPHeaderField: "Content-Range") ?? "-")")
        if let range = http.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            totalSize = total
        } else if http.statusCode == 200, http.expectedContentLength > 0 {
            // Server ignored Range: it sends the whole file from byte 0.
            totalSize = http.expectedContentLength
            if position != 0 {
                // Can't serve this offset; let FFmpeg see an error rather than wrong bytes.
                failed = true
                return false
            }
        }
        return true
    }

    fileprivate func didReceive(data: Data, task t: URLSessionDataTask) {
        condition.lock()
        defer { condition.unlock() }
        guard isCurrent(t) else { return }
        chunks.append(data)
        buffered += data.count
#if DEBUG
        statIn += data.count; stat()
#endif
        if buffered >= highWater && !suspended {
            suspended = true
            t.suspend()
            log("suspend at \(buffered) buffered")
        }
        condition.broadcast()
    }

    fileprivate func didComplete(task t: URLSessionTask, error: Error?) {
        condition.lock()
        defer { condition.broadcast(); condition.unlock() }
        guard isCurrent(t) else { return }
        if let error, (error as NSError).code != NSURLErrorCancelled {
            failed = true
            log("request failed: \((error as NSError).code) \(error.localizedDescription)")
        }
        finished = true
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
            print("[AVIO] protocol=\(m.networkProtocolName ?? "?") reused=\(m.isReusedConnection) remote=\(m.remoteAddress ?? "?") multipath=\(m.isMultipath) iface cellular=\(m.isCellular) expensive=\(m.isExpensive)")
        }
    }
#endif

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        owner?.didComplete(task: task, error: error)
    }
}
#endif
