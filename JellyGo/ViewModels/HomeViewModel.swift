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

    var featuredItems: [JellyfinItem] {
        var result: [JellyfinItem] = []
        let movies = latestMovies.prefix(4)
        let shows  = latestShows.prefix(4)
        for i in 0..<max(movies.count, shows.count) {
            if i < movies.count { result.append(movies[i]) }
            if i < shows.count  { result.append(shows[i]) }
        }
        return Array(result.prefix(6))
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
            latestShows = lm.filter { $0.isSeries || $0.isEpisode }
            libraries = libs
        } catch let err as JellyfinAPIError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
