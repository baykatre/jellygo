import SwiftUI
import Combine

@MainActor
final class ExploreViewModel: ObservableObject {
    @Published var featuredItems: [JellyfinItem] = []
    @Published var latestMovies: [JellyfinItem] = []
    @Published var latestSeries: [JellyfinItem] = []
    @Published var topRatedMovies: [JellyfinItem] = []
    @Published var topRatedSeries: [JellyfinItem] = []
    @Published var favorites: [JellyfinItem] = []
    @Published var genreSections: [(genre: String, items: [JellyfinItem])] = []
    @Published var pendingGenres: [String] = []
    @Published var isLoading = false

    var serverURL: String = ""
    private var userId: String = ""
    private var token: String = ""
    private var loadingGenres = Set<String>()

    // MARK: - Load All Sections

    private enum SectionResult {
        case featured([JellyfinItem])
        case latestMovies([JellyfinItem])
        case latestSeries([JellyfinItem])
        case topMovies([JellyfinItem])
        case topSeries([JellyfinItem])
        case favorites([JellyfinItem])
    }

    func load(appState: AppState) async {
        isLoading = true
        genreSections = []
        pendingGenres = []
        loadingGenres = []

        serverURL = appState.serverURL
        userId = appState.userId
        token = appState.token
        let url = serverURL
        let uid = userId
        let tok = token

        await withTaskGroup(of: SectionResult.self) { group in
            group.addTask { .featured((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Movie", "Series"], sortBy: "Random", sortOrder: "Descending",
                limit: 6, recursive: true
            ))?.items ?? []) }

            group.addTask { .latestMovies((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Movie"], sortBy: "DateCreated", sortOrder: "Descending",
                limit: 16, recursive: true
            ))?.items ?? []) }

            group.addTask { .latestSeries((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Series"], sortBy: "DateCreated", sortOrder: "Descending",
                limit: 16, recursive: true
            ))?.items ?? []) }

            group.addTask { .topMovies((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Movie"], sortBy: "CommunityRating", sortOrder: "Descending",
                limit: 16, recursive: true
            ))?.items ?? []) }

            group.addTask { .topSeries((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Series"], sortBy: "CommunityRating", sortOrder: "Descending",
                limit: 16, recursive: true
            ))?.items ?? []) }

            group.addTask { .favorites((try? await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: tok,
                itemTypes: ["Movie", "Series"], sortBy: "SortName",
                limit: 16, recursive: true, filters: "IsFavorite"
            ))?.items ?? []) }

            // UI her section hazır olunca güncellenir
            for await result in group {
                switch result {
                case .featured(let items):
                    featuredItems = items
                    isLoading = false
                case .latestMovies(let items):
                    latestMovies = items
                    updatePendingGenres()
                case .latestSeries(let items):
                    latestSeries = items
                    updatePendingGenres()
                case .topMovies(let items):
                    topRatedMovies = items
                case .topSeries(let items):
                    topRatedSeries = items
                case .favorites(let items):
                    favorites = items
                }
            }
        }

        isLoading = false
    }

    // MARK: - Lazy Genre Loading

    private func updatePendingGenres() {
        var genreSet = Set<String>()
        for item in latestMovies + latestSeries {
            genreSet.formUnion(item.genres ?? [])
        }
        let sorted = genreSet.sorted().prefix(10).map { $0 }
        // Only update if changed to avoid unnecessary redraws
        if sorted != pendingGenres {
            pendingGenres = sorted
        }
    }

    func loadGenreIfNeeded(_ genre: String) async {
        guard !loadingGenres.contains(genre),
              !genreSections.contains(where: { $0.genre == genre }) else { return }
        loadingGenres.insert(genre)
        let items = (try? await JellyfinAPI.shared.getItems(
            serverURL: serverURL, userId: userId, token: token,
            itemTypes: ["Movie", "Series"], sortBy: "Random",
            limit: 16, recursive: true, genres: [genre]
        ))?.items ?? []
        loadingGenres.remove(genre)
        if !items.isEmpty {
            genreSections.append((genre: genre, items: items))
            genreSections.sort { $0.genre < $1.genre }
        }
    }

    // MARK: - Refresh

    func refresh(appState: AppState) async {
        await load(appState: appState)
    }
}
