import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var showDeleteSeriesConfirm: String? = nil
    @State private var showDeleteMovieConfirm: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if dm.downloads.isEmpty && dm.downloadOrder.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Downloaded content will appear here.")
                    }
                } else {
                    downloadsList
                }
            }
            .navigationTitle("Downloads")
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .alert("Delete All Episodes?", isPresented: Binding(
                get: { showDeleteSeriesConfirm != nil },
                set: { if !$0 { showDeleteSeriesConfirm = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let sid = showDeleteSeriesConfirm {
                        dm.downloads
                            .filter { $0.seriesId == sid }
                            .forEach { dm.deleteDownload($0.id) }
                    }
                    showDeleteSeriesConfirm = nil
                }
                Button("Cancel", role: .cancel) { showDeleteSeriesConfirm = nil }
            } message: {
                let name = dm.downloads.first { $0.seriesId == showDeleteSeriesConfirm }?.seriesName ?? ""
                Text("Remove all downloaded episodes of \"\(name)\"?")
            }
            .alert("Delete Download?", isPresented: Binding(
                get: { showDeleteMovieConfirm != nil },
                set: { if !$0 { showDeleteMovieConfirm = nil } }
            )) {
                Button("Delete", role: .destructive) {
                    if let id = showDeleteMovieConfirm { dm.deleteDownload(id) }
                    showDeleteMovieConfirm = nil
                }
                Button("Cancel", role: .cancel) { showDeleteMovieConfirm = nil }
            } message: {
                let name = dm.downloads.first { $0.id == showDeleteMovieConfirm }?.name ?? ""
                Text("Remove \"\(name)\" from your downloads?")
            }
        }
    }

    // MARK: - List

    private var downloadsList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 28) {

                if !dm.downloadOrder.isEmpty {
                    activeSection
                }

                let movies = dm.downloads.filter { $0.isMovie }
                if !movies.isEmpty {
                    posterSection(title: "Movies", items: movies)
                }

                let episodes = dm.downloads.filter { $0.isEpisode }
                if !episodes.isEmpty {
                    seriesSection(episodes: episodes)
                }
            }
            .padding(.vertical, 16)
        }
    }

    private let gridColumns = [
        GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)
    ]

    // MARK: - Series Section (grid → navigate to detail page)

    private func seriesSection(episodes: [DownloadedItem]) -> some View {
        let groups = Dictionary(grouping: episodes) { $0.seriesId ?? $0.id }
        let seriesIds = groups.keys.sorted {
            (groups[$0]?.first?.seriesName ?? "") < (groups[$1]?.first?.seriesName ?? "")
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text("Diziler")
                .font(.title3.bold())
                .padding(.horizontal, 20)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(seriesIds, id: \.self) { sid in
                    if let groupEps = groups[sid], let first = groupEps.first {
                        let seriesItem = makeSeriesItem(first: first)
                        NavigationLink(value: seriesItem) {
                            PosterCardView(item: seriesItem, serverURL: first.serverURL)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                showDeleteSeriesConfirm = sid
                            } label: {
                                Label("Tümünü Sil (\(groupEps.count) bölüm)", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func makeSeriesItem(first: DownloadedItem) -> JellyfinItem {
        JellyfinItem(
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
    }

    // MARK: - Poster Section (vertical grid)

    private func posterSection(title: String, items: [DownloadedItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.bold())
                .padding(.horizontal, 20)

            LazyVGrid(columns: gridColumns, spacing: 16) {
                ForEach(items) { item in
                    NavigationLink(value: item.toJellyfinItem()) {
                        PosterCardView(item: item.toJellyfinItem(), serverURL: item.serverURL)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            showDeleteMovieConfirm = item.id
                        } label: {
                            Label("Delete Download", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - Active Downloads

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading")
                .font(.title3.bold())
                .padding(.horizontal, 20)

            VStack(spacing: 10) {
                ForEach(dm.downloadOrder, id: \.self) { itemId in
                    if let task = dm.activeTasks[itemId] {
                        activeRow(task)
                    } else if let paused = dm.pausedItems.first(where: { $0.id == itemId }) {
                        pausedRow(paused)
                    } else if let queued = dm.downloadQueue.first(where: { $0.id == itemId }) {
                        queuedRow(queued)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func activeRow(_ task: ActiveDownload) -> some View {
        let navItem = JellyfinItem(
            id: task.id, name: task.name,
            type: task.seriesId != nil ? "Episode" : "Movie",
            overview: nil, productionYear: nil,
            communityRating: nil, criticRating: nil,
            runTimeTicks: nil, seriesName: task.seriesName, seriesId: task.seriesId,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil,
            userData: nil, imageBlurHashes: nil,
            primaryImageAspectRatio: nil, genres: nil,
            officialRating: nil, taglines: nil, people: nil,
            premiereDate: nil, mediaStreams: nil, mediaSources: nil,
            childCount: nil
        )
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NavigationLink(value: navItem) {
                    HStack(spacing: 12) {
                        AsyncImage(url: activeThumbnailURL(task)) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Color(.systemGray5)
                                    .overlay(Image(systemName: "arrow.down.circle").foregroundStyle(.secondary).font(.caption))
                            }
                        }
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            if let series = task.seriesName {
                                Text(series)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(task.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)

                            if task.isFailed {
                                Label("Failed", systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if task.isTranscoding {
                                Label("Transcoding", systemImage: "gearshape.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                                HStack(spacing: 4) {
                                    Text(task.formattedProgress)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !task.formattedSpeed.isEmpty {
                                        Text("·").foregroundStyle(.secondary)
                                        Text(task.formattedSpeed)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                if task.isDirect {
                                    Label("Direct", systemImage: "bolt.fill")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(.green)
                                }
                                HStack(spacing: 4) {
                                    Text(task.formattedProgress)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if !task.formattedSpeed.isEmpty {
                                        Text("·").foregroundStyle(.secondary)
                                        Text(task.formattedSpeed)
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if !task.isFailed {
                    Button { dm.pauseDownload(task.id) } label: {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }

                Button { dm.cancelDownload(task.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            if !task.isFailed {
                if task.progress > 0 || task.bytesExpected > 0 {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                        .tint(task.isTranscoding ? .orange : (task.isDirect ? .green : .accentColor))
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(task.isTranscoding ? .orange : .accentColor)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func pausedRow(_ entry: PausedDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                NavigationLink(value: entry.meta.toJellyfinItem()) {
                    HStack(spacing: 12) {
                        Color(.systemGray5)
                            .overlay(Image(systemName: "pause.fill").foregroundStyle(.secondary).font(.caption))
                            .frame(width: 80, height: 45)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        VStack(alignment: .leading, spacing: 2) {
                            if let series = entry.seriesName {
                                Text(series)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(entry.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            if entry.isDirect {
                                Label("Direct", systemImage: "bolt.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            } else if entry.isTranscoding {
                                Label("Transcoding", systemImage: "gearshape.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.orange)
                            }
                            if !entry.formattedProgress.isEmpty {
                                Text(entry.formattedProgress)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                Button { dm.resumeDownload(entry.id, appState: appState) } label: {
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(.tint)
                        .font(.title3)
                }
                .buttonStyle(.plain)

                Button { dm.cancelDownload(entry.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }

            if entry.progress > 0 {
                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
                    .tint(entry.isTranscoding ? .orange : (entry.isDirect ? .green : .accentColor))
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func queuedRow(_ entry: QueuedDownload) -> some View {
        HStack(spacing: 12) {
            NavigationLink(value: entry.meta.toJellyfinItem()) {
                HStack(spacing: 12) {
                    Color(.systemGray5)
                        .overlay(Image(systemName: "clock").foregroundStyle(.secondary).font(.caption))
                        .frame(width: 80, height: 45)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        if let series = entry.seriesName {
                            Text(series)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(entry.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Label("Waiting", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Button { dm.cancelDownload(entry.id) } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func activeThumbnailURL(_ task: ActiveDownload) -> URL? {
        guard let base = URL(string: appState.serverURL) else { return nil }
        // Episodes: use the episode's Primary image (16:9 thumbnail)
        // Movies / series fallback: use Backdrop of the series or item
        let isEpisode = task.seriesId != nil
        let path: String
        if isEpisode {
            path = "Items/\(task.id)/Images/Primary"
        } else {
            path = "Items/\(task.id)/Images/Backdrop"
        }
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "maxWidth", value: "320"),
                         URLQueryItem(name: "api_key", value: appState.token)]
        return c?.url
    }
}
