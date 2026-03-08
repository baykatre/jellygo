import Foundation

/// Persists playback positions for locally downloaded files using UserDefaults.
enum LocalPlaybackStore {
    private static func key(for itemId: String) -> String { "localPos.\(itemId)" }

    static func savePosition(_ seconds: Double, for itemId: String) {
        guard seconds > 0 else { return }
        UserDefaults.standard.set(seconds, forKey: key(for: itemId))
    }

    static func position(for itemId: String) -> Double {
        UserDefaults.standard.double(forKey: key(for: itemId))
    }

    static func clear(for itemId: String) {
        UserDefaults.standard.removeObject(forKey: key(for: itemId))
    }
}
