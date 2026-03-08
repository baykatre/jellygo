import SwiftUI
import Combine

@MainActor
final class ItemDetailViewModel: ObservableObject {
    @Published var fullItem: JellyfinItem?
    @Published var seasons: [JellyfinItem] = []
    @Published var episodes: [String: [JellyfinItem]] = [:]
    @Published var isLoading = false
    @Published var isFavorite = false
    @Published var isWatched = false

    func load(item: JellyfinItem, appState: AppState) async {
        isLoading = true
        isFavorite = item.userData?.isFavorite ?? false
        isWatched = item.userData?.played ?? false

        async let detailsTask = JellyfinAPI.shared.getItemDetails(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token
        )

        if item.isSeries {
            async let seasonsTask = JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: item.id,
                itemTypes: ["Season"],
                sortBy: "IndexNumber",
                sortOrder: "Ascending",
                limit: 100
            )
            if let (details, seasonsResponse) = try? await (detailsTask, seasonsTask) {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
                seasons = seasonsResponse.items
                if let first = seasons.first {
                    await loadEpisodes(seasonId: first.id, appState: appState)
                }
            }
        } else if item.isEpisode {
            // Load sibling episodes for the season
            if let seriesId = item.seriesId {
                async let episodesTask = JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    parentId: item.seriesId,
                    itemTypes: ["Season"],
                    sortBy: "IndexNumber",
                    sortOrder: "Ascending",
                    limit: 100
                )
                if let (details, seasonsResponse) = try? await (detailsTask, episodesTask) {
                    fullItem = details
                    isFavorite = details.userData?.isFavorite ?? isFavorite
                    isWatched = details.userData?.played ?? isWatched
                    seasons = seasonsResponse.items
                    // Find and load the current season
                    if let currentSeason = seasons.first(where: { $0.indexNumber == item.parentIndexNumber }) {
                        await loadEpisodes(seasonId: currentSeason.id, appState: appState)
                    } else if let first = seasons.first {
                        await loadEpisodes(seasonId: first.id, appState: appState)
                    }
                }
                _ = seriesId
            } else if let details = try? await detailsTask {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
            }
        } else {
            if let details = try? await detailsTask {
                fullItem = details
                isFavorite = details.userData?.isFavorite ?? isFavorite
                isWatched = details.userData?.played ?? isWatched
            }
        }

        isLoading = false
    }

    func reloadAfterPlayback(item: JellyfinItem, appState: AppState) async {
        // Clear episode cache so fresh data is fetched
        episodes = [:]
        await load(item: item, appState: appState)
    }

    func loadEpisodes(seasonId: String, appState: AppState) async {
        guard episodes[seasonId] == nil else { return }
        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: seasonId,
                itemTypes: ["Episode"],
                sortBy: "IndexNumber",
                sortOrder: "Ascending",
                limit: 200
            )
            episodes[seasonId] = response.items
        } catch {}
    }

    /// Returns the episode to highlight and resume-play for a given season.
    /// Priority: partially watched → first unwatched → first episode
    func resumeEpisode(seasonId: String) -> JellyfinItem? {
        guard let eps = episodes[seasonId] else { return nil }
        if let partial = eps.first(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) {
            return partial
        }
        if let next = eps.first(where: { $0.userData?.played != true }) {
            return next
        }
        return eps.first
    }

    /// For a series: searches all loaded seasons for a partial watch,
    /// then falls back to first unwatched, then first episode ever.
    /// Loads the first season if nothing is loaded yet.
    func resumeEpisodeForSeries(appState: AppState) async -> JellyfinItem? {
        // Ensure at least the first season is loaded
        if let first = seasons.first {
            await loadEpisodes(seasonId: first.id, appState: appState)
        }

        // Check already-loaded seasons for a partial watch
        for season in seasons {
            if let eps = episodes[season.id],
               let partial = eps.first(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) {
                return partial
            }
        }

        // Load remaining seasons and check for next unwatched
        for season in seasons {
            await loadEpisodes(seasonId: season.id, appState: appState)
            if let eps = episodes[season.id],
               let next = eps.first(where: { $0.userData?.played != true }) {
                return next
            }
        }

        // All watched — return first episode of first season
        if let firstSeason = seasons.first {
            return episodes[firstSeason.id]?.first
        }
        return nil
    }

    /// Loads seasons one by one and returns the first season that has a partial watch
    /// or an unwatched episode. Falls back to the first season.
    func bestSeasonToOpen(appState: AppState) async -> JellyfinItem? {
        for season in seasons {
            await loadEpisodes(seasonId: season.id, appState: appState)
            guard let eps = episodes[season.id] else { continue }
            if eps.contains(where: { ($0.userData?.playbackPositionTicks ?? 0) > 0 }) { return season }
            if eps.contains(where: { $0.userData?.played != true }) { return season }
        }
        return seasons.first
    }

    func toggleFavorite(item: JellyfinItem, appState: AppState) async {
        let newValue = !isFavorite
        isFavorite = newValue
        try? await JellyfinAPI.shared.setFavorite(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token,
            isFavorite: newValue
        )
    }

    func toggleWatched(item: JellyfinItem, appState: AppState) async {
        let newValue = !isWatched
        isWatched = newValue
        try? await JellyfinAPI.shared.setPlayed(
            serverURL: appState.serverURL,
            itemId: item.id,
            userId: appState.userId,
            token: appState.token,
            played: newValue
        )
    }
}
