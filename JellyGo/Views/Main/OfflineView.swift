import SwiftUI

struct OfflineView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager

    private let gridColumns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if dm.downloads.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "wifi.slash")
                    } description: {
                        Text("You're offline. Download content while connected to watch it here.")
                    }
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            let movies = dm.downloads.filter { $0.isMovie }
                            if !movies.isEmpty {
                                gridSection(title: "Movies", items: movies.map { $0.toJellyfinItem() }, serverURL: movies[0].serverURL)
                            }

                            let episodes = dm.downloads.filter { $0.isEpisode }
                            if !episodes.isEmpty {
                                seriesGridSection(episodes: episodes)
                            }
                        }
                        .padding(.vertical, 16)
                    }
                }
            }
            .navigationTitle("Offline")
            .navigationBarTitleDisplayMode(.large)
            .safeAreaInset(edge: .top) {
                offlineBanner
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
        }
    }

    // MARK: - Offline Banner

    private var offlineBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.caption.weight(.semibold))
            Text("No internet connection — showing downloaded content")
                .font(.caption)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.gradient)
    }

    // MARK: - Movie Grid

    private func gridSection(title: String, items: [JellyfinItem], serverURL: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 20)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        OfflinePosterCard(item: item, serverURL: serverURL)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Series Grid (grouped)

    private func seriesGridSection(episodes: [DownloadedItem]) -> some View {
        let groups = Dictionary(grouping: episodes) { $0.seriesId ?? $0.id }
        let seriesIds = groups.keys.sorted {
            (groups[$0]?.first?.seriesName ?? "") < (groups[$1]?.first?.seriesName ?? "")
        }

        return VStack(alignment: .leading, spacing: 12) {
            Text("TV Shows")
                .font(.title3.bold())
                .padding(.horizontal, 20)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(seriesIds, id: \.self) { sid in
                    if let first = groups[sid]?.first {
                        let seriesItem = JellyfinItem(
                            id: first.seriesId ?? first.id,
                            name: first.seriesName ?? first.name,
                            type: "Series",
                            overview: nil, productionYear: nil,
                            communityRating: nil, criticRating: nil,
                            runTimeTicks: nil, seriesName: nil, seriesId: nil,
                            seasonName: nil, indexNumber: nil, parentIndexNumber: nil,
                            userData: nil, imageBlurHashes: nil,
                            primaryImageAspectRatio: nil, genres: nil,
                            officialRating: nil, taglines: nil, people: nil,
                            premiereDate: nil, mediaStreams: nil, mediaSources: nil,
                            childCount: nil
                        )
                        NavigationLink(value: seriesItem) {
                            OfflinePosterCard(item: seriesItem, serverURL: first.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

// MARK: - Offline Poster Card (shows poster with local badge)

private struct OfflinePosterCard: View {
    let item: JellyfinItem
    let serverURL: String

    private let width: CGFloat = 100
    private var height: CGFloat { width * 3 / 2 }

    private var posterURL: URL? {
        JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: item.id, imageType: "Primary", maxWidth: 200)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: posterURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.systemGray5))
                            .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                    }
                }
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .background(Color.black.opacity(0.5), in: Circle())
                    .padding(5)
            }

            Text(item.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: width, alignment: .leading)
        }
    }
}
