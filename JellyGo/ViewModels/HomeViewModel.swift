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
    /// Server URL captured at load time — used for image URLs so they don't flicker on same-user server switch.
    @Published var serverURL: String = ""

    private func buildFeatured() {
        let pool = Array(latestMovies.prefix(8)) + Array(latestShows.prefix(8))
        featuredItems = Array(pool.shuffled().prefix(6))
    }

    func load(appState: AppState) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        // One-time migration: populate serverId and share token across URL variants
        await appState.migrateServerIdIfNeeded()

        let url   = appState.serverURL
        serverURL = url
        let uid   = appState.userId
        let token = appState.token

        async let cwTask   = JellyfinAPI.shared.getContinueWatching(serverURL: url, userId: uid, token: token)
        async let nuTask   = JellyfinAPI.shared.getNextUp(serverURL: url, userId: uid, token: token)
        async let lmTask   = JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Movie"], sortBy: "DateCreated", sortOrder: "Descending",
            limit: 16, recursive: true)
        async let lsTask   = JellyfinAPI.shared.getItems(
            serverURL: url, userId: uid, token: token,
            itemTypes: ["Series"], sortBy: "DateCreated", sortOrder: "Descending",
            limit: 16, recursive: true)
        async let libsTask = JellyfinAPI.shared.getLibraries(serverURL: url, userId: uid, token: token)

        continueWatching = (try? await cwTask)  ?? []
        nextUp           = (try? await nuTask)  ?? []

        var networkFailed = false

        do {
            latestMovies = try await lmTask.items
        } catch JellyfinAPIError.unauthorized {
            error = NSLocalizedString("Session expired. Re-add the account from settings.", comment: "")
        } catch JellyfinAPIError.networkError {
            networkFailed = true
        } catch let err as JellyfinAPIError {
            error = err.errorDescription
        } catch { /* non-API errors intentionally ignored */ }

        do {
            latestShows = try await lsTask.items
        } catch JellyfinAPIError.unauthorized {
            if error == nil { error = NSLocalizedString("Session expired. Re-add the account from settings.", comment: "") }
        } catch JellyfinAPIError.networkError {
            networkFailed = true
        } catch let err as JellyfinAPIError {
            if error == nil { error = err.errorDescription }
        } catch { /* non-API errors intentionally ignored */ }

        libraries = (try? await libsTask) ?? []
        buildFeatured()

        // Server became unreachable mid-session → try fallback
        if networkFailed {
            await appState.validateAndFallback()
        }
    }
}
