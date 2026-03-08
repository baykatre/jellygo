import SwiftUI

struct DownloadedSeriesDetailView: View {
    let seriesId: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var showDeleteConfirm: String? = nil  // episode itemId

    private var episodes: [DownloadedItem] {
        dm.downloads.filter { ($0.seriesId ?? $0.id) == seriesId && $0.isEpisode }
    }

    private var seriesName: String {
        episodes.first?.seriesName ?? episodes.first?.name ?? ""
    }

    private var seasons: [Int: [DownloadedItem]] {
        Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
    }

    private var seasonNumbers: [Int] {
        seasons.keys.sorted()
    }

    private var backdropURL: URL? {
        JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: seriesId, maxWidth: 1000)
    }

var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                // Backdrop
                AsyncImage(url: backdropURL) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color(.systemGray5)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()

                // Episode list
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(seasonNumbers, id: \.self) { sNum in
                        if let sEps = seasons[sNum]?.sorted(by: { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }) {
                            Text(sNum == 0 ? "Özel Bölümler" : "Sezon \(sNum)")
                                .font(.title3.bold())
                                .padding(.horizontal, 16)
                                .padding(.top, 20)
                                .padding(.bottom, 8)

                            ForEach(sEps) { ep in
                                episodeRow(ep)
                                Divider().padding(.leading, 108)
                            }
                        }
                    }
                }

                Color.clear.frame(height: 20)
            }
        }
        .navigationTitle(seriesName)
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: episodes.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .toolbar(.hidden, for: .tabBar)
        .alert("Bölümü Sil?", isPresented: Binding(
            get: { showDeleteConfirm != nil },
            set: { if !$0 { showDeleteConfirm = nil } }
        )) {
            Button("Sil", role: .destructive) {
                if let id = showDeleteConfirm { dm.deleteDownload(id) }
                showDeleteConfirm = nil
            }
            Button("İptal", role: .cancel) { showDeleteConfirm = nil }
        } message: {
            let name = episodes.first { $0.id == showDeleteConfirm }?.name ?? ""
            Text("\"\(name)\" silinsin mi?")
        }
    }

    private func episodeRow(_ ep: DownloadedItem) -> some View {
        let thumbURL = JellyfinAPI.shared.imageURL(serverURL: appState.serverURL,
                                                   itemId: ep.id, imageType: "Primary", maxWidth: 200)
        return HStack(spacing: 12) {
            AsyncImage(url: thumbURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(.systemGray5)
                        .overlay(Image(systemName: "play.rectangle").foregroundStyle(.tertiary))
                }
            }
            .frame(width: 92, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                if let epNum = ep.episodeNumber {
                    Text("Bölüm \(epNum)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(ep.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                if !ep.formattedSize.isEmpty {
                    Text(ep.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showDeleteConfirm = ep.id
            } label: {
                Image(systemName: "trash")
                    .font(.body)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
