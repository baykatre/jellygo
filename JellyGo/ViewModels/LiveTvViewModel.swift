import SwiftUI
import Combine

@MainActor
final class LiveTvViewModel: ObservableObject {
    @Published var channels: [JellyfinItem] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var serverURL: String = ""

    func load(appState: AppState) async {
        guard appState.serverValidated, !appState.serverUnreachable else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        let url = appState.serverURL
        serverURL = url
        let uid = appState.userId
        let token = appState.token

        do {
            channels = try await JellyfinAPI.shared.getLiveTvChannels(
                serverURL: url, userId: uid, token: token
            )
        } catch {
            if channels.isEmpty {
                self.error = error.localizedDescription
            }
        }
    }
}
