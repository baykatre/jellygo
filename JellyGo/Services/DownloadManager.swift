import Foundation
import Combine

// MARK: - Model

struct DownloadedItem: Codable, Identifiable {
    let id: String           // Jellyfin itemId
    let name: String
    let type: String         // "Movie" | "Episode"
    let seriesName: String?
    let seriesId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let quality: String      // "Direct" | "1080p" | "720p" | "480p" | "360p"
    var fileName: String     // e.g. "{itemId}.mp4"
    let addedDate: Date
    let serverURL: String
    let userId: String
    var fileSize: Int64?
    var runTimeTicks: Int64?

    var localURL: URL? {
        DownloadManager.downloadsDirectory.appendingPathComponent(fileName)
    }

    var isMovie: Bool   { type == "Movie" }
    var isEpisode: Bool { type == "Episode" }

    /// Converts back to a minimal JellyfinItem so existing views can be reused.
    func toJellyfinItem() -> JellyfinItem {
        JellyfinItem(
            id: id, name: name, type: type,
            overview: nil, productionYear: nil,
            communityRating: nil, criticRating: nil,
            runTimeTicks: runTimeTicks,
            seriesName: seriesName, seriesId: seriesId,
            seasonName: nil, indexNumber: episodeNumber,
            parentIndexNumber: seasonNumber,
            userData: nil, imageBlurHashes: nil,
            primaryImageAspectRatio: nil, genres: nil,
            officialRating: nil, taglines: nil, people: nil,
            premiereDate: nil, mediaStreams: nil, mediaSources: nil,
            childCount: nil
        )
    }

    var formattedSize: String {
        guard let size = fileSize else { return "" }
        let gb = Double(size) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(size) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

// MARK: - Active Download

struct ActiveDownload: Identifiable {
    let id: String
    let name: String
    let seriesName: String?
    let seriesId: String?
    var progress: Double     // 0..1
    var bytesReceived: Int64
    var bytesExpected: Int64 // 0 when truly unknown
    var isFailed: Bool
    var isPaused: Bool
    var isDirect: Bool
    var isTranscoding: Bool  // separate flag so estimated bytesExpected doesn't affect this
    let task: URLSessionDownloadTask

    // Speed tracking
    var speedBytesPerSec: Double = 0
    var lastSpeedUpdateDate: Date = .now
    var lastSpeedBytes: Int64 = 0

    var formattedProgress: String {
        let received = Double(bytesReceived) / 1_048_576
        if bytesExpected <= 0 {
            if received >= 1000 { return String(format: "%.1f GB", received / 1024) }
            return String(format: "%.0f MB", received)
        }
        let total = Double(bytesExpected) / 1_048_576
        if total >= 1000 {
            return String(format: "%.1f / %.1f GB", received / 1024, total / 1024)
        }
        return String(format: "%.0f / %.0f MB", received, total)
    }

    var formattedSpeed: String {
        guard speedBytesPerSec > 0 else { return "" }
        let mbps = speedBytesPerSec / 1_048_576
        if mbps >= 1 { return String(format: "%.1f MB/s", mbps) }
        let kbps = speedBytesPerSec / 1024
        return String(format: "%.0f KB/s", kbps)
    }
}

// MARK: - Queue Entry

struct QueuedDownload: Identifiable {
    let id: String
    let name: String
    let seriesName: String?
    let isDirect: Bool
    let isTranscoding: Bool
    let meta: DownloadedItem
    let request: URLRequest
    let estimatedBytes: Int64  // 0 if unknown
}

// MARK: - Paused Download (persisted)

struct PausedDownload: Codable, Identifiable {
    let id: String
    let name: String
    let seriesName: String?
    let seriesId: String?
    let isDirect: Bool
    let isTranscoding: Bool
    let meta: DownloadedItem
    let originalURLString: String  // fallback if no resume data
    var bytesReceived: Int64 = 0
    var bytesExpected: Int64 = 0

    var formattedProgress: String {
        let received = Double(bytesReceived) / 1_048_576
        if bytesExpected <= 0 {
            if bytesReceived == 0 { return "" }
            if received >= 1000 { return String(format: "%.1f GB", received / 1024) }
            return String(format: "%.0f MB", received)
        }
        let total = Double(bytesExpected) / 1_048_576
        if total >= 1000 {
            return String(format: "%.1f / %.1f GB", received / 1024, total / 1024)
        }
        return String(format: "%.0f / %.0f MB", received, total)
    }

    var progress: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1.0, Double(bytesReceived) / Double(bytesExpected))
    }
}

// MARK: - Manager

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published var downloads: [DownloadedItem] = []
    @Published var activeTasks: [String: ActiveDownload] = [:]
    @Published var downloadQueue: [QueuedDownload] = []
    @Published var pausedItems: [PausedDownload] = []
    /// Stable insertion order for all in-progress downloads (active + queued + paused)
    @Published var downloadOrder: [String] = []

    /// Fired when a new download starts (used for in-app banner)
    let downloadStarted = PassthroughSubject<PausedDownload, Never>()

    private let maxConcurrent = 3
    private let maxTranscoding = 1

    var backgroundCompletionHandler: (() -> Void)?

    private var urlSession: URLSession!
    private let metaLock = NSLock()
    nonisolated(unsafe) private var pendingMeta: [String: DownloadedItem] = [:]
    nonisolated(unsafe) private var resumeDataStore: [String: Data] = [:]

    nonisolated static var downloadsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyGoDownloads", isDirectory: true)
    }

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)
        // Load metadata BEFORE creating the URLSession so that pendingMeta is
        // fully populated before any background-session delegate calls can fire.
        loadMetadata()
        loadPausedItems()
        for p in pausedItems {
            metaLock.lock()
            pendingMeta[p.id] = p.meta
            metaLock.unlock()
            if !downloadOrder.contains(p.id) { downloadOrder.append(p.id) }
        }
        let config = URLSessionConfiguration.background(withIdentifier: "jellygo.bg.downloads")
        config.timeoutIntervalForResource = 3600
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Queries

    func isDownloaded(_ itemId: String) -> Bool { downloads.contains { $0.id == itemId } }
    func isDownloading(_ itemId: String) -> Bool { activeTasks[itemId] != nil }
    func isQueued(_ itemId: String) -> Bool { downloadQueue.contains { $0.id == itemId } }
    func isPaused(_ itemId: String) -> Bool { pausedItems.contains { $0.id == itemId } }

    // MARK: - Queue Logic

    private var activeTranscodingCount: Int {
        activeTasks.values.filter { $0.isTranscoding }.count
    }

    private func canStartNow(isTranscoding: Bool) -> Bool {
        guard activeTasks.count < maxConcurrent else { return false }
        if isTranscoding { return activeTranscodingCount < maxTranscoding }
        return true
    }

    private func drainQueue() {
        var i = 0
        while i < downloadQueue.count {
            let entry = downloadQueue[i]
            if canStartNow(isTranscoding: entry.isTranscoding) {
                downloadQueue.remove(at: i)
                launchTask(for: entry)
            } else {
                i += 1
            }
        }
    }

    private func launchTask(for entry: QueuedDownload) {
        metaLock.lock()
        let savedData = resumeDataStore.removeValue(forKey: entry.id)
        metaLock.unlock()

        let task: URLSessionDownloadTask
        if let savedData {
            task = urlSession.downloadTask(withResumeData: savedData)
        } else {
            task = urlSession.downloadTask(with: entry.request)
        }
        task.taskDescription = entry.id

        metaLock.lock()
        pendingMeta[entry.id] = entry.meta
        metaLock.unlock()

        // Ensure this item is in pausedItems as kill-recovery entry
        if !pausedItems.contains(where: { $0.id == entry.id }) {
            let p = PausedDownload(id: entry.id, name: entry.name, seriesName: entry.seriesName,
                                   seriesId: entry.meta.seriesId, isDirect: entry.isDirect,
                                   isTranscoding: entry.isTranscoding, meta: entry.meta,
                                   originalURLString: entry.request.url?.absoluteString ?? "")
            pausedItems.append(p)
            savePausedItems()
            downloadStarted.send(p)
        }
        if !downloadOrder.contains(entry.id) { downloadOrder.append(entry.id) }

        activeTasks[entry.id] = ActiveDownload(
            id: entry.id, name: entry.name,
            seriesName: entry.seriesName, seriesId: entry.meta.seriesId,
            progress: 0, bytesReceived: 0,
            bytesExpected: entry.estimatedBytes,
            isFailed: false, isPaused: false, isDirect: entry.isDirect,
            isTranscoding: entry.isTranscoding,
            task: task
        )
        task.resume()
    }

    // MARK: - Start

    func startDownload(item: JellyfinItem, qualityLabel: String, downloadURL: URL, appState: AppState) {
        guard !isDownloaded(item.id), !isDownloading(item.id),
              !isQueued(item.id), !isPaused(item.id) else { return }

        let isDirect = qualityLabel == "Direct"
        let isTranscoding = !isDirect
        let fileName = "\(item.id).mp4"
        let meta = DownloadedItem(
            id: item.id, name: item.name, type: item.type,
            seriesName: item.seriesName, seriesId: item.seriesId,
            seasonNumber: item.parentIndexNumber, episodeNumber: item.indexNumber,
            quality: qualityLabel, fileName: fileName, addedDate: Date(),
            serverURL: appState.serverURL, userId: appState.userId,
            runTimeTicks: item.runTimeTicks
        )

        // Estimate total bytes for transcoding so the progress bar is deterministic
        let estimatedBytes: Int64
        if isTranscoding, let ticks = item.runTimeTicks, let bitrate = bitrateForLabel(qualityLabel) {
            estimatedBytes = Int64(Double(ticks) / 10_000_000 * Double(bitrate) / 8)
        } else {
            estimatedBytes = 0
        }

        var req = URLRequest(url: downloadURL)
        req.timeoutInterval = 3600

        let entry = QueuedDownload(id: item.id, name: item.name, seriesName: item.seriesName,
                                   isDirect: isDirect, isTranscoding: isTranscoding,
                                   meta: meta, request: req, estimatedBytes: estimatedBytes)

        if !downloadOrder.contains(item.id) { downloadOrder.append(item.id) }
        if canStartNow(isTranscoding: isTranscoding) {
            launchTask(for: entry)
        } else {
            downloadQueue.append(entry)
        }
    }

    private func bitrateForLabel(_ label: String) -> Int? {
        switch label {
        case "1080p": return 8_000_000
        case "720p":  return 4_000_000
        case "480p":  return 2_000_000
        case "360p":  return 1_000_000
        default:      return nil
        }
    }

    // MARK: - Pause / Resume

    func pauseDownload(_ itemId: String) {
        guard let active = activeTasks[itemId], !active.isPaused else { return }
        metaLock.lock()
        let meta = pendingMeta[itemId]
        metaLock.unlock()

        let taskURL = active.task.currentRequest?.url?.absoluteString ?? ""
        let snapshotReceived = active.bytesReceived
        let snapshotExpected = active.bytesExpected

        active.task.cancel(byProducingResumeData: { [weak self] data in
            guard let self else { return }
            if let data {
                self.metaLock.lock()
                self.resumeDataStore[itemId] = data
                self.metaLock.unlock()
            }
            Task { @MainActor [self] in
                if !self.pausedItems.contains(where: { $0.id == itemId }), let meta {
                    var p = PausedDownload(id: itemId, name: active.name,
                                           seriesName: active.seriesName, seriesId: active.seriesId,
                                           isDirect: active.isDirect, isTranscoding: active.isTranscoding,
                                           meta: meta, originalURLString: taskURL)
                    p.bytesReceived = snapshotReceived
                    p.bytesExpected = snapshotExpected
                    self.pausedItems.append(p)
                } else if let idx = self.pausedItems.firstIndex(where: { $0.id == itemId }) {
                    var updated = self.pausedItems[idx]
                    if updated.originalURLString.isEmpty {
                        updated = PausedDownload(
                            id: updated.id, name: updated.name,
                            seriesName: updated.seriesName, seriesId: updated.seriesId,
                            isDirect: updated.isDirect, isTranscoding: updated.isTranscoding,
                            meta: updated.meta, originalURLString: taskURL)
                    }
                    updated.bytesReceived = snapshotReceived
                    updated.bytesExpected = snapshotExpected
                    self.pausedItems[idx] = updated
                }
                self.savePausedItems()
                self.activeTasks.removeValue(forKey: itemId)
                _ = self.metaLock.withLock { self.pendingMeta.removeValue(forKey: itemId) }
                self.drainQueue()
            }
        })
    }

    func resumeDownload(_ itemId: String, appState: AppState) {
        guard let paused = pausedItems.first(where: { $0.id == itemId }) else { return }
        guard !isDownloading(itemId), !isQueued(itemId) else { return }

        pausedItems.removeAll { $0.id == itemId }
        savePausedItems()

        // Build request — use resume data if available, else reconstruct URL
        let urlString = paused.originalURLString
        guard let url = URL(string: urlString.isEmpty ? "" : urlString) ?? nil else {
            // If no original URL, rebuild from quality + current token
            guard let rebuilt = rebuildURL(meta: paused.meta, appState: appState) else { return }
            let req = URLRequest(url: rebuilt)
            let entry = QueuedDownload(id: paused.id, name: paused.name, seriesName: paused.seriesName,
                                       isDirect: paused.isDirect, isTranscoding: paused.isTranscoding,
                                       meta: paused.meta, request: req, estimatedBytes: 0)
            if canStartNow(isTranscoding: paused.isTranscoding) { launchTask(for: entry) }
            else { downloadQueue.append(entry) }
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3600
        let estimatedBytes: Int64
        if paused.isTranscoding, let ticks = paused.meta.runTimeTicks,
           let bitrate = bitrateForLabel(paused.meta.quality) {
            estimatedBytes = Int64(Double(ticks) / 10_000_000 * Double(bitrate) / 8)
        } else {
            estimatedBytes = 0
        }
        let entry = QueuedDownload(id: paused.id, name: paused.name, seriesName: paused.seriesName,
                                   isDirect: paused.isDirect, isTranscoding: paused.isTranscoding,
                                   meta: paused.meta, request: req, estimatedBytes: estimatedBytes)
        if canStartNow(isTranscoding: paused.isTranscoding) { launchTask(for: entry) }
        else { downloadQueue.append(entry) }
    }

    private func rebuildURL(meta: DownloadedItem, appState: AppState) -> URL? {
        if meta.quality == "Direct" {
            return Self.directURL(itemId: meta.id, serverURL: appState.serverURL, token: appState.token)
        } else if let bitrate = bitrateForLabel(meta.quality) {
            return Self.transcodedURL(itemId: meta.id, serverURL: appState.serverURL,
                                      token: appState.token, maxBitrate: bitrate)
        }
        return nil
    }

    // MARK: - Cancel / Delete

    func cancelDownload(_ itemId: String) {
        downloadOrder.removeAll { $0 == itemId }
        if let idx = downloadQueue.firstIndex(where: { $0.id == itemId }) {
            downloadQueue.remove(at: idx)
            return
        }
        if pausedItems.contains(where: { $0.id == itemId }) {
            pausedItems.removeAll { $0.id == itemId }
            savePausedItems()
            metaLock.lock()
            resumeDataStore.removeValue(forKey: itemId)
            metaLock.unlock()
            return
        }
        // Use plain cancel (not byProducingResumeData) to avoid stale resume data
        // being picked up by a future download of the same item with a different quality.
        activeTasks[itemId]?.task.cancel()
        activeTasks.removeValue(forKey: itemId)
        metaLock.lock()
        pendingMeta.removeValue(forKey: itemId)
        resumeDataStore.removeValue(forKey: itemId)
        metaLock.unlock()
        pausedItems.removeAll { $0.id == itemId }
        savePausedItems()
        drainQueue()
    }

    func deleteDownload(_ itemId: String) {
        // Cancel any in-progress task first so it doesn't re-save the file after deletion
        activeTasks[itemId]?.task.cancel()
        activeTasks.removeValue(forKey: itemId)
        downloadQueue.removeAll { $0.id == itemId }
        pausedItems.removeAll { $0.id == itemId }
        downloadOrder.removeAll { $0 == itemId }
        metaLock.lock()
        pendingMeta.removeValue(forKey: itemId)
        resumeDataStore.removeValue(forKey: itemId)
        metaLock.unlock()
        savePausedItems()

        // Delete the video file
        if let item = downloads.first(where: { $0.id == itemId }), let url = item.localURL {
            try? FileManager.default.removeItem(at: url)
        } else {
            // Might have been cancelled mid-download; try the expected filename anyway
            let fallback = Self.downloadsDirectory.appendingPathComponent("\(itemId).mp4")
            try? FileManager.default.removeItem(at: fallback)
        }

        // Delete subtitle files (e.g. {itemId}_tur.srt, {itemId}_eng.srt …)
        let srtPattern = "\(itemId)_"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: Self.downloadsDirectory.path) {
            for file in files where file.hasPrefix(srtPattern) && file.hasSuffix(".srt") {
                try? FileManager.default.removeItem(at: Self.downloadsDirectory.appendingPathComponent(file))
            }
        }

        // Clear URLCache entries for this item (video stream + image URLs)
        URLCache.shared.removeCachedResponses(since: .distantPast)

        downloads.removeAll { $0.id == itemId }
        saveMetadata()
        drainQueue()
    }

    // MARK: - Subtitles

    func downloadSubtitles(itemId: String, mediaSourceId: String, streams: [JellyfinMediaStream], serverURL: String, token: String) {
        for stream in streams.prefix(5) {
            guard let url = Self.subtitleURL(serverURL: serverURL, itemId: itemId,
                                             mediaSourceId: mediaSourceId,
                                             streamIndex: stream.index, token: token) else { continue }
            let lang = stream.language ?? "und"
            let destURL = Self.downloadsDirectory.appendingPathComponent("\(itemId)_\(lang).srt")
            URLSession.shared.downloadTask(with: url) { tempURL, _, _ in
                guard let tempURL else { return }
                try? FileManager.default.removeItem(at: destURL)
                try? FileManager.default.moveItem(at: tempURL, to: destURL)
            }.resume()
        }
    }

    // MARK: - URL Builders

    static func directURL(itemId: String, serverURL: String, token: String) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Videos/\(itemId)/stream"),
                              resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "static", value: "true"),
                         URLQueryItem(name: "api_key", value: token)]
        return c?.url
    }

    static func subtitleURL(serverURL: String, itemId: String, mediaSourceId: String,
                            streamIndex: Int, token: String) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var c = URLComponents(
            url: base.appendingPathComponent(
                "Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/0/Stream.srt"),
            resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "api_key", value: token)]
        return c?.url
    }

    static func transcodedURL(itemId: String, serverURL: String, token: String, maxBitrate: Int) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var c = URLComponents(url: base.appendingPathComponent("Videos/\(itemId)/stream.mp4"),
                              resolvingAgainstBaseURL: false)
        c?.queryItems = [
            URLQueryItem(name: "VideoCodec",       value: "h264"),
            URLQueryItem(name: "AudioCodec",       value: "aac"),
            URLQueryItem(name: "VideoBitrate",     value: "\(maxBitrate)"),
            URLQueryItem(name: "AudioBitrate",     value: "128000"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
            URLQueryItem(name: "Static",           value: "false"),
            URLQueryItem(name: "api_key",          value: token)
        ]
        return c?.url
    }

    // MARK: - Persistence

    private func loadMetadata() {
        let url = Self.downloadsDirectory.appendingPathComponent("metadata.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([DownloadedItem].self, from: data) else { return }
        downloads = items.filter {
            $0.localURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }
    }

    func saveMetadata() {
        let url = Self.downloadsDirectory.appendingPathComponent("metadata.json")
        if let data = try? JSONEncoder().encode(downloads) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func loadPausedItems() {
        let url = Self.downloadsDirectory.appendingPathComponent("paused.json")
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PausedDownload].self, from: data) else { return }
        // Only keep items that aren't already completed downloads
        pausedItems = items.filter { p in !downloads.contains(where: { $0.id == p.id }) }
    }

    private func savePausedItems() {
        let url = Self.downloadsDirectory.appendingPathComponent("paused.json")
        if let data = try? JSONEncoder().encode(pausedItems) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let itemId = downloadTask.taskDescription else { return }
        metaLock.lock()
        let meta = pendingMeta[itemId]
        metaLock.unlock()

        // If meta is missing (rare race on relaunch), keep the file safe with itemId as name
        let fileName = meta?.fileName ?? "\(itemId).mp4"
        let destURL = Self.downloadsDirectory.appendingPathComponent(fileName)

        guard let meta else {
            // Save the file so it isn't lost; the entry will appear as orphaned but recoverable
            try? FileManager.default.moveItem(at: location, to: destURL)
            return
        }
        do {
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.moveItem(at: location, to: destURL)
            var completed = meta
            let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path)
            completed.fileSize = attrs?[.size] as? Int64
            let finalItem = completed

            metaLock.lock()
            pendingMeta.removeValue(forKey: itemId)
            metaLock.unlock()

            Task { @MainActor [self] in
                downloads.append(finalItem)
                activeTasks.removeValue(forKey: itemId)
                pausedItems.removeAll { $0.id == itemId }
                downloadOrder.removeAll { $0 == itemId }
                savePausedItems()
                saveMetadata()
                drainQueue()
            }
        } catch {
            Task { @MainActor [self] in
                activeTasks[itemId]?.isFailed = true
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let itemId = downloadTask.taskDescription else { return }
        let now = Date()

        Task { @MainActor [self] in
            if var dl = activeTasks[itemId] {
                // For transcoding, the OS-reported total is unreliable (chunked encoding).
                // Always prefer our pre-calculated estimate; fall back to OS value only for
                // direct downloads where Content-Length is accurate.
                let expected: Int64
                if dl.isTranscoding {
                    expected = dl.bytesExpected  // keep our estimate
                } else {
                    expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : dl.bytesExpected
                }
                let progress = expected > 0
                    ? min(1.0, Double(totalBytesWritten) / Double(expected)) : 0

                let elapsed = now.timeIntervalSince(dl.lastSpeedUpdateDate)
                if elapsed >= 1.0 {
                    dl.speedBytesPerSec = Double(totalBytesWritten - dl.lastSpeedBytes) / elapsed
                    dl.lastSpeedUpdateDate = now
                    dl.lastSpeedBytes = totalBytesWritten
                }
                dl.progress = progress
                dl.bytesReceived = totalBytesWritten
                dl.bytesExpected = expected
                activeTasks[itemId] = dl
            } else if let paused = pausedItems.first(where: { $0.id == itemId }) {
                // Background task reconnected after kill — promote from paused to active
                pausedItems.removeAll { $0.id == itemId }
                savePausedItems()
                activeTasks[itemId] = ActiveDownload(
                    id: paused.id, name: paused.name,
                    seriesName: paused.seriesName, seriesId: paused.seriesId,
                    progress: 0, bytesReceived: totalBytesWritten,
                    bytesExpected: totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : 0,
                    isFailed: false, isPaused: false,
                    isDirect: paused.isDirect, isTranscoding: paused.isTranscoding,
                    task: downloadTask
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let itemId = task.taskDescription else { return }
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        if let resumeData = nsErr.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            metaLock.lock()
            resumeDataStore[itemId] = resumeData
            metaLock.unlock()
        }
        Task { @MainActor [self] in
            activeTasks[itemId]?.isFailed = true
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [self] in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
