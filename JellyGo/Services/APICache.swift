import Foundation
import CryptoKit

// MARK: - Cache Entry

private struct CacheEntry: Codable {
    let url: String
    let data: Data
    let expiry: Date

    var isExpired: Bool { Date() > expiry }
}

// MARK: - APICache

final class APICache {
    static let shared = APICache()

    private let cacheDir: URL
    private let queue = DispatchQueue(label: "com.jellygo.apicache", attributes: .concurrent)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("jellygo_api")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Get / Set

    func get(for url: URL) -> Data? {
        let file = cacheFile(for: url)
        return queue.sync {
            guard let raw = try? Data(contentsOf: file),
                  let entry = try? JSONDecoder().decode(CacheEntry.self, from: raw),
                  !entry.isExpired else { return nil }
            return entry.data
        }
    }

    func set(_ data: Data, for url: URL, ttl: TimeInterval) {
        let file = cacheFile(for: url)
        let entry = CacheEntry(url: url.absoluteString, data: data,
                               expiry: Date().addingTimeInterval(ttl))
        guard let raw = try? JSONEncoder().encode(entry) else { return }
        queue.async(flags: .barrier) {
            try? raw.write(to: file, options: .atomic)
        }
    }

    // MARK: - Invalidation

    /// Disk'teki tüm entry'leri tarar, URL'si itemId içerenleri siler.
    func invalidate(itemId: String) {
        queue.async(flags: .barrier) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: self.cacheDir, includingPropertiesForKeys: nil) else { return }
            for file in files where file.pathExtension == "json" {
                guard let raw = try? Data(contentsOf: file),
                      let entry = try? JSONDecoder().decode(CacheEntry.self, from: raw),
                      entry.url.contains(itemId) else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Tüm cache'i temizler (logout).
    func clear() {
        queue.async(flags: .barrier) {
            try? FileManager.default.removeItem(at: self.cacheDir)
            try? FileManager.default.createDirectory(
                at: self.cacheDir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Private

    private func cacheFile(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = hash.compactMap { String(format: "%02x", $0) }.joined() + ".json"
        return cacheDir.appendingPathComponent(name)
    }
}
