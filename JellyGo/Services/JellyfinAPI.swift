import Foundation

// MARK: - Errors

enum JellyfinAPIError: LocalizedError {
    case invalidURL
    case networkError(Error)
    case unauthorized
    case serverError(Int)
    case decodingError(Error)
    case notAJellyfinServer

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("Geçersiz sunucu adresi", comment: "")
        case .networkError(let e):
            return String(format: NSLocalizedString("Bağlantı hatası: %@", comment: ""), e.localizedDescription)
        case .unauthorized:
            return NSLocalizedString("Kullanıcı adı veya şifre hatalı", comment: "")
        case .serverError(let c):
            return String(format: NSLocalizedString("Sunucu hatası: %d", comment: ""), c)
        case .decodingError:
            return NSLocalizedString("Sunucu yanıtı okunamadı", comment: "")
        case .notAJellyfinServer:
            return NSLocalizedString("Bu adres bir Jellyfin sunucusu değil", comment: "")
        }
    }
}

// MARK: - API Client

final class JellyfinAPI {
    static let shared = JellyfinAPI()

    private let clientName = "JellyGo"
    private let clientVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    private let deviceName = "iPhone"

    private lazy var deviceId: String = {
        if let stored = UserDefaults.standard.string(forKey: "jellygo.deviceId") {
            return stored
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "jellygo.deviceId")
        return newId
    }()

    private init() {}

    // MARK: - Helpers

    private func authHeader(token: String? = nil) -> String {
        var h = "MediaBrowser Client=\"\(clientName)\", Device=\"\(deviceName)\", DeviceId=\"\(deviceId)\", Version=\"\(clientVersion)\""
        if let token { h += ", Token=\"\(token)\"" }
        return h
    }

    private func baseRequest(url: URL, token: String? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return req
    }

    private func buildURL(_ base: URL, path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw JellyfinAPIError.invalidURL
        }
        if !queryItems.isEmpty { comps.queryItems = queryItems }
        guard let url = comps.url else { throw JellyfinAPIError.invalidURL }
        return url
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JellyfinAPIError.decodingError(error)
        }
    }

    private func perform(_ request: URLRequest, cacheTTL: TimeInterval? = nil) async throws -> Data {
        // Block all API calls when manual offline mode is active
        if await MainActor.run(body: { AppState.shared?.manualOffline ?? false }) {
            throw JellyfinAPIError.networkError(URLError(.notConnectedToInternet))
        }

        // Cache lookup — sadece GET istekleri için
        let isGet = request.httpMethod == nil || request.httpMethod == "GET"
        if let ttl = cacheTTL, isGet, let url = request.url,
           let cached = APICache.shared.get(for: url) {
            return cached
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JellyfinAPIError.networkError(URLError(.badServerResponse))
            }
            switch http.statusCode {
            case 200...299:
                // Cache'e yaz
                if let ttl = cacheTTL, isGet, let url = request.url {
                    APICache.shared.set(data, for: url, ttl: ttl)
                }
                return data
            case 401, 403:  throw JellyfinAPIError.unauthorized
            default:        throw JellyfinAPIError.serverError(http.statusCode)
            }
        } catch let error as JellyfinAPIError {
            throw error
        } catch {
            throw JellyfinAPIError.networkError(error)
        }
    }

    // MARK: - Auth

    func checkServer(url: String) async throws -> JellyfinServerInfo {
        guard let base = URL(string: url) else { throw JellyfinAPIError.invalidURL }
        let endpoint = base.appendingPathComponent("System/Info/Public")
        let req = baseRequest(url: endpoint)
        do {
            let data = try await perform(req)
            return try decode(JellyfinServerInfo.self, from: data)
        } catch JellyfinAPIError.decodingError {
            throw JellyfinAPIError.notAJellyfinServer
        } catch JellyfinAPIError.serverError {
            throw JellyfinAPIError.notAJellyfinServer
        }
    }

    // MARK: - QuickConnect

    func quickConnectEnabled(serverURL: String) async throws -> Bool {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("QuickConnect/Enabled")
        let req = baseRequest(url: url)
        let data = try await perform(req)
        // Response is a plain JSON boolean: true or false
        return (try? JSONDecoder().decode(Bool.self, from: data)) ?? false
    }

    func quickConnectInitiate(serverURL: String) async throws -> QuickConnectResult {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("QuickConnect/Initiate")
        var req = baseRequest(url: url)
        req.httpMethod = "POST"
        let data = try await perform(req)
        return try decode(QuickConnectResult.self, from: data)
    }

    func quickConnectCheck(serverURL: String, secret: String) async throws -> Bool {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "QuickConnect/Connect", queryItems: [
            URLQueryItem(name: "Secret", value: secret)
        ])
        let req = baseRequest(url: url)
        let data = try await perform(req)
        let result = try decode(QuickConnectResult.self, from: data)
        return result.authenticated
    }

    func quickConnectAuthenticate(serverURL: String, secret: String) async throws -> JellyfinAuthResponse {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("Users/AuthenticateWithQuickConnect")
        var req = baseRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = try? JSONEncoder().encode(["Secret": secret])
        let data = try await perform(req)
        return try decode(JellyfinAuthResponse.self, from: data)
    }

    func quickConnectAuthorize(serverURL: String, code: String, token: String) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "QuickConnect/Authorize", queryItems: [
            URLQueryItem(name: "Code", value: code)
        ])
        var req = baseRequest(url: url, token: token)
        req.httpMethod = "POST"
        _ = try await perform(req)
    }

    func login(serverURL: String, username: String, password: String) async throws -> JellyfinAuthResponse {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let endpoint = base.appendingPathComponent("Users/AuthenticateByName")
        var req = baseRequest(url: endpoint)
        req.httpMethod = "POST"
        req.httpBody = try? JSONEncoder().encode(["Username": username, "Pw": password])
        let data = try await perform(req)
        return try decode(JellyfinAuthResponse.self, from: data)
    }

    // MARK: - Item Details

    func getItemDetails(serverURL: String, itemId: String, userId: String, token: String) async throws -> JellyfinItem {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Users/\(userId)/Items/\(itemId)", queryItems: [
            URLQueryItem(name: "Fields", value: "Genres,People,Taglines,OfficialRating,CommunityRating,CriticRating,Overview,UserData,RunTimeTicks,PremiereDate,EndDate,ProductionLocations,MediaStreams,MediaSources,ChildCount,ProviderIds,ImageTags")
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItem.self, from: data)
    }

    func setFavorite(serverURL: String, itemId: String, userId: String, token: String, isFavorite: Bool) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("Users/\(userId)/FavoriteItems/\(itemId)")
        var req = baseRequest(url: url, token: token)
        req.httpMethod = isFavorite ? "POST" : "DELETE"
        _ = try await perform(req)
        APICache.shared.invalidate(itemId: itemId)
    }

    func setPlayed(serverURL: String, itemId: String, userId: String, token: String, played: Bool) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("Users/\(userId)/PlayedItems/\(itemId)")
        var req = baseRequest(url: url, token: token)
        req.httpMethod = played ? "POST" : "DELETE"
        _ = try await perform(req)

        // When marking as unwatched, also reset playback position
        if !played {
            try? await resetPlaybackPosition(serverURL: serverURL, itemId: itemId, userId: userId, token: token)
        }

        APICache.shared.invalidate(itemId: itemId)
    }

    func resetPlaybackPosition(serverURL: String, itemId: String, userId: String, token: String) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }

        // 1. Report playback start
        let startURL = base.appendingPathComponent("Sessions/Playing")
        var startReq = baseRequest(url: startURL, token: token)
        startReq.httpMethod = "POST"
        startReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        startReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "ItemId": itemId,
            "PositionTicks": 0
        ])
        _ = try? await perform(startReq)

        // 2. Report playback stopped at 0
        let stopURL = base.appendingPathComponent("Sessions/Playing/Stopped")
        var stopReq = baseRequest(url: stopURL, token: token)
        stopReq.httpMethod = "POST"
        stopReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        stopReq.httpBody = try JSONSerialization.data(withJSONObject: [
            "ItemId": itemId,
            "PositionTicks": 0
        ])
        _ = try? await perform(stopReq)
    }

    func personImageURL(serverURL: String, person: JellyfinPerson, maxWidth: Int = 200) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(person.id)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    // MARK: - Libraries

    func getLibraries(serverURL: String, userId: String, token: String) async throws -> [JellyfinLibrary] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Users/\(userId)/Views", queryItems: [
            URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio")
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req, cacheTTL: 24 * 3600)  // 24 saat
        let response = try decode(JellyfinLibrariesResponse.self, from: data)
        return response.items
    }

    // MARK: - Items

    func getItems(
        serverURL: String,
        userId: String,
        token: String,
        parentId: String? = nil,
        itemTypes: [String]? = nil,
        sortBy: String = "SortName",
        sortOrder: String = "Ascending",
        startIndex: Int = 0,
        limit: Int = 50,
        recursive: Bool = false,
        filters: String? = nil,
        genres: [String]? = nil
    ) async throws -> JellyfinItemsResponse {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks,MediaStreams,MediaSources,Genres,OfficialRating,ImageTags")
        ]
        if let parentId { queryItems.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let types = itemTypes { queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ","))) }
        if let filters { queryItems.append(URLQueryItem(name: "Filters", value: filters)) }
        if let genres, !genres.isEmpty { queryItems.append(URLQueryItem(name: "Genres", value: genres.joined(separator: ","))) }
        let url = try buildURL(base, path: "Users/\(userId)/Items", queryItems: queryItems)
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data)
    }

    func getContinueWatching(serverURL: String, userId: String, token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Users/\(userId)/Items/Resume", queryItems: [
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks,MediaStreams,MediaSources,Genres,OfficialRating,ImageTags"),
            URLQueryItem(name: "MediaTypes", value: "Video")
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data).items
    }

    func getNextUp(serverURL: String, userId: String, token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Shows/NextUp", queryItems: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks,MediaStreams,MediaSources,Genres,OfficialRating,ImageTags")
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data).items
    }

    func getLatestMedia(serverURL: String, userId: String, token: String, libraryId: String? = nil, includeItemTypes: [String]? = nil) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "Limit", value: "16"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks,MediaStreams,MediaSources,Genres,OfficialRating,ImageTags")
        ]
        if let libraryId { queryItems.append(URLQueryItem(name: "ParentId", value: libraryId)) }
        if let types = includeItemTypes { queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ","))) }
        let url = try buildURL(base, path: "Users/\(userId)/Items/Latest", queryItems: queryItems)
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req, cacheTTL: 30 * 60)    // 30 dakika
        return try decode([JellyfinItem].self, from: data)
    }

    // MARK: - Search

    func search(serverURL: String, userId: String, token: String, query: String) async throws -> [JellyfinSearchHint] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Search/Hints", queryItems: [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "30"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req)
        return try decode(JellyfinSearchResponse.self, from: data).searchHints
    }

    // MARK: - Playback

    func getPlaybackInfo(serverURL: String, itemId: String, userId: String, token: String, startTimeTicks: Int64 = 0, maxBitrate: Int? = nil, externalSubtitles: Bool = false, audioStreamIndex: Int? = nil, forceTranscode: Bool = false) async throws -> JellyfinPlaybackInfo {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "UserId", value: userId)]
        if startTimeTicks > 0 {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: "\(startTimeTicks)"))
        }
        if let idx = audioStreamIndex {
            queryItems.append(URLQueryItem(name: "AudioStreamIndex", value: "\(idx)"))
        }
        if externalSubtitles {
            queryItems.append(URLQueryItem(name: "SubtitleStreamIndex", value: "-1"))
        }
        let url = try buildURL(base, path: "Items/\(itemId)/PlaybackInfo", queryItems: queryItems)
        var req = baseRequest(url: url, token: token)
        req.httpMethod = "POST"

        // Device profile: direct play MP4/H264/HEVC, fallback to HLS transcode
        let subMethod = externalSubtitles ? "External" : "Hls"
        let profile: [String: Any] = [
            "UserId": userId,
            "DeviceProfile": [
                "MaxStaticBitrate": 100_000_000,
                "MaxStreamingBitrate": maxBitrate ?? 120_000_000,
                "DirectPlayProfiles": forceTranscode ? [] as [[String: String]] : [
                    [
                        "Container": "mp4,m4v,mov,m2ts,ts",
                        "Type": "Video",
                        "VideoCodec": "h264,hevc,h265",
                        "AudioCodec": "aac,mp3,ac3,eac3,flac,alac,opus"
                    ]
                ],
                "TranscodingProfiles": [
                    [
                        "Container": "ts",
                        "Type": "Video",
                        "VideoCodec": "h264",
                        "AudioCodec": "aac",
                        "Protocol": "hls",
                        "Context": "Streaming",
                        "MaxAudioChannels": "6"
                    ]
                ],
                "CodecProfiles": [
                    [
                        "Type": "Video",
                        "Codec": "hevc",
                        "Conditions": [
                            [
                                "Condition": "NotEquals",
                                "Property": "VideoRangeType",
                                "Value": "DOVI",
                                "IsRequired": true
                            ]
                        ]
                    ]
                ],
                "SubtitleProfiles": externalSubtitles
                    ? [] as [[String: String]]   // No subtitle support → server won't burn-in any subs
                    : [
                        ["Format": "vtt", "Method": "Hls"],
                        ["Format": "ass", "Method": "Hls"],
                        ["Format": "ssa", "Method": "Hls"],
                        ["Format": "srt", "Method": "Hls"],
                        ["Format": "pgssub", "Method": "Encode"],
                        ["Format": "dvdsub", "Method": "Encode"],
                        ["Format": "dvbsub", "Method": "Encode"],
                        ["Format": "sub", "Method": "Encode"]
                    ],
                "ResponseProfiles": [
                    ["Type": "Video", "Container": "m4v", "MimeType": "video/mp4"]
                ]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: profile)
        let data = try await perform(req)
        return try decode(JellyfinPlaybackInfo.self, from: data)
    }

    func streamURL(serverURL: String, itemId: String, mediaSourceId: String, token: String) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Videos/\(itemId)/stream"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "api_key", value: token)
        ]
        return components?.url
    }

    // MARK: - Progress Reporting

    func reportPlaybackStart(serverURL: String, itemId: String, token: String) async {
        guard let base = URL(string: serverURL) else { return }
        var req = baseRequest(url: base.appendingPathComponent("Sessions/Playing"), token: token)
        req.httpMethod = "POST"
        req.httpBody = try? JSONEncoder().encode(["ItemId": itemId])
        _ = try? await URLSession.shared.data(for: req)
    }

    func reportPlaybackProgress(serverURL: String, itemId: String, positionTicks: Int64, isPaused: Bool, token: String) async {
        guard let base = URL(string: serverURL) else { return }
        var req = baseRequest(url: base.appendingPathComponent("Sessions/Playing/Progress"), token: token)
        req.httpMethod = "POST"
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    func reportPlaybackStopped(serverURL: String, itemId: String, positionTicks: Int64, token: String) async {
        guard let base = URL(string: serverURL) else { return }
        var req = baseRequest(url: base.appendingPathComponent("Sessions/Playing/Stopped"), token: token)
        req.httpMethod = "POST"
        let body: [String: Any] = ["ItemId": itemId, "PositionTicks": positionTicks]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    func subtitleURL(serverURL: String, itemId: String, mediaSourceId: String, subtitleIndex: Int, format: String = "vtt") -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        return base.appendingPathComponent("Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(subtitleIndex)/Stream.\(format)")
    }

    // MARK: - Image URLs

    /// Returns nil when manual offline is active — prevents AsyncImage from hitting the network.
    private var isOffline: Bool {
        AppState.shared?.manualOffline ?? false
    }

    func imageURL(serverURL: String, itemId: String, imageType: String = "Primary", maxWidth: Int = 400) -> URL? {
        guard !isOffline, let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/\(imageType)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    func backdropURL(serverURL: String, itemId: String, maxWidth: Int = 1280) -> URL? {
        guard !isOffline, let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Backdrop"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    func logoURL(serverURL: String, itemId: String, maxWidth: Int = 600) -> URL? {
        guard !isOffline, let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Logo"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    func refreshItemMetadata(serverURL: String, itemId: String, token: String) async {
        guard let base = URL(string: serverURL) else { return }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Refresh"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "MetadataRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "ImageRefreshMode", value: "FullRefresh"),
            URLQueryItem(name: "ReplaceAllImages", value: "false"),
            URLQueryItem(name: "ReplaceAllMetadata", value: "false"),
        ]
        guard let url = components?.url else { return }
        var req = baseRequest(url: url, token: token)
        req.httpMethod = "POST"
        _ = try? await perform(req)
    }

    func getPersonFilmography(serverURL: String, personId: String, userId: String, token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Users/\(userId)/Items", queryItems: [
            URLQueryItem(name: "PersonIds", value: personId),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "PremiereDate"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,CommunityRating"),
            URLQueryItem(name: "Limit", value: "100"),
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req, cacheTTL: 6 * 3600)   // 6 saat
        let all = try decode(JellyfinItemsResponse.self, from: data).items

        // De-duplicate: prefer Series/Movie over individual episodes
        var seen = Set<String>()
        var result: [JellyfinItem] = []
        for item in all {
            let key = item.seriesId ?? item.id
            if seen.insert(key).inserted {
                result.append(item)
            }
        }
        return result
    }

    func getSimilarItems(serverURL: String, itemId: String, userId: String, token: String, limit: Int = 12) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = try buildURL(base, path: "Items/\(itemId)/Similar", queryItems: [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,CommunityRating"),
        ])
        let req = baseRequest(url: url, token: token)
        let data = try await perform(req, cacheTTL: 6 * 3600)   // 6 saat
        return try decode(JellyfinItemsResponse.self, from: data).items
    }
}
