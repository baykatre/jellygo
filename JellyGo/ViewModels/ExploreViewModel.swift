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
    @Published var isLoading = false

    var serverURL: String = ""

    // MARK: - Load All Sections

    func load(appState: AppState) async {
        isLoading = true

        let url = appState.serverURL
        serverURL = url
        let uid = appState.userId
        let token = appState.token

        let featuredTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Movie", "Series"], sortBy: "Random", sortOrder: "Descending",
            limit: 6, recursive: true
        )}
        let latestMoviesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Movie"], sortBy: "DateCreated", sortOrder: "Descending",
            limit: 16, recursive: true
        )}
        let latestSeriesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Series"], sortBy: "DateCreated", sortOrder: "Descending",
            limit: 16, recursive: true
        )}
        let topMoviesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Movie"], sortBy: "CommunityRating", sortOrder: "Descending",
            limit: 16, recursive: true
        )}
        let topSeriesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Series"], sortBy: "CommunityRating", sortOrder: "Descending",
            limit: 16, recursive: true
        )}
        let favoritesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Movie", "Series"], sortBy: "SortName",
            limit: 16, recursive: true, filters: "IsFavorite"
        )}

        featuredItems = (await featuredTask.value)?.items ?? []
        latestMovies = (await latestMoviesTask.value)?.items ?? []
        latestSeries = (await latestSeriesTask.value)?.items ?? []
        topRatedMovies = (await topMoviesTask.value)?.items ?? []
        topRatedSeries = (await topSeriesTask.value)?.items ?? []
        favorites = (await favoritesTask.value)?.items ?? []

        await loadGenreSections(appState: appState)

        isLoading = false
    }

    // MARK: - Refresh

    func refresh(appState: AppState) async {
        await load(appState: appState)
    }

    // MARK: - Genre Sections

    private func loadGenreSections(appState: AppState) async {
        let url = appState.serverURL
        let uid = appState.userId
        let token = appState.token

        // Collect genres from latest movies + series
        var genreSet = Set<String>()
        for item in latestMovies + latestSeries {
            if let genres = item.genres {
                genreSet.formUnion(genres)
            }
        }

        let genresToLoad = Array(genreSet.sorted().prefix(10))
        var sections: [(genre: String, items: [JellyfinItem])] = []

        await withTaskGroup(of: (String, [JellyfinItem]).self) { group in
            for genre in genresToLoad {
                group.addTask {
                    let items = (try? await JellyfinAPI.shared.getItems(
                        serverURL: url, userId: uid, token: token,
                        itemTypes: ["Movie", "Series"], sortBy: "Random",
                        limit: 16, recursive: true, genres: [genre]
                    ).items) ?? []
                    return (genre, items)
                }
            }
            for await (genre, items) in group {
                if !items.isEmpty {
                    sections.append((genre: genre, items: items))
                }
            }
        }

        genreSections = sections.sorted { $0.genre < $1.genre }
    }
}
