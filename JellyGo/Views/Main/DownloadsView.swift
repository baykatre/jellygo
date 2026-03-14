import SwiftUI

struct DownloadedSeriesNav: Hashable {
    let seriesId: String
}

struct DownloadsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var showDeleteSeriesConfirm: String? = nil
    @State private var showDeleteMovieConfirm: String? = nil
    @State private var scrollOffset: CGFloat = 0

    private var totalSizeFormatted: String {
        let bytes = dm.downloads.compactMap(\.fileSize).reduce(0, +)
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    var body: some View {
        NavigationStack {
            Group {
                if dm.downloads.isEmpty && dm.downloadOrder.isEmpty {
                    ScrollView {
                        Color.clear.frame(height: 44)
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 48))
                                .foregroundStyle(.tertiary)
                            Text("No Downloads")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    }
                } else {
                    downloadsList
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .overlay(alignment: .top) {
                HStack {
                    Text(String(localized: "Downloads", bundle: AppState.currentBundle))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)

                    Spacer()

                    if !totalSizeFormatted.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "internaldrive")
                                .font(.caption.weight(.semibold))
                            Text(totalSizeFormatted)
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .opacity(max(0.0, 1.0 - (scrollOffset / 100.0)))
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item, isFromDownloads: true)
            }
            .navigationDestination(for: DownloadedSeriesNav.self) { nav in
                DownloadedSeriesDetailView(seriesId: nav.seriesId, isSheet: false)
            }
            .alert(String(localized: "Delete All Episodes?", bundle: AppState.currentBundle), isPresented: Binding(
                get: { showDeleteSeriesConfirm != nil },
                set: { if !$0 { showDeleteSeriesConfirm = nil } }
            )) {
                Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                    if let sid = showDeleteSeriesConfirm {
                        dm.downloads
                            .filter { $0.seriesId == sid }
                            .forEach { dm.deleteDownload($0.id) }
                    }
                    showDeleteSeriesConfirm = nil
                }
                Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { showDeleteSeriesConfirm = nil }
            } message: {
                let name = dm.downloads.first { $0.seriesId == showDeleteSeriesConfirm }?.seriesName ?? ""
                Text("Remove all downloaded episodes of \"\(name)\"?")
            }
            .alert(String(localized: "Delete Download?", bundle: AppState.currentBundle), isPresented: Binding(
                get: { showDeleteMovieConfirm != nil },
                set: { if !$0 { showDeleteMovieConfirm = nil } }
            )) {
                Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                    if let id = showDeleteMovieConfirm { dm.deleteDownload(id) }
                    showDeleteMovieConfirm = nil
                }
                Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { showDeleteMovieConfirm = nil }
            } message: {
                let name = dm.downloads.first { $0.id == showDeleteMovieConfirm }?.name ?? ""
                Text("Remove \"\(name)\" from your downloads?")
            }
            .background(Color(.systemBackground).ignoresSafeArea())
        }
    }

    // MARK: - List

    private var downloadsList: some View {
        ScrollView(showsIndicators: false) {
            Color.clear.frame(height: 44)

            VStack(alignment: .leading, spacing: 32) {

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
            .padding(.top, 28)
            .padding(.bottom, 40)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            scrollOffset = offset
        }
    }

    // MARK: - Series Section

    private func seriesSection(episodes: [DownloadedItem]) -> some View {
        let groups = Dictionary(grouping: episodes) { $0.seriesId ?? $0.id }
        let seriesIds = groups.keys.sorted {
            (groups[$0]?.first?.seriesName ?? "") < (groups[$1]?.first?.seriesName ?? "")
        }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "TV Shows")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(seriesIds, id: \.self) { sid in
                        if let groupEps = groups[sid], let first = groupEps.first {
                            let seriesItem = makeSeriesItem(first: first)
                            let seasonCount = Set(groupEps.compactMap(\.seasonNumber)).count
                            NavigationLink(value: DownloadedSeriesNav(seriesId: sid)) {
                                VStack(alignment: .leading, spacing: 6) {
                                    BackdropCardView(item: seriesItem, serverURL: first.serverURL, width: 260)
                                    seriesDetailText(seasonCount: seasonCount, episodeCount: groupEps.count, totalSize: groupEps.compactMap(\.fileSize).reduce(0, +))
                                        .frame(width: 260, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    showDeleteSeriesConfirm = sid
                                } label: {
                                    Label(String(localized: "Delete All (\(groupEps.count) episodes)", bundle: AppState.currentBundle), systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
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
            childCount: nil, providerIds: nil,
            endDate: nil, productionLocations: nil
        )
    }

    private func makeMovieCardItem(_ item: DownloadedItem) -> JellyfinItem {
        JellyfinItem(
            id: item.id, name: item.name, type: "Movie",
            overview: nil, productionYear: nil,
            communityRating: nil, criticRating: nil,
            runTimeTicks: nil, seriesName: nil, seriesId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil,
            userData: nil, imageBlurHashes: nil,
            primaryImageAspectRatio: nil, genres: nil,
            officialRating: nil, taglines: nil, people: nil,
            premiereDate: nil, mediaStreams: nil, mediaSources: nil,
            childCount: nil, providerIds: nil,
            endDate: nil, productionLocations: nil
        )
    }

    private func seriesDetailText(seasonCount: Int, episodeCount: Int, totalSize: Int64) -> some View {
        let parts: [String] = [
            seasonCount > 0 ? "\(seasonCount) Sezon" : nil,
            "\(episodeCount) B\u{00F6}l\u{00FC}m",
            totalSize > 0 ? ByteCountFormatter().string(fromByteCount: totalSize) : nil
        ].compactMap { $0 }
        return Text(parts.joined(separator: " \u{00B7} "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private func movieDetailText(item: DownloadedItem) -> some View {
        let parts: [String] = [
            item.productionYear.map { "\($0)" },
            item.runTimeTicks.map { ticks in
                let totalMinutes = Int(ticks / 10_000_000 / 60)
                let hours = totalMinutes / 60
                let mins = totalMinutes % 60
                return hours > 0 ? "\(hours) sa. \(mins) dk." : "\(mins) dk."
            },
            item.fileSize.flatMap { $0 > 0 ? ByteCountFormatter().string(fromByteCount: $0) : nil }
        ].compactMap { $0 }
        return Text(parts.joined(separator: " \u{00B7} "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: - Poster Section (horizontal scroll)

    private func posterSection(title: LocalizedStringKey, items: [DownloadedItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: title)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: DownloadedSeriesNav(seriesId: item.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                BackdropCardView(item: makeMovieCardItem(item), serverURL: item.serverURL, width: 260)
                                movieDetailText(item: item)
                                    .frame(width: 260, alignment: .leading)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                showDeleteMovieConfirm = item.id
                            } label: {
                                Label(String(localized: "Delete Download", bundle: AppState.currentBundle), systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - Active Downloads

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Downloading")

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
            .padding(.horizontal, 20)
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
            childCount: nil, providerIds: nil,
            endDate: nil, productionLocations: nil
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
                                Label(String(localized: "Failed", bundle: AppState.currentBundle), systemImage: "exclamationmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            } else if task.isTranscoding {
                                Label(String(localized: "Transcoding", bundle: AppState.currentBundle), systemImage: "gearshape.fill")
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
                                    Label(String(localized: "Direct", bundle: AppState.currentBundle), systemImage: "bolt.fill")
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
                                Label(String(localized: "Direct", bundle: AppState.currentBundle), systemImage: "bolt.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            } else if entry.isTranscoding {
                                Label(String(localized: "Transcoding", bundle: AppState.currentBundle), systemImage: "gearshape.fill")
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
                        Label(String(localized: "Waiting", bundle: AppState.currentBundle), systemImage: "clock")
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
        // Prefer local cache
        if let local = DownloadManager.localBackdropURL(itemId: task.id)
            ?? DownloadManager.localPosterURL(itemId: task.id) {
            return local
        }
        guard let base = URL(string: appState.serverURL) else { return nil }
        let isEpisode = task.seriesId != nil
        let path = isEpisode
            ? "Items/\(task.id)/Images/Primary"
            : "Items/\(task.id)/Images/Backdrop"
        var c = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        c?.queryItems = [URLQueryItem(name: "maxWidth", value: "320"),
                         URLQueryItem(name: "api_key", value: appState.token)]
        return c?.url
    }
}
