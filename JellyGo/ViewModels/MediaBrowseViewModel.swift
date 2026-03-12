import SwiftUI
import Combine

@MainActor
final class MediaBrowseViewModel: ObservableObject {
    @Published var featuredItems: [JellyfinItem] = []
    @Published var recentlyAdded: [JellyfinItem] = []
    @Published var topRated: [JellyfinItem] = []
    @Published var favorites: [JellyfinItem] = []
    @Published var genreSections: [(genre: String, items: [JellyfinItem])] = []
    @Published var allItems: [JellyfinItem] = []
    @Published var availableGenres: [String] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?

    var serverURL: String = ""
    private var totalItems: Int = 0
    private var currentCategory: String = ""
    private var currentItemTypes: [String]?
    private var currentGenres: [String]?

    // MARK: - Load Genres

    func loadGenres(category: String, appState: AppState) async {
        let url = appState.serverURL
        serverURL = url
        let uid = appState.userId
        let token = appState.token

        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: url, userId: uid, token: token,
                itemTypes: [category], sortBy: "SortName",
                limit: 100, recursive: true
            )
            var genreSet = Set<String>()
            for item in response.items {
                if let genres = item.genres {
                    genreSet.formUnion(genres)
                }
            }
            availableGenres = genreSet.sorted()
        } catch {
            availableGenres = []
        }
    }

    // MARK: - Load Category

    func loadCategory(category: String, appState: AppState, genre: String? = nil, isRefresh: Bool = false) async {
        guard isRefresh || !isLoading else { return }
        if !isRefresh {
            isLoading = true
        }
        error = nil
        currentCategory = category

        let url = appState.serverURL
        serverURL = url
        let uid = appState.userId
        let token = appState.token

        let itemTypes: [String] = [category]
        let genres: [String]? = genre.map { [$0] }

        currentItemTypes = itemTypes
        currentGenres = genres

        // Parallel fetches — use unstructured Tasks to avoid cancellation from .refreshable

        let featuredTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: itemTypes, sortBy: "Random", sortOrder: "Descending",
            limit: 6, recursive: true, genres: genres
        )}
        let recentTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: itemTypes, sortBy: "DateCreated", sortOrder: "Descending",
            limit: 16, recursive: true, genres: genres
        )}
        let topRatedTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: itemTypes, sortBy: "CommunityRating", sortOrder: "Descending",
            limit: 16, recursive: true, genres: genres
        )}
        let favoritesTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: itemTypes, sortBy: "SortName",
            limit: 16, recursive: true, filters: "IsFavorite", genres: genres
        )}
        let allTask = Task.detached { try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: itemTypes, sortBy: "SortName",
            limit: 50, recursive: true, genres: genres
        )}

        featuredItems = (await featuredTask.value)?.items ?? []
        recentlyAdded = (await recentTask.value)?.items ?? []
        topRated = (await topRatedTask.value)?.items ?? []
        favorites = (await favoritesTask.value)?.items ?? []

        let allResponse = await allTask.value
        allItems = allResponse?.items ?? []
        totalItems = allResponse?.totalRecordCount ?? 0

        // Genre sub-sections when no genre filter is applied
        if genres == nil {
            await loadGenreSections(itemTypes: itemTypes, appState: appState)
        } else {
            genreSections = []
        }

        isLoading = false
    }

    // MARK: - Genre Sub-Sections

    private func loadGenreSections(itemTypes: [String], appState: AppState) async {
        let url = appState.serverURL
        let uid = appState.userId
        let token = appState.token

        let genresToLoad = Array(availableGenres.prefix(10))
        var sections: [(genre: String, items: [JellyfinItem])] = []

        await withTaskGroup(of: (String, [JellyfinItem]).self) { group in
            for genre in genresToLoad {
                group.addTask {
                    let items = (try? await JellyfinAPI.shared.getItems(
                        serverURL: url, userId: uid, token: token,
                        itemTypes: itemTypes, sortBy: "Random",
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

        // Sort by genre name to keep stable order
        genreSections = sections.sorted { $0.genre < $1.genre }
    }

    // MARK: - Load More

    func loadMore(appState: AppState) async {
        guard !isLoadingMore, allItems.count < totalItems else { return }
        isLoadingMore = true

        let url = appState.serverURL
        let uid = appState.userId
        let token = appState.token

        let response = try? await JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: currentItemTypes, sortBy: "SortName",
            startIndex: allItems.count, limit: 50, recursive: true,
            genres: currentGenres
        )

        if let items = response?.items {
            allItems.append(contentsOf: items)
        }

        isLoadingMore = false
    }
}
