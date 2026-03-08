import SwiftUI
import Combine

@MainActor
final class SearchViewModel: ObservableObject {
    @Published var results: [JellyfinSearchHint] = []
    @Published var isSearching = false
    @Published var filter: SearchFilter = .all

    enum SearchFilter: String, CaseIterable {
        case all = "All"
        case movie = "Movie"
        case series = "Series"

        var itemType: String? {
            switch self {
            case .all:    return nil
            case .movie:  return "Movie"
            case .series: return "Series"
            }
        }

        var icon: String {
            switch self {
            case .all:    return "square.grid.2x2"
            case .movie:  return "film"
            case .series: return "tv"
            }
        }
    }

    var filteredResults: [JellyfinSearchHint] {
        guard let type = filter.itemType else { return results }
        return results.filter { $0.type == type }
    }

    @Published var recentItems: [JellyfinSearchHint] = []

    private let recentKey = "jellygo.recentSearches"
    private var searchTask: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: recentKey),
           let saved = try? JSONDecoder().decode([JellyfinSearchHint].self, from: data) {
            recentItems = saved
        }
    }

    func addToRecent(_ hint: JellyfinSearchHint) {
        var items = recentItems.filter { $0.itemId != hint.itemId }
        items.insert(hint, at: 0)
        recentItems = Array(items.prefix(12))
        if let data = try? JSONEncoder().encode(recentItems) {
            UserDefaults.standard.set(data, forKey: recentKey)
        }
    }

    func clearRecent() {
        recentItems = []
        UserDefaults.standard.removeObject(forKey: recentKey)
    }

    func search(query: String, appState: AppState) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            do {
                results = try await JellyfinAPI.shared.search(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    query: trimmed
                )
            } catch {}
            isSearching = false
        }
    }
}
