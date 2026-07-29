import Foundation
import CryptoKit
import UIKit

/// Persistent, on-disk + in-memory image cache — independent of URLCache/HTTP
/// headers, so posters/backdrops/logos survive regardless of what caching headers
/// the media server sends, and aren't evicted by unrelated network traffic (e.g.
/// video streaming sharing URLCache.shared). Mirrors APICache's disk layout.
final class ImageCache {
    static let shared = ImageCache()

    private let memoryCache = NSCache<NSString, UIImage>()
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "com.jellygo.imagecache", attributes: .concurrent)

    private init() {
        memoryCache.countLimit = 300
        memoryCache.totalCostLimit = 150 * 1024 * 1024 // ~150MB of decoded images

        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        cacheDir = base.appendingPathComponent("jellygo_images")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    // MARK: - Memory Lookup (fast, safe to call from the main thread)

    func memoryCachedImage(for url: URL) -> UIImage? {
        memoryCache.object(forKey: url.absoluteString as NSString)
    }

    // MARK: - Fetch (memory → disk → network, disk/network always off the main thread)

    /// `networkPriority` is a URLSessionTask priority (0.0–1.0). Foreground/on-screen
    /// images use the default; background prefetching uses a low priority so it never
    /// starves connection slots the visible UI is waiting on.
    func fetch(url: URL, networkPriority: Float = URLSessionTask.defaultPriority) async -> UIImage? {
        if let img = memoryCachedImage(for: url) { return img }

        if let img = await readFromDisk(url: url) {
            memoryCache.setObject(img, forKey: url.absoluteString as NSString)
            return img
        }

        guard let image = await downloadImage(url: url, networkPriority: networkPriority) else { return nil }
        return image
    }

    private func downloadImage(url: URL, networkPriority: Float) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let task = URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
                guard let data, error == nil, let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                self?.store(data: data, image: image, for: url)
                continuation.resume(returning: image)
            }
            task.priority = networkPriority
            task.resume()
        }
    }

    /// Warms the cache for the given URLs — used to preload the hero banner's items so
    /// swiping never has to hit the network. Runs sequentially, one at a time, at low
    /// network priority, so it never floods the connection pool or delays whatever the
    /// user is actually looking at right now.
    func warm(_ urls: [URL?]) {
        let pending = urls.compactMap { $0 }.filter { memoryCachedImage(for: $0) == nil }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .utility) { [weak self] in
            for url in pending {
                _ = await self?.fetch(url: url, networkPriority: URLSessionTask.lowPriority)
            }
        }
    }

    private func readFromDisk(url: URL) async -> UIImage? {
        let file = cacheFile(for: url)
        return await withCheckedContinuation { continuation in
            queue.async {
                guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: img)
            }
        }
    }

    // MARK: - Private

    private func store(data: Data, image: UIImage, for url: URL) {
        memoryCache.setObject(image, forKey: url.absoluteString as NSString, cost: data.count)
        let file = cacheFile(for: url)
        queue.async(flags: .barrier) {
            try? data.write(to: file, options: .atomic)
        }
    }

    private func cacheFile(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = hash.compactMap { String(format: "%02x", $0) }.joined()
        return cacheDir.appendingPathComponent(name)
    }
}
