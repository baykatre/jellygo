import Foundation
import Combine
import os

nonisolated private let log = Logger(subsystem: "JellyGo", category: "DownloadManager")

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

    // Full metadata for offline display
    var overview: String?
    var productionYear: Int?
    var communityRating: Double?
    var officialRating: String?
    var genres: [String]?
    var premiereDate: String?
    var primaryImageAspectRatio: Double?
    var seasonName: String?
    var taglines: [String]?

    // Explicit init(from:) so existing metadata.json without new fields still decodes
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        quality = try c.decode(String.self, forKey: .quality)
        fileName = try c.decode(String.self, forKey: .fileName)
        addedDate = try c.decode(Date.self, forKey: .addedDate)
        serverURL = try c.decode(String.self, forKey: .serverURL)
        userId = try c.decode(String.self, forKey: .userId)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        productionYear = try c.decodeIfPresent(Int.self, forKey: .productionYear)
        communityRating = try c.decodeIfPresent(Double.self, forKey: .communityRating)
        officialRating = try c.decodeIfPresent(String.self, forKey: .officialRating)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        premiereDate = try c.decodeIfPresent(String.self, forKey: .premiereDate)
        primaryImageAspectRatio = try c.decodeIfPresent(Double.self, forKey: .primaryImageAspectRatio)
        seasonName = try c.decodeIfPresent(String.self, forKey: .seasonName)
        taglines = try c.decodeIfPresent([String].self, forKey: .taglines)
    }

    init(id: String, name: String, type: String, seriesName: String?, seriesId: String?,
         seasonNumber: Int?, episodeNumber: Int?, quality: String, fileName: String,
         addedDate: Date, serverURL: String, userId: String, fileSize: Int64? = nil,
         runTimeTicks: Int64? = nil, overview: String? = nil, productionYear: Int? = nil,
         communityRating: Double? = nil, officialRating: String? = nil,
         genres: [String]? = nil, premiereDate: String? = nil,
         primaryImageAspectRatio: Double? = nil, seasonName: String? = nil,
         taglines: [String]? = nil) {
        self.id = id; self.name = name; self.type = type
        self.seriesName = seriesName; self.seriesId = seriesId
        self.seasonNumber = seasonNumber; self.episodeNumber = episodeNumber
        self.quality = quality; self.fileName = fileName
        self.addedDate = addedDate; self.serverURL = serverURL; self.userId = userId
        self.fileSize = fileSize; self.runTimeTicks = runTimeTicks; self.overview = overview
        self.productionYear = productionYear; self.communityRating = communityRating
        self.officialRating = officialRating; self.genres = genres
        self.premiereDate = premiereDate; self.primaryImageAspectRatio = primaryImageAspectRatio
        self.seasonName = seasonName; self.taglines = taglines
    }

    var localURL: URL? {
        DownloadManager.downloadsDirectory.appendingPathComponent(fileName)
    }

    var qualityDisplayName: String { VideoQuality.displayName(for: quality) }

    var isMovie: Bool   { type == "Movie" }
    var isEpisode: Bool { type == "Episode" }

    /// Converts back to a full JellyfinItem so existing views work identically offline.
    func toJellyfinItem() -> JellyfinItem {
        // Build userData from saved local position
        let savedPos = LocalPlaybackStore.position(for: id)
        let ud: JellyfinUserData? = savedPos > 0
            ? JellyfinUserData(playbackPositionTicks: Int64(savedPos * 10_000_000), played: nil, isFavorite: nil, playCount: nil)
            : nil

        return JellyfinItem(
            id: id, name: name, type: type,
            overview: overview, productionYear: productionYear,
            communityRating: communityRating, criticRating: nil,
            runTimeTicks: runTimeTicks,
            seriesName: seriesName, seriesId: seriesId,
            seasonName: seasonName, indexNumber: episodeNumber,
            parentIndexNumber: seasonNumber,
            userData: ud, imageBlurHashes: nil,
            primaryImageAspectRatio: primaryImageAspectRatio, genres: genres,
            officialRating: officialRating, taglines: taglines, people: nil,
            premiereDate: premiereDate, mediaStreams: nil, mediaSources: nil,
            childCount: nil, providerIds: nil,
            endDate: nil, productionLocations: nil, imageTags: nil, backdropImageTags: nil,
            channelNumber: nil, currentProgram: nil
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
        loadResumeDataFromDisk()
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
        // Pro-only feature
        guard appState.isPro else {
            appState.showPaywall = true
            return
        }
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
            runTimeTicks: item.runTimeTicks,
            overview: item.overview, productionYear: item.productionYear,
            communityRating: item.communityRating, officialRating: item.officialRating,
            genres: item.genres, premiereDate: item.premiereDate,
            primaryImageAspectRatio: item.primaryImageAspectRatio,
            seasonName: item.seasonName, taglines: item.taglines
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

        // Cache poster/backdrop for offline display
        downloadPoster(itemId: item.id, serverURL: appState.serverURL, token: appState.token)
        if let seriesId = item.seriesId {
            downloadSeriesPoster(seriesId: seriesId, serverURL: appState.serverURL, token: appState.token)
        }

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
        // Progressive transcodes advertise Accept-Ranges: none; pausing by cancellation
        // cannot preserve their partial file. Only original-file downloads can pause.
        guard let active = activeTasks[itemId], !active.isPaused, !active.isTranscoding else { return }
        metaLock.lock()
        let meta = pendingMeta[itemId]
        metaLock.unlock()

        let taskURL = active.task.currentRequest?.url?.absoluteString ?? ""
        let snapshotReceived = active.bytesReceived
        let snapshotExpected = active.bytesExpected

        active.task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor [weak self] in
                guard let self, self.activeTasks[itemId]?.task === active.task else { return }
                // Cancel may have removed this task while resume data was being produced.
                // Only the still-current task may restore a resumable download.
                if let data {
                    self.metaLock.withLock {
                        self.resumeDataStore[itemId] = data
                    }
                }
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

        // Credentials of the account that owns this download (may differ from the active one).
        let creds = credentials(for: paused.meta, appState: appState)

        // Build request — use resume data if available, else reconstruct URL
        let urlString = paused.originalURLString
        let storedURL = urlString.isEmpty ? nil : URL(string: urlString)
        guard let storedURL else {
            // If no original URL, rebuild from quality + current token
            guard let rebuilt = rebuildURL(meta: paused.meta,
                                           serverURL: creds?.serverURL ?? appState.serverURL,
                                           token: creds?.token ?? appState.token) else { return }
            pausedItems.removeAll { $0.id == itemId }
            savePausedItems()
            let req = URLRequest(url: rebuilt)
            let entry = QueuedDownload(id: paused.id, name: paused.name, seriesName: paused.seriesName,
                                       isDirect: paused.isDirect, isTranscoding: paused.isTranscoding,
                                       meta: paused.meta, request: req, estimatedBytes: 0)
            if canStartNow(isTranscoding: paused.isTranscoding) { launchTask(for: entry) }
            else { downloadQueue.append(entry) }
            return
        }

        // Stored URLs (and the opaque resume data, which pins the same request) may still
        // carry the legacy `api_key=<old token>` that Server 12 ignores. Re-issue the URL
        // against the owning account's current server address + token as `ApiKey`.
        let url = refreshedDownloadURL(storedURL, meta: paused.meta, creds: creds)
        if url != storedURL {
            // The resume data still targets the old URL/token; it cannot be edited safely,
            // so drop it and restart this download from the beginning (controlled restart).
            metaLock.lock()
            let hadResumeData = resumeDataStore.removeValue(forKey: itemId) != nil
            metaLock.unlock()
            log.info("resume \(itemId, privacy: .public): URL refreshed (\(JellyfinMediaRequestBuilder.masked(storedURL), privacy: .public) → \(JellyfinMediaRequestBuilder.masked(url), privacy: .public)); resumeData discarded=\(hadResumeData)")
        }

        pausedItems.removeAll { $0.id == itemId }
        savePausedItems()

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

    /// Moves a task that ended with a non-2xx HTTP response back to the paused list so the
    /// user can retry with "Resume" (which refreshes the URL/token). No automatic retry loop.
    fileprivate func parkAfterHTTPFailure(itemId: String, meta: DownloadedItem?, originalURLString: String) {
        let active = activeTasks.removeValue(forKey: itemId)
        if !pausedItems.contains(where: { $0.id == itemId }), let meta {
            let p = PausedDownload(id: itemId, name: active?.name ?? meta.name,
                                   seriesName: active?.seriesName ?? meta.seriesName,
                                   seriesId: active?.seriesId ?? meta.seriesId,
                                   isDirect: active?.isDirect ?? (meta.quality == "Direct"),
                                   isTranscoding: active?.isTranscoding ?? (meta.quality != "Direct"),
                                   meta: meta, originalURLString: originalURLString)
            pausedItems.append(p)
            if !downloadOrder.contains(itemId) { downloadOrder.append(itemId) }
        }
        savePausedItems()
        drainQueue()
    }

    private func rebuildURL(meta: DownloadedItem, serverURL: String, token: String) -> URL? {
        if meta.quality == "Direct" {
            return Self.directURL(itemId: meta.id, serverURL: serverURL, token: token)
        } else if let bitrate = bitrateForLabel(meta.quality) {
            return Self.transcodedURL(itemId: meta.id, serverURL: serverURL,
                                      token: token, maxBitrate: bitrate)
        }
        return nil
    }

    /// Server address + token of the account that started the download (`meta.serverURL`,
    /// `meta.userId`). The active session is preferred when it is the same user on the same
    /// server (also via another saved URL of that server); otherwise the saved account's
    /// Keychain token is used. Returns nil when no matching account is known.
    private func credentials(for meta: DownloadedItem, appState: AppState) -> (serverURL: String, token: String)? {
        let owner = appState.savedAccounts.first { $0.userId == meta.userId && $0.serverURL == meta.serverURL }
        if meta.userId == appState.userId, !appState.token.isEmpty, !appState.serverURL.isEmpty {
            if meta.serverURL == appState.serverURL {
                return (appState.serverURL, appState.token)
            }
            if let sid = owner?.serverId, !sid.isEmpty, sid == appState.serverId {
                return (appState.serverURL, appState.token)
            }
        }
        if let owner, let token = KeychainService.shared.getToken(forAccountId: owner.tokenKey), !token.isEmpty {
            return (owner.serverURL, token)
        }
        return nil
    }

    /// Re-issues a stored download URL with current credentials. Keeps every original query
    /// parameter (quality, audio track …); only the server address and the token change.
    private func refreshedDownloadURL(_ stored: URL, meta: DownloadedItem,
                                      creds: (serverURL: String, token: String)?) -> URL {
        guard let creds else {
            // Owning account unknown: keep the stored URL but move a legacy `api_key`
            // value to `ApiKey` (same token) so Server 12 accepts it.
            return JellyfinMediaRequestBuilder.upgradingLegacyToken(stored)
        }
        let rebased = JellyfinMediaRequestBuilder.rebase(stored, from: meta.serverURL, to: creds.serverURL)
            ?? JellyfinMediaRequestBuilder.rebase(stored, from: creds.serverURL, to: creds.serverURL)
            ?? rebuildURL(meta: meta, serverURL: creds.serverURL, token: creds.token)
        guard let rebased else { return JellyfinMediaRequestBuilder.upgradingLegacyToken(stored) }
        return JellyfinMediaRequestBuilder.authorizedURL(rebased, serverURL: creds.serverURL,
                                                         token: creds.token, replaceExisting: true)
    }

    // MARK: - Cancel / Delete

    func cancelDownload(_ itemId: String) {
        // Active downloads also have a pausedItems entry for kill recovery. Always
        // clear every state; removing that entry alone does not cancel the transfer.
        downloadOrder.removeAll { $0 == itemId }
        downloadQueue.removeAll { $0.id == itemId }
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

        // Delete subtitle + poster files (e.g. {itemId}_tur_3.srt, {itemId}_poster.jpg …)
        let subPattern = "\(itemId)_"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: Self.downloadsDirectory.path) {
            for file in files where file.hasPrefix(subPattern) && !file.hasSuffix(".mp4") {
                try? FileManager.default.removeItem(at: Self.downloadsDirectory.appendingPathComponent(file))
            }
        }

        // Clear URLCache entries for this item (video stream + image URLs)
        URLCache.shared.removeCachedResponses(since: .distantPast)

        downloads.removeAll { $0.id == itemId }
        saveMetadata()
        drainQueue()
    }

    func deleteAllDownloads() {
        for item in downloads {
            activeTasks[item.id]?.task.cancel()
        }
        activeTasks.removeAll()
        downloadQueue.removeAll()
        pausedItems.removeAll()
        downloadOrder.removeAll()
        metaLock.lock()
        pendingMeta.removeAll()
        resumeDataStore.removeAll()
        metaLock.unlock()
        savePausedItems()

        try? FileManager.default.removeItem(at: Self.downloadsDirectory)
        try? FileManager.default.createDirectory(at: Self.downloadsDirectory, withIntermediateDirectories: true)

        URLCache.shared.removeAllCachedResponses()
        downloads.removeAll()
        saveMetadata()
    }

    // MARK: - Poster Cache

    /// Downloads poster, backdrop, and logo images to local storage for offline display.
    func downloadPoster(itemId: String, serverURL: String, token: String) {
        Task {
            // Primary poster
            if let url = JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: itemId, imageType: "Primary", maxWidth: 400) {
                await Self.downloadImage(url: url, destName: "\(itemId)_poster.jpg", serverURL: serverURL, token: token)
            }
            // Backdrop
            if let url = JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: itemId, imageType: "Backdrop", maxWidth: 800) {
                await Self.downloadImage(url: url, destName: "\(itemId)_backdrop.jpg", serverURL: serverURL, token: token)
            }
            // Logo
            if let url = JellyfinAPI.shared.logoURL(serverURL: serverURL, itemId: itemId) {
                await Self.downloadImage(url: url, destName: "\(itemId)_logo.png", serverURL: serverURL, token: token)
            }
        }
    }

    /// Downloads poster, backdrop, and logo for series (used by episode downloads).
    func downloadSeriesPoster(seriesId: String, serverURL: String, token: String) {
        let posterDest = "\(seriesId)_poster.jpg"
        let backdropDest = "\(seriesId)_backdrop.jpg"
        let logoDest = "\(seriesId)_logo.png"
        // Skip if already cached
        guard !FileManager.default.fileExists(atPath: Self.downloadsDirectory.appendingPathComponent(posterDest).path) else { return }
        Task {
            if let url = JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: seriesId, imageType: "Primary", maxWidth: 400) {
                await Self.downloadImage(url: url, destName: posterDest, serverURL: serverURL, token: token)
            }
            if let url = JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: seriesId, imageType: "Backdrop", maxWidth: 800) {
                await Self.downloadImage(url: url, destName: backdropDest, serverURL: serverURL, token: token)
            }
            if let url = JellyfinAPI.shared.logoURL(serverURL: serverURL, itemId: seriesId) {
                await Self.downloadImage(url: url, destName: logoDest, serverURL: serverURL, token: token)
            }
        }
    }

    /// Foreground URLSession request → token travels only in the `Authorization` header.
    private static func downloadImage(url: URL, destName: String, serverURL: String, token: String) async {
        let req = JellyfinMediaRequestBuilder.authorizedRequest(url: url, serverURL: serverURL, token: token)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status >= 200, status < 300, !data.isEmpty else { return }
            let dest = downloadsDirectory.appendingPathComponent(destName)
            try data.write(to: dest)
        } catch {
            Logger(subsystem: "JellyGo", category: "DownloadManager").error("savePosterToDisk failed: \(error)")
        }
    }

    /// Returns local poster URL if cached, nil otherwise.
    static func localPosterURL(itemId: String) -> URL? {
        // Called from view bodies (episode lists in the player); a disk check on every
        // redraw showed up in profiles, so answers are cached. Hits never go stale; misses
        // are re-checked after a few seconds in case the poster was just downloaded.
        let now = Date()
        if let hit = posterLookupCache[itemId], hit.url != nil || now.timeIntervalSince(hit.checked) < 5 {
            return hit.url
        }
        let url = downloadsDirectory.appendingPathComponent("\(itemId)_poster.jpg")
        let found = FileManager.default.fileExists(atPath: url.path) ? url : nil
        posterLookupCache[itemId] = (found, now)
        return found
    }
    nonisolated(unsafe) private static var posterLookupCache: [String: (url: URL?, checked: Date)] = [:]

    /// Returns local backdrop URL if cached, nil otherwise.
    static func localBackdropURL(itemId: String) -> URL? {
        let url = downloadsDirectory.appendingPathComponent("\(itemId)_backdrop.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns local logo URL if cached, nil otherwise.
    static func localLogoURL(itemId: String) -> URL? {
        let url = downloadsDirectory.appendingPathComponent("\(itemId)_logo.png")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns local person photo URL if cached, nil otherwise.
    static func localPersonURL(personId: String) -> URL? {
        let url = downloadsDirectory.appendingPathComponent("\(personId)_person.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns local user avatar URL if cached, nil otherwise.
    static func localUserAvatarURL(userId: String) -> URL? {
        let url = downloadsDirectory.appendingPathComponent("\(userId)_avatar.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Downloads and caches the user's profile image for offline display.
    func downloadUserAvatar(userId: String, serverURL: String, token: String) {
        let destName = "\(userId)_avatar.jpg"
        let dest = Self.downloadsDirectory.appendingPathComponent(destName)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }
        guard let url = JellyfinMediaRequestBuilder.url(
            serverURL: serverURL, path: "Users/\(userId)/Images/Primary",
            queryItems: [URLQueryItem(name: "maxWidth", value: "80")]) else { return }
        Task {
            await Self.downloadImage(url: url, destName: destName, serverURL: serverURL, token: token)
        }
    }

    /// Downloads cast/crew photos for offline display.
    func downloadPeople(_ people: [JellyfinPerson], serverURL: String, token: String) {
        Task {
            for person in people.prefix(15) {
                guard person.primaryImageTag != nil else { continue }
                let dest = "\(person.id)_person.jpg"
                guard !FileManager.default.fileExists(atPath: Self.downloadsDirectory.appendingPathComponent(dest).path) else { continue }
                if let url = JellyfinAPI.shared.personImageURL(serverURL: serverURL, person: person) {
                    await Self.downloadImage(url: url, destName: dest, serverURL: serverURL, token: token)
                }
            }
        }
    }

    // MARK: - Item Details Cache

    /// Saves full JellyfinItem JSON for offline detail view.
    static func saveItemDetails(_ item: JellyfinItem) {
        let dest = downloadsDirectory.appendingPathComponent("\(item.id)_details.json")
        if let data = try? JSONEncoder().encode(item) {
            try? data.write(to: dest)
        }
    }

    /// Loads cached JellyfinItem details from disk.
    static func loadItemDetails(itemId: String) -> JellyfinItem? {
        let url = downloadsDirectory.appendingPathComponent("\(itemId)_details.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JellyfinItem.self, from: data)
    }

    // MARK: - Subtitles

    func downloadSubtitles(itemId: String, mediaSourceId: String, streams: [JellyfinMediaStream], serverURL: String, token: String) {
        for stream in streams {
            let lang = stream.language ?? "und"
            // Try SRT → VTT → ASS fallback (same as streaming player)
            Task {
                await Self.downloadSubtitleWithFallback(
                    itemId: itemId, mediaSourceId: mediaSourceId,
                    streamIndex: stream.index, lang: lang,
                    serverURL: serverURL, token: token
                )
            }
        }
    }

    /// Tries downloading a subtitle in SRT, then VTT, then ASS format.
    private static func downloadSubtitleWithFallback(
        itemId: String, mediaSourceId: String, streamIndex: Int,
        lang: String, serverURL: String, token: String
    ) async {
        let formats = ["srt", "vtt", "ass"]
        for format in formats {
            guard let url = subtitleURL(serverURL: serverURL, itemId: itemId,
                                        mediaSourceId: mediaSourceId,
                                        streamIndex: streamIndex, token: token,
                                        format: format) else { continue }
            // Foreground URLSession request → header only (subtitleURL carries no query token).
            let req = JellyfinMediaRequestBuilder.authorizedRequest(url: url, serverURL: serverURL, token: token)
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                guard status >= 200, status < 300, !data.isEmpty else { continue }
                // Save with .srt extension always — our parser handles all formats
                let destURL = downloadsDirectory.appendingPathComponent("\(itemId)_\(lang)_\(streamIndex).srt")
                try? FileManager.default.removeItem(at: destURL)
                try data.write(to: destURL)
                return // success
            } catch {
                continue
            }
        }
    }

    // MARK: - URL Builders

    // Download URLs run in the *background* URLSession. The token stays in the query as
    // `ApiKey` there (not a header): nsurlsessiond owns the request across app relaunches and
    // the opaque resume data pins it, and `Authorization` is on Apple's list of headers the
    // URL loading system may manage itself. Keeping the token in the URL also lets
    // `resumeDownload` detect and refresh stale credentials from `originalURLString`.

    static func directURL(itemId: String, serverURL: String, token: String) -> URL? {
        JellyfinMediaRequestBuilder.mediaURL(
            serverURL: serverURL, path: "Videos/\(itemId)/stream",
            queryItems: [URLQueryItem(name: "static", value: "true")],
            token: token)
    }

    /// Subtitle file URL **without** a token. Both callers fetch it with URLSession and
    /// authenticate via the `Authorization` header (`JellyfinMediaRequestBuilder.authorizedRequest`
    /// / `SubtitleManager.load`). `token` is kept for source compatibility.
    static func subtitleURL(serverURL: String, itemId: String, mediaSourceId: String,
                            streamIndex: Int, token: String, format: String = "srt") -> URL? {
        JellyfinMediaRequestBuilder.url(
            serverURL: serverURL,
            path: "Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/0/Stream.\(format)")
    }

    static func transcodedURL(itemId: String, serverURL: String, token: String, maxBitrate: Int, audioStreamIndex: Int? = nil) -> URL? {
        var items = [
            // Downloads are played by the user's engine; VLC can't decode AV1 in hardware.
            URLQueryItem(name: "VideoCodec",       value: JellyfinMediaRequestBuilder.transcodingVideoCodecs(
                allowAV1: AppState.shared?.playerEngine != .vlc)),
            URLQueryItem(name: "AudioCodec",       value: "aac"),
            URLQueryItem(name: "VideoBitrate",     value: "\(maxBitrate)"),
            URLQueryItem(name: "AudioBitrate",     value: "128000"),
            URLQueryItem(name: "MaxAudioChannels", value: "2"),
            URLQueryItem(name: "Static",           value: "false"),
        ]
        if let idx = audioStreamIndex {
            items.append(URLQueryItem(name: "AudioStreamIndex", value: "\(idx)"))
        }
        return JellyfinMediaRequestBuilder.mediaURL(
            serverURL: serverURL, path: "Videos/\(itemId)/stream.mp4",
            queryItems: items, token: token)
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
        // Persist resume data alongside paused items
        saveResumeDataToDisk()
    }

    // MARK: Resume Data Persistence

    private static var resumeDataDirectory: URL {
        downloadsDirectory.appendingPathComponent("ResumeData", isDirectory: true)
    }

    private func saveResumeDataToDisk() {
        let dir = Self.resumeDataDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Save each resume data blob
        metaLock.lock()
        let store = resumeDataStore
        metaLock.unlock()

        // Remove old files that are no longer in the store
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for file in existing {
                let itemId = file.replacingOccurrences(of: ".resume", with: "")
                if store[itemId] == nil {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
                }
            }
        }

        for (itemId, data) in store {
            let fileURL = dir.appendingPathComponent("\(itemId).resume")
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func loadResumeDataFromDisk() {
        let dir = Self.resumeDataDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        metaLock.lock()
        for file in files where file.hasSuffix(".resume") {
            let itemId = String(file.dropLast(7)) // remove ".resume"
            if let data = try? Data(contentsOf: dir.appendingPathComponent(file)) {
                resumeDataStore[itemId] = data
            }
        }
        metaLock.unlock()
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

        // URLSession delivers HTTP error bodies (e.g. 401 for a stale / legacy token after
        // Server 12 disabled `api_key`) as a "finished" download. Never store such a body as
        // the media file: drop it and the resume data, and park the item as paused so
        // "Resume" re-issues the URL with current credentials (controlled restart).
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let status = http.statusCode
            let failedURL = downloadTask.originalRequest?.url?.absoluteString ?? ""
            log.error("download \(itemId, privacy: .public) HTTP \(status) for \(JellyfinMediaRequestBuilder.masked(failedURL), privacy: .public) — not saved, parked as paused")
            try? FileManager.default.removeItem(at: location)
            metaLock.lock()
            let meta = pendingMeta.removeValue(forKey: itemId)
            resumeDataStore.removeValue(forKey: itemId)
            metaLock.unlock()
            Task { @MainActor [weak self] in
                self?.parkAfterHTTPFailure(itemId: itemId, meta: meta, originalURLString: failedURL)
            }
            return
        }

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

            Task { @MainActor [weak self] in
                guard let self else { return }
                downloads.append(finalItem)
                activeTasks.removeValue(forKey: itemId)
                pausedItems.removeAll { $0.id == itemId }
                downloadOrder.removeAll { $0 == itemId }
                savePausedItems()
                saveMetadata()
                drainQueue()
            }
        } catch {
            Task { @MainActor [weak self] in
                guard let self else { return }
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

        Task { @MainActor [weak self] in
            guard let self else { return }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            activeTasks[itemId]?.isFailed = true
            saveResumeDataToDisk()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
