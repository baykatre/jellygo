import SwiftUI
import Combine

@MainActor
final class PersonDetailViewModel: ObservableObject {
    @Published var biography: String?
    @Published var filmography: [JellyfinItem] = []
    @Published var isLoading = false
    /// Incremented after metadata refresh so PersonDetailView re-evaluates image URLs
    @Published var imageVersion: Int = 0

    @Published var birthDate: Date?
    @Published var deathDate: Date?
    @Published var birthPlace: String?
    @Published var knownForDepartment: String?

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        if let d = isoFormatter.date(from: raw) { return d }
        // Fallback: date-only strings like "1975-03-15T00:00:00.0000000Z"
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: raw)
    }

    func load(person: JellyfinPerson, appState: AppState) async {
        isLoading = true

        if let details = try? await JellyfinAPI.shared.getItemDetails(
            serverURL: appState.serverURL,
            itemId: person.id,
            userId: appState.userId,
            token: appState.token
        ) {
            biography = details.overview
            birthDate = PersonDetailViewModel.parseDate(details.premiereDate)
            deathDate = PersonDetailViewModel.parseDate(details.endDate)
            birthPlace = details.productionLocations?.first
        }
        knownForDepartment = person.type.isEmpty || person.type == "Unknown" ? nil : person.type

        if let items = try? await JellyfinAPI.shared.getPersonFilmography(
            serverURL: appState.serverURL,
            personId: person.id,
            userId: appState.userId,
            token: appState.token
        ) {
            filmography = items
        }

        isLoading = false

        guard !Task.isCancelled else {
            return
        }

        // Always trigger a server-side metadata refresh so Jellyfin downloads
        // the person's photo from external providers (TMDb etc.) if missing.
        await JellyfinAPI.shared.refreshItemMetadata(
            serverURL: appState.serverURL,
            itemId: person.id,
            token: appState.token
        )

        guard !Task.isCancelled else {
            return
        }

        // Wait for Jellyfin to download the image, then increment imageVersion
        // so PersonDetailView uses a cache-busted URL for a fresh network request.
        try? await Task.sleep(for: .seconds(3))

        guard !Task.isCancelled else {
            return
        }

        imageVersion += 1
    }
}
