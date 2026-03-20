import Foundation

enum TMDBService {
    private static let apiKey = "4219e299c89411838049ab0dab19ebd5"
    private static let cacheKey = "TMDBTrendingPosters"

    struct TrendingItem: Codable {
        let posterURL: String
        let title: String
    }

    static func fetchTrending(count: Int = 6) async -> [TrendingItem] {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([TrendingItem].self, from: data),
           !cached.isEmpty {
            Task { await refreshCache(count: count) }
            return Array(cached.prefix(count))
        }
        return await refreshCache(count: count)
    }

    @discardableResult
    private static func refreshCache(count: Int) async -> [TrendingItem] {
        guard let url = URL(string: "https://api.themoviedb.org/3/trending/all/week?api_key=\(apiKey)") else { return [] }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(TMDBResponse.self, from: data)

            let items = response.results
                .filter { $0.poster_path != nil }
                .prefix(count)
                .map { TrendingItem(posterURL: "https://image.tmdb.org/t/p/w780\($0.poster_path!)", title: $0.title ?? $0.name ?? "") }

            let result = Array(items)
            if let encoded = try? JSONEncoder().encode(result) {
                UserDefaults.standard.set(encoded, forKey: cacheKey)
            }
            return result
        } catch {
            return []
        }
    }

    private struct TMDBResponse: Decodable {
        let results: [TMDBMovie]
    }

    private struct TMDBMovie: Decodable {
        let id: Int
        let title: String?
        let name: String?
        let poster_path: String?
    }
}
