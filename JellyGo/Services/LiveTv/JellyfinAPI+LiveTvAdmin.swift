import Foundation

// Server-side Live TV setup (Jellyfin 12.4, verified against
// Jellyfin.Api/Controllers/LiveTvController.cs and ConfigurationController.cs):
//
//   GET    /Users/Me                                  [Authorize]          → UserDto.Policy.IsAdministrator
//   GET    /System/Configuration/livetv               [Authorize]          → LiveTvOptions (TunerHosts, ListingProviders)
//   POST   /LiveTv/TunerHosts            body TunerHostInfo     [RequiresElevation]
//   DELETE /LiveTv/TunerHosts?id=…                              [RequiresElevation]
//   POST   /LiveTv/ListingProviders?validateListings=&validateLogin=  body ListingsProviderInfo [RequiresElevation]
//   DELETE /LiveTv/ListingProviders?id=…                        [RequiresElevation]
//
// RequiresElevation = role claim "Administrator" (Jellyfin.Server/Extensions/ApiServiceCollectionExtensions.cs).
// The M3U tuner type is "m3u" (M3UTunerHost.Type), the XMLTV provider type is "xmltv"
// (XmlTvListingsProvider.Type); the XMLTV address goes into ListingsProviderInfo.Path.

nonisolated enum JellyfinLiveTvAdminError: LocalizedError {
    case notAdministrator
    case sessionExpired
    case invalidResponse
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notAdministrator:
            return String(localized: "Only a server administrator can change Live TV sources on the server.", bundle: AppState.currentBundle)
        case .sessionExpired:
            return String(localized: "Your session has expired. Sign in again.", bundle: AppState.currentBundle)
        case .invalidResponse:
            return String(localized: "Could not read server response", bundle: AppState.currentBundle)
        case .server(let code):
            return String(format: String(localized: "Server error: %d", bundle: AppState.currentBundle), code)
        }
    }
}

nonisolated struct JellyfinTunerHost: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let url: String
    let type: String
    let friendlyName: String?
    let userAgent: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", url = "Url", type = "Type", friendlyName = "FriendlyName", userAgent = "UserAgent"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        friendlyName = try c.decodeIfPresent(String.self, forKey: .friendlyName)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
    }
}

nonisolated struct JellyfinListingProvider: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let type: String
    let path: String?
    let listingsId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", type = "Type", path = "Path", listingsId = "ListingsId"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
        path = try c.decodeIfPresent(String.self, forKey: .path)
        listingsId = try c.decodeIfPresent(String.self, forKey: .listingsId)
    }
}

nonisolated struct JellyfinLiveTvServerConfig: Decodable, Sendable {
    let tunerHosts: [JellyfinTunerHost]
    let listingProviders: [JellyfinListingProvider]

    enum CodingKeys: String, CodingKey {
        case tunerHosts = "TunerHosts", listingProviders = "ListingProviders"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tunerHosts = try c.decodeIfPresent([JellyfinTunerHost].self, forKey: .tunerHosts) ?? []
        listingProviders = try c.decodeIfPresent([JellyfinListingProvider].self, forKey: .listingProviders) ?? []
    }
}

private nonisolated struct CurrentUserPolicyDTO: Decodable {
    struct Policy: Decodable {
        let isAdministrator: Bool?
        enum CodingKeys: String, CodingKey { case isAdministrator = "IsAdministrator" }
    }
    let policy: Policy?
    enum CodingKeys: String, CodingKey { case policy = "Policy" }
}

/// Body for POST /LiveTv/TunerHosts. Values not set by the user are the server defaults
/// from TunerHostInfo's constructor.
private nonisolated struct TunerHostBody: Encodable {
    var type = "m3u"
    var url: String
    var friendlyName: String
    var userAgent: String?
    var importFavoritesOnly = false
    var allowHWTranscoding = true
    var allowFmp4TranscodingContainer = false
    var allowStreamSharing = true
    var fallbackMaxStreamingBitrate = 30_000_000
    var enableStreamLooping = false
    var tunerCount = 0
    var ignoreDts = true
    var readAtNativeFramerate = false

    enum CodingKeys: String, CodingKey {
        case type = "Type", url = "Url", friendlyName = "FriendlyName", userAgent = "UserAgent"
        case importFavoritesOnly = "ImportFavoritesOnly", allowHWTranscoding = "AllowHWTranscoding"
        case allowFmp4TranscodingContainer = "AllowFmp4TranscodingContainer", allowStreamSharing = "AllowStreamSharing"
        case fallbackMaxStreamingBitrate = "FallbackMaxStreamingBitrate", enableStreamLooping = "EnableStreamLooping"
        case tunerCount = "TunerCount", ignoreDts = "IgnoreDts", readAtNativeFramerate = "ReadAtNativeFramerate"
    }
}

/// Body for POST /LiveTv/ListingProviders.
private nonisolated struct ListingProviderBody: Encodable {
    var type = "xmltv"
    var path: String
    var enableAllTuners = true

    enum CodingKeys: String, CodingKey {
        case type = "Type", path = "Path", enableAllTuners = "EnableAllTuners"
    }
}

extension JellyfinAPI {

    private func liveTvAdminSend(_ request: URLRequest) async throws -> Data {
        if AppState.shared?.manualOffline ?? false {
            throw JellyfinAPIError.networkError(URLError(.notConnectedToInternet))
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw JellyfinAPIError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else { throw JellyfinLiveTvAdminError.invalidResponse }
        switch http.statusCode {
        case 200...299: return data
        case 401: throw JellyfinLiveTvAdminError.sessionExpired
        case 403: throw JellyfinLiveTvAdminError.notAdministrator
        default: throw JellyfinLiveTvAdminError.server(http.statusCode)
        }
    }

    private func liveTvAdminURL(_ serverURL: String, _ path: String, _ query: [URLQueryItem] = []) throws -> URL {
        guard let url = JellyfinMediaRequestBuilder.url(serverURL: serverURL, path: path, queryItems: query) else {
            throw JellyfinAPIError.invalidURL
        }
        return url
    }

    /// `UserDto.Policy.IsAdministrator` of the signed-in user.
    func currentUserIsAdministrator(serverURL: String, token: String) async throws -> Bool {
        let req = baseRequest(url: try liveTvAdminURL(serverURL, "Users/Me"), token: token)
        let data = try await liveTvAdminSend(req)
        guard let dto = try? JSONDecoder().decode(CurrentUserPolicyDTO.self, from: data) else {
            throw JellyfinLiveTvAdminError.invalidResponse
        }
        return dto.policy?.isAdministrator ?? false
    }

    func getLiveTvServerConfig(serverURL: String, token: String) async throws -> JellyfinLiveTvServerConfig {
        let req = baseRequest(url: try liveTvAdminURL(serverURL, "System/Configuration/livetv"), token: token)
        let data = try await liveTvAdminSend(req)
        guard let config = try? JSONDecoder().decode(JellyfinLiveTvServerConfig.self, from: data) else {
            throw JellyfinLiveTvAdminError.invalidResponse
        }
        return config
    }

    func addM3UTunerHost(serverURL: String, token: String, address: String, name: String, userAgent: String?) async throws {
        var req = baseRequest(url: try liveTvAdminURL(serverURL, "LiveTv/TunerHosts"), token: token)
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(TunerHostBody(url: address, friendlyName: name, userAgent: userAgent))
        _ = try await liveTvAdminSend(req)
    }

    func deleteTunerHost(serverURL: String, token: String, id: String) async throws {
        var req = baseRequest(url: try liveTvAdminURL(serverURL, "LiveTv/TunerHosts", [URLQueryItem(name: "id", value: id)]), token: token)
        req.httpMethod = "DELETE"
        _ = try await liveTvAdminSend(req)
    }

    func addXmlTvListingProvider(serverURL: String, token: String, address: String) async throws {
        var req = baseRequest(url: try liveTvAdminURL(serverURL, "LiveTv/ListingProviders", [
            URLQueryItem(name: "validateListings", value: "false"),
            URLQueryItem(name: "validateLogin", value: "false"),
        ]), token: token)
        req.httpMethod = "POST"
        req.httpBody = try JSONEncoder().encode(ListingProviderBody(path: address))
        _ = try await liveTvAdminSend(req)
    }

    func deleteListingProvider(serverURL: String, token: String, id: String) async throws {
        var req = baseRequest(url: try liveTvAdminURL(serverURL, "LiveTv/ListingProviders", [URLQueryItem(name: "id", value: id)]), token: token)
        req.httpMethod = "DELETE"
        _ = try await liveTvAdminSend(req)
    }
}
