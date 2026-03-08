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
    private let clientVersion = "1.0.0"
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

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JellyfinAPIError.decodingError(error)
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw JellyfinAPIError.networkError(URLError(.badServerResponse))
            }
            switch http.statusCode {
            case 200...299: return data
            case 401:       throw JellyfinAPIError.unauthorized
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
        var components = URLComponents(url: base.appendingPathComponent("Users/\(userId)/Items/\(itemId)"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Fields", value: "Genres,People,Taglines,OfficialRating,CriticRating,Overview,UserData,RunTimeTicks,PremiereDate,MediaStreams,ChildCount")
        ]
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItem.self, from: data)
    }

    func setFavorite(serverURL: String, itemId: String, userId: String, token: String, isFavorite: Bool) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("Users/\(userId)/FavoriteItems/\(itemId)")
        var req = baseRequest(url: url, token: token)
        req.httpMethod = isFavorite ? "POST" : "DELETE"
        _ = try await perform(req)
    }

    func setPlayed(serverURL: String, itemId: String, userId: String, token: String, played: Bool) async throws {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        let url = base.appendingPathComponent("Users/\(userId)/PlayedItems/\(itemId)")
        var req = baseRequest(url: url, token: token)
        req.httpMethod = played ? "POST" : "DELETE"
        _ = try await perform(req)
    }

    func personImageURL(serverURL: String, person: JellyfinPerson, maxWidth: Int = 200) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(person.id)/Images/Primary"), resolvingAgainstBaseURL: false)
        var items: [URLQueryItem] = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        if let tag = person.primaryImageTag {
            items.append(URLQueryItem(name: "tag", value: tag))
        }
        components?.queryItems = items
        return components?.url
    }

    // MARK: - Libraries

    func getLibraries(serverURL: String, userId: String, token: String) async throws -> [JellyfinLibrary] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Users/\(userId)/Views"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "PrimaryImageAspectRatio")]
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
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
        recursive: Bool = false
    ) async throws -> JellyfinItemsResponse {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Users/\(userId)/Items"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "SortBy", value: sortBy),
            URLQueryItem(name: "SortOrder", value: sortOrder),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "Recursive", value: recursive ? "true" : "false"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks")
        ]
        if let parentId { queryItems.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let types = itemTypes { queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ","))) }
        components.queryItems = queryItems
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data)
    }

    func getContinueWatching(serverURL: String, userId: String, token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Users/\(userId)/Items/Resume"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks"),
            URLQueryItem(name: "MediaTypes", value: "Video")
        ]
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data).items
    }

    func getNextUp(serverURL: String, userId: String, token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Shows/NextUp"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks")
        ]
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode(JellyfinItemsResponse.self, from: data).items
    }

    func getLatestMedia(serverURL: String, userId: String, token: String, libraryId: String? = nil) async throws -> [JellyfinItem] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Users/\(userId)/Items/Latest"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "Limit", value: "16"),
            URLQueryItem(name: "Fields", value: "Overview,PrimaryImageAspectRatio,UserData,RunTimeTicks")
        ]
        if let libraryId { queryItems.append(URLQueryItem(name: "ParentId", value: libraryId)) }
        components.queryItems = queryItems
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode([JellyfinItem].self, from: data)
    }

    // MARK: - Search

    func search(serverURL: String, userId: String, token: String, query: String) async throws -> [JellyfinSearchHint] {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Search/Hints"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: "30"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")
        ]
        let req = baseRequest(url: components.url!, token: token)
        let data = try await perform(req)
        return try decode(JellyfinSearchResponse.self, from: data).searchHints
    }

    // MARK: - Playback

    func getPlaybackInfo(serverURL: String, itemId: String, userId: String, token: String, startTimeTicks: Int64 = 0) async throws -> JellyfinPlaybackInfo {
        guard let base = URL(string: serverURL) else { throw JellyfinAPIError.invalidURL }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/PlaybackInfo"), resolvingAgainstBaseURL: false)!
        var queryItems: [URLQueryItem] = [URLQueryItem(name: "UserId", value: userId)]
        if startTimeTicks > 0 {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: "\(startTimeTicks)"))
        }
        components.queryItems = queryItems
        var req = baseRequest(url: components.url!, token: token)
        req.httpMethod = "POST"

        // Device profile: direct play MP4/H264/HEVC, fallback to HLS transcode
        let profile: [String: Any] = [
            "UserId": userId,
            "DeviceProfile": [
                "MaxStaticBitrate": 100_000_000,
                "MaxStreamingBitrate": 120_000_000,
                "DirectPlayProfiles": [
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
                "SubtitleProfiles": [
                    ["Format": "vtt", "Method": "Hls"],
                    ["Format": "ass", "Method": "Hls"],
                    ["Format": "ssa", "Method": "Hls"],
                    ["Format": "srt", "Method": "Hls"]
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

    func imageURL(serverURL: String, itemId: String, imageType: String = "Primary", maxWidth: Int = 400) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/\(imageType)"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    func backdropURL(serverURL: String, itemId: String, maxWidth: Int = 1280) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Backdrop"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }

    func logoURL(serverURL: String, itemId: String, maxWidth: Int = 600) -> URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Logo"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        return components?.url
    }
}
