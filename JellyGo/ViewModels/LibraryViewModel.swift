import SwiftUI
import Combine

@MainActor
final class LibraryViewModel: ObservableObject {
    @Published var items: [JellyfinItem] = []
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var error: String?

    private var totalCount = 0
    private let pageSize = 50
    private var libraryId: String = ""
    private var appState: AppState?

    var hasMore: Bool { items.count < totalCount }

    func load(libraryId: String, appState: AppState) async {
        self.libraryId = libraryId
        self.appState = appState
        items = []
        isLoading = true
        error = nil
        defer { isLoading = false }
        await fetchPage(startIndex: 0)
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore, appState != nil else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        await fetchPage(startIndex: items.count)
    }

    private func fetchPage(startIndex: Int) async {
        guard let appState else { return }
        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                parentId: libraryId,
                sortBy: "SortName",
                sortOrder: "Ascending",
                startIndex: startIndex,
                limit: pageSize,
                recursive: false
            )
            totalCount = response.totalRecordCount
            if startIndex == 0 {
                items = response.items
            } else {
                items.append(contentsOf: response.items)
            }
        } catch let err as JellyfinAPIError {
            error = err.errorDescription
        } catch {
            self.error = error.localizedDescription
        }
    }
}
