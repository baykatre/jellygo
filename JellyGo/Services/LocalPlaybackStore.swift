import Foundation

/// Persists playback positions for locally downloaded files using UserDefaults.
enum LocalPlaybackStore {
    private static func key(for itemId: String) -> String { "localPos.\(itemId)" }
    private static let pendingKey = "localPos.pendingSync"

    static func savePosition(_ seconds: Double, for itemId: String) {
        guard seconds > 0 else { return }
        UserDefaults.standard.set(seconds, forKey: key(for: itemId))
        // Mark this item as needing sync to server
        var pending = pendingSyncItems()
        pending[itemId] = seconds
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    static func position(for itemId: String) -> Double {
        UserDefaults.standard.double(forKey: key(for: itemId))
    }

    static func clear(for itemId: String) {
        UserDefaults.standard.removeObject(forKey: key(for: itemId))
        var pending = pendingSyncItems()
        pending.removeValue(forKey: itemId)
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    // MARK: - Pending Sync

    /// Returns items whose playback positions haven't been synced to the server yet.
    static func pendingSyncItems() -> [String: Double] {
        UserDefaults.standard.dictionary(forKey: pendingKey) as? [String: Double] ?? [:]
    }

    /// Marks an item as synced (removes from pending).
    static func markSynced(_ itemId: String) {
        var pending = pendingSyncItems()
        pending.removeValue(forKey: itemId)
        UserDefaults.standard.set(pending, forKey: pendingKey)
    }

    /// Syncs all pending playback positions to the server.
    static func syncPendingPositions(serverURL: String, token: String) async {
        let pending = pendingSyncItems()
        guard !pending.isEmpty else { return }

        for (itemId, seconds) in pending {
            let ticks = Int64(seconds * 10_000_000)
            await JellyfinAPI.shared.reportPlaybackStopped(
                serverURL: serverURL, itemId: itemId,
                positionTicks: ticks, token: token
            )
            markSynced(itemId)
        }
    }
}
