import SwiftUI
import Combine

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var continueWatching: [JellyfinItem] = []
    @Published var nextUp: [JellyfinItem] = []
    @Published var latestMovies: [JellyfinItem] = []
    @Published var latestShows: [JellyfinItem] = []
    @Published var libraries: [JellyfinLibrary] = []
    @Published var isLoading = false
    @Published var error: String?

    @Published var featuredItems: [JellyfinItem] = []

    private func buildFeatured() {
        let pool = Array(latestMovies.prefix(8)) + Array(latestShows.prefix(8))
        featuredItems = Array(pool.shuffled().prefix(6))
    }

    func load(appState: AppState) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            async let continueTask = JellyfinAPI.shared.getContinueWatching(
                serverURL: appState.serverURL, userId: appState.userId, token: appState.token)
            async let nextUpTask = JellyfinAPI.shared.getNextUp(
                serverURL: appState.serverURL, userId: appState.userId, token: appState.token)
            async let latestMoviesTask = JellyfinAPI.shared.getLatestMedia(
                serverURL: appState.serverURL, userId: appState.userId, token: appState.token)
            async let librariesTask = JellyfinAPI.shared.getLibraries(
                serverURL: appState.serverURL, userId: appState.userId, token: appState.token)

            let (cw, nu, lm, libs) = try await (continueTask, nextUpTask, latestMoviesTask, librariesTask)

            continueWatching = cw
            nextUp = nu
            latestMovies = lm.filter { $0.isMovie }

            // Jellyfin Latest returns Episodes for TV, not Series.
            // Deduplicate by seriesId so each show appears only once.
            var seenSeries = Set<String>()
            latestShows = lm
                .filter { $0.isSeries || $0.isEpisode }
                .filter { item in
                    let key = item.isEpisode ? (item.seriesId ?? item.id) : item.id
                    return seenSeries.insert(key).inserted
                }
            libraries = libs
            buildFeatured()
        } catch let err as JellyfinAPIError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
