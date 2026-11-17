import SwiftUI

/// Detail-page data fetched ahead of time for the items in the Home hero slider, so tapping
/// "info" opens a filled page instead of waiting for several requests.
@MainActor
final class DetailPrefetchStore {
    static let shared = DetailPrefetchStore()

    struct Snapshot {
        let fullItem: JellyfinItem?
        let seasons: [JellyfinItem]
        let episodes: [String: [JellyfinItem]]
        let similarItems: [JellyfinItem]
        /// Series: the season the page should open on (first partly watched / unwatched one).
        let bestSeasonId: String?
        let fetchedAt: Date
    }

    /// Older snapshots are ignored (watched state, resume points may have changed).
    private let maxAge: TimeInterval = 10 * 60
    /// Requests run at most this many items at a time, so prefetching never competes much
    /// with what the user is actually looking at.
    private let maxConcurrent = 2

    private var snapshots: [String: Snapshot] = [:]
    private var inFlight: Set<String> = []
    private var queue: [JellyfinItem] = []
    private var running = 0
    private weak var appState: AppState?

    /// Snapshots belong to one user on one server; switching drops them.
    private var owner = ""
    private static func owner(of appState: AppState) -> String { appState.serverURL + "|" + appState.userId }

    func snapshot(for itemId: String, appState: AppState) -> Snapshot? {
        guard owner == Self.owner(of: appState) else { return nil }
        guard let s = snapshots[itemId], Date().timeIntervalSince(s.fetchedAt) < maxAge else { return nil }
        return s
    }

    /// Drops everything (account / server switch).
    func reset() {
        snapshots.removeAll()
        queue.removeAll()
    }

    /// Queues the given items; already fresh or in-flight ones are skipped.
    func prefetch(_ items: [JellyfinItem], appState: AppState) {
        guard NetworkMonitor.shared.isConnected, !appState.manualOffline, !appState.serverUnreachable else { return }
        let newOwner = Self.owner(of: appState)
        if newOwner != owner { reset(); owner = newOwner }
        self.appState = appState
        for item in items where snapshot(for: item.id, appState: appState) == nil
            && !inFlight.contains(item.id) && !queue.contains(where: { $0.id == item.id }) {
            queue.append(item)
        }
        pump()
    }

    private func pump() {
        while running < maxConcurrent, !queue.isEmpty, let appState {
            let item = queue.removeFirst()
            running += 1
            inFlight.insert(item.id)
            Task(priority: .utility) { [weak self] in
                let snap = await Self.fetch(item: item, appState: appState)
                guard let self else { return }
                if let snap, self.owner == Self.owner(of: appState) { self.snapshots[item.id] = snap }
                self.inFlight.remove(item.id)
                self.running -= 1
                self.pump()
            }
        }
    }

    /// Runs the detail page's own loading (without its side effects) and keeps the result.
    private static func fetch(item: JellyfinItem, appState: AppState) async -> Snapshot? {
        let vm = ItemDetailViewModel()
        await vm.load(item: item, appState: appState, isPrefetch: true)
        guard vm.fullItem != nil else { return nil }
        var bestSeasonId: String?
        if item.isSeries {
            bestSeasonId = await vm.bestSeasonToOpen(appState: appState)?.id
        }
        return Snapshot(fullItem: vm.fullItem, seasons: vm.seasons, episodes: vm.episodes,
                        similarItems: vm.similarItems, bestSeasonId: bestSeasonId, fetchedAt: Date())
    }
}
