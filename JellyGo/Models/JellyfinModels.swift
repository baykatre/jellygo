import Foundation

// MARK: - Server

struct JellyfinServerInfo: Codable {
    let serverName: String
    let version: String
    let id: String

    enum CodingKeys: String, CodingKey {
        case serverName = "ServerName"
        case version = "Version"
        case id = "Id"
    }
}

// MARK: - Auth

struct JellyfinAuthResponse: Codable {
    let user: JellyfinUser
    let accessToken: String
    let serverId: String

    enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}

struct JellyfinUser: Codable, Identifiable {
    let id: String
    let name: String
    let serverId: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
    }
}

// MARK: - Libraries

struct JellyfinLibrariesResponse: Codable {
    let items: [JellyfinLibrary]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinLibrary: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let collectionType: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
    }
}

// MARK: - Media Items

struct JellyfinItemsResponse: Codable {
    let items: [JellyfinItem]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinItem: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let overview: String?
    let productionYear: Int?
    let communityRating: Double?
    let criticRating: Double?
    let runTimeTicks: Int64?
    let seriesName: String?
    let seriesId: String?
    let seasonName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let userData: JellyfinUserData?
    let imageBlurHashes: [String: [String: String]]?
    let primaryImageAspectRatio: Double?
    let genres: [String]?
    let officialRating: String?
    let taglines: [String]?
    let people: [JellyfinPerson]?
    let premiereDate: String?
    let mediaStreams: [JellyfinMediaStream]?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case overview = "Overview"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case criticRating = "CriticRating"
        case runTimeTicks = "RunTimeTicks"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case userData = "UserData"
        case imageBlurHashes = "ImageBlurHashes"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case genres = "Genres"
        case officialRating = "OfficialRating"
        case taglines = "Taglines"
        case people = "People"
        case premiereDate = "PremiereDate"
        case mediaStreams = "MediaStreams"
    }

    var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        return Int(ticks / 10_000_000 / 60)
    }

    var videoResolution: String? {
        guard let stream = mediaStreams?.first(where: { $0.isVideo }),
              let height = stream.height else { return nil }
        if height >= 2160 { return "4K" }
        if height >= 1080 { return "1080p" }
        if height >= 720  { return "720p" }
        return "\(height)p"
    }

    var formattedPremiereDate: String? {
        guard let raw = premiereDate else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .none
            out.locale = Locale(identifier: "tr_TR")
            return out.string(from: date)
        }
        return String(raw.prefix(10))
    }

    var isMovie: Bool { type == "Movie" }
    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }
    var isSeason: Bool { type == "Season" }
}

struct JellyfinPerson: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let role: String?
    let type: String
    let primaryImageTag: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
    }
}

struct JellyfinUserData: Codable, Hashable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let isFavorite: Bool?
    let playCount: Int?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case played = "Played"
        case isFavorite = "IsFavorite"
        case playCount = "PlayCount"
    }

    var resumePositionSeconds: Double? {
        guard let ticks = playbackPositionTicks, ticks > 0 else { return nil }
        return Double(ticks) / 10_000_000
    }
}

// MARK: - Playback

struct JellyfinPlaybackInfo: Codable {
    let mediaSources: [JellyfinMediaSource]

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
    }
}

struct JellyfinMediaSource: Codable, Identifiable {
    let id: String
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let mediaStreams: [JellyfinMediaStream]?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let transcodingUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case mediaStreams = "MediaStreams"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case transcodingUrl = "TranscodingUrl"
    }
}

struct JellyfinMediaStream: Codable, Hashable {
    let type: String
    let index: Int
    let language: String?
    let displayTitle: String?
    let codec: String?
    let isDefault: Bool?
    let isExternal: Bool?
    let height: Int?
    let width: Int?

    enum CodingKeys: String, CodingKey {
        case type = "Type"
        case index = "Index"
        case language = "Language"
        case displayTitle = "DisplayTitle"
        case codec = "Codec"
        case isDefault = "IsDefault"
        case isExternal = "IsExternal"
        case height = "Height"
        case width = "Width"
    }

    var isAudio: Bool { type == "Audio" }
    var isSubtitle: Bool { type == "Subtitle" }
    var isVideo: Bool { type == "Video" }
}

// MARK: - Search

struct JellyfinSearchResponse: Codable {
    let searchHints: [JellyfinSearchHint]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case searchHints = "SearchHints"
        case totalRecordCount = "TotalRecordCount"
    }
}

struct JellyfinSearchHint: Codable, Identifiable, Hashable {
    let itemId: String
    let name: String
    let type: String
    let productionYear: Int?
    let series: String?

    var id: String { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case name = "Name"
        case type = "Type"
        case productionYear = "ProductionYear"
        case series = "Series"
    }
}

extension JellyfinItem {
    init(fromHint hint: JellyfinSearchHint) {
        self.id = hint.itemId
        self.name = hint.name
        self.type = hint.type
        self.overview = nil
        self.productionYear = hint.productionYear
        self.communityRating = nil
        self.criticRating = nil
        self.runTimeTicks = nil
        self.seriesName = hint.series
        self.seriesId = nil
        self.seasonName = nil
        self.indexNumber = nil
        self.parentIndexNumber = nil
        self.userData = nil
        self.imageBlurHashes = nil
        self.primaryImageAspectRatio = nil
        self.genres = nil
        self.officialRating = nil
        self.taglines = nil
        self.people = nil
        self.premiereDate = nil
        self.mediaStreams = nil
    }
}
