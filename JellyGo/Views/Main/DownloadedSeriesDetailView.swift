import SwiftUI

struct DownloadedSeriesDetailView: View {
    let seriesId: String
    var onPlay: ((DownloadedItem) -> Void)? = nil
    var onNavigate: ((JellyfinItem) -> Void)? = nil
    var isSheet: Bool = true

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var dm: DownloadManager
    @State private var deleteTarget: String? = nil
    @State private var showDeleteAll = false
    @State private var redownloadTarget: DownloadedItem? = nil
    @State private var isSelecting = false
    @State private var selectedIds: Set<String> = []
    @State private var showDeleteSelected = false
    @State private var navigationTarget: JellyfinItem? = nil
    @State private var playTarget: JellyfinItem? = nil

    // MARK: - Data

    private var allItems: [DownloadedItem] {
        dm.downloads.filter { ($0.seriesId ?? $0.id) == seriesId }
    }

    private var isSingleItem: Bool {
        allItems.count == 1 && (allItems.first?.isMovie == true || allItems.first?.seriesId == nil)
    }

    private var episodes: [DownloadedItem] {
        allItems.filter { $0.isEpisode }.sorted {
            let s0 = $0.seasonNumber ?? 0, s1 = $1.seasonNumber ?? 0
            if s0 != s1 { return s0 < s1 }
            return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
        }
    }

    private var seasons: [Int: [DownloadedItem]] {
        Dictionary(grouping: episodes) { $0.seasonNumber ?? 0 }
    }

    private var seasonNumbers: [Int] {
        seasons.keys.sorted()
    }

    private var displayName: String {
        if let movie = allItems.first, movie.isMovie { return movie.name }
        return allItems.first?.seriesName ?? allItems.first?.name ?? ""
    }

    private var totalSize: Int64 {
        allItems.compactMap(\.fileSize).reduce(0, +)
    }

    private var formattedTotalSize: String {
        let gb = Double(totalSize) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(totalSize) / 1_048_576
        return String(format: "%.0f MB", mb)
    }

    private var qualitySummary: String {
        let quals = Set(allItems.map(\.quality))
        return quals.sorted().joined(separator: ", ")
    }

    private var backdropURL: URL? {
        DownloadManager.localBackdropURL(itemId: seriesId)
            ?? DownloadManager.localPosterURL(itemId: seriesId)
            ?? JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: seriesId, maxWidth: 1000)
    }

    private var logoURL: URL? {
        DownloadManager.localLogoURL(itemId: seriesId)
            ?? JellyfinAPI.shared.logoURL(serverURL: appState.serverURL, itemId: seriesId)
    }

    @State private var logoFailed = false

    private var earliestDate: Date? {
        allItems.map(\.addedDate).min()
    }

    // MARK: - Body

    @State private var pullDown: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                headerOverlay
                    .frame(height: headerHeight + safeAreaTop)
                    .offset(y: max(0, scrollOffset))
                    .zIndex(1)
                statsSection
                    .offset(y: max(0, scrollOffset))
                    .zIndex(2)
                if isSingleItem, let movie = allItems.first {
                    movieInfoSection(movie)
                } else {
                    episodeListSection
                }
                actionsSection
                Color.clear.frame(height: 40)
            }
        }
        .onScrollGeometryChange(for: CGFloat.self) { geo in
            geo.contentOffset.y + geo.contentInsets.top
        } action: { _, offset in
            scrollOffset = offset
            pullDown = max(0, -offset)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .navigationBarBackButtonHidden(isSelecting)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .font(.body.weight(.semibold))
                    }
                }
            } else if isSelecting {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isSelecting = false
                            selectedIds.removeAll()
                        }
                    } label: {
                        Text(String(localized: "Cancel", bundle: AppState.currentBundle))

                    }
                }
            }
            if !isSingleItem {
                ToolbarItem(placement: .primaryAction) {
                    if isSelecting && !selectedIds.isEmpty {
                        Button(role: .destructive) {
                            showDeleteSelected = true
                        } label: {
                            Text(String(format: String(localized: "Delete (%lld)", bundle: AppState.currentBundle), Int64(selectedIds.count)))
                                .font(.body.weight(.medium))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSelecting.toggle()
                                if !isSelecting { selectedIds.removeAll() }
                            }
                        } label: {
                            Text(isSelecting
                                ? String(localized: "Done", bundle: AppState.currentBundle)
                                : String(localized: "Select", bundle: AppState.currentBundle))
                                .font(.body.weight(.medium))
                        }
                    }
                }
            }
        }
        .navigationDestination(item: $navigationTarget) { item in
            ItemDetailView(item: item, isFromDownloads: true)
        }
        .navigationDestination(item: $playTarget) { item in
            ItemDetailView(item: item, isFromDownloads: true, autoPlay: true)
        }
        .onChange(of: allItems.isEmpty) { _, isEmpty in
            if isEmpty { dismiss() }
        }
        .alert(String(localized: "Delete Download", bundle: AppState.currentBundle), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                if let id = deleteTarget { dm.deleteDownload(id) }
                deleteTarget = nil
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) { deleteTarget = nil }
        } message: {
            let name = allItems.first { $0.id == deleteTarget }?.name ?? ""
            Text(String(format: String(localized: "Remove \u{201C}%@\u{201D} from your downloads?", bundle: AppState.currentBundle), name))
        }
        .alert(String(localized: "Delete All Downloads", bundle: AppState.currentBundle), isPresented: $showDeleteAll) {
            Button(String(localized: "Delete All", bundle: AppState.currentBundle), role: .destructive) {
                for item in allItems { dm.deleteDownload(item.id) }
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
        } message: {
            Text(String(format: String(localized: "Remove all downloads for \u{201C}%@\u{201D}?", bundle: AppState.currentBundle), displayName))
        }
        .alert(String(format: String(localized: "Delete Selected (%lld)", bundle: AppState.currentBundle), Int64(selectedIds.count)), isPresented: $showDeleteSelected) {
            Button(String(localized: "Delete", bundle: AppState.currentBundle), role: .destructive) {
                for id in selectedIds { dm.deleteDownload(id) }
                selectedIds.removeAll()
                isSelecting = false
            }
            Button(String(localized: "Cancel", bundle: AppState.currentBundle), role: .cancel) {}
        } message: {
            let selectedSize = episodes.filter { selectedIds.contains($0.id) }.compactMap(\.fileSize).reduce(0, +)
            Text(String(format: String(localized: "Remove %lld downloads (%@)?", bundle: AppState.currentBundle), Int64(selectedIds.count), formatBytes(selectedSize)))
        }
    }

    // MARK: - Header

    private let headerHeight: CGFloat = 320

    // Logo + date overlay — single backdrop, parallax + pinning
    private var headerOverlay: some View {
        ZStack(alignment: .bottom) {
            // Backdrop image — stretches on pull-down, opaque for pinning
            Color.clear
                .overlay(alignment: .top) {
                    AsyncImage(url: backdropURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color(.systemGray5)
                        }
                    }
                    .frame(height: headerHeight + safeAreaTop + pullDown)
                    .overlay {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .clear, location: 0.45),
                                .init(color: .black.opacity(0.4), location: 0.65),
                                .init(color: .black.opacity(0.85), location: 1.0)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                    .clipped()
                    .offset(y: -pullDown)
                }

            // Logo + date
            VStack(alignment: .leading, spacing: 6) {
                if !logoFailed, let url = logoURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 200, maxHeight: 60)
                                .shadow(color: .black.opacity(0.6), radius: 6)
                        case .failure:
                            logoFallbackText.onAppear { logoFailed = true }
                        case .empty:
                            logoFallbackText.opacity(0)
                        @unknown default:
                            logoFallbackText
                        }
                    }
                } else {
                    logoFallbackText
                }

                if let date = earliestDate {
                    Text(String(format: String(localized: "Downloaded %@", bundle: AppState.currentBundle), date.formatted(.relative(presentation: .named))))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    private var safeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .keyWindow?.safeAreaInsets.top ?? 0
    }

    private var logoFallbackText: some View {
        Text(displayName)
            .font(.title2.bold())
            .foregroundStyle(.white)
            .lineLimit(2)
            .shadow(color: .black.opacity(0.5), radius: 4)
    }

    // MARK: - Stats

    private var statsSection: some View {
        HStack(spacing: 0) {
            if !isSingleItem {
                statCell(
                    icon: "film.stack",
                    value: "\(episodes.count)",
                    label: String(localized: "Episodes", bundle: AppState.currentBundle)
                )
                Divider().frame(height: 36)
            }

            statCell(
                icon: "internaldrive",
                value: formattedTotalSize,
                label: String(localized: "Size", bundle: AppState.currentBundle)
            )
            Divider().frame(height: 36)

            statCell(
                icon: "sparkles.tv",
                value: qualitySummary,
                label: String(localized: "Quality", bundle: AppState.currentBundle)
            )

            if !isSingleItem {
                Divider().frame(height: 36)
                statCell(
                    icon: "folder",
                    value: "\(seasonNumbers.count)",
                    label: seasonNumbers.count == 1
                        ? String(localized: "Season", bundle: AppState.currentBundle)
                        : String(localized: "Seasons", bundle: AppState.currentBundle)
                )
            }
        }
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .primary.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, -30)
    }

    private func statCell(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Movie Info

    private func movieInfoSection(_ movie: DownloadedItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { playTarget = movie.toJellyfinItem() } label: {
                HStack {
                    Image(systemName: "play.fill")
                    Text(String(localized: "Play", bundle: AppState.currentBundle))
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)

            if let overview = movie.overview, !overview.isEmpty {
                Text(overview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .padding(.horizontal, 16)
            }

            VStack(spacing: 0) {
                infoRow(
                    icon: "sparkles.tv",
                    label: String(localized: "Quality", bundle: AppState.currentBundle),
                    value: movie.quality
                )
                Divider().padding(.leading, 48)
                infoRow(
                    icon: "internaldrive",
                    label: String(localized: "Size", bundle: AppState.currentBundle),
                    value: movie.formattedSize
                )
                if let ticks = movie.runTimeTicks, ticks > 0 {
                    Divider().padding(.leading, 48)
                    infoRow(
                        icon: "clock",
                        label: String(localized: "Duration", bundle: AppState.currentBundle),
                        value: formatDuration(ticks)
                    )
                }
                if let year = movie.productionYear {
                    Divider().padding(.leading, 48)
                    infoRow(
                        icon: "calendar",
                        label: String(localized: "Year", bundle: AppState.currentBundle),
                        value: "\(year)"
                    )
                }
                if let rating = movie.communityRating {
                    Divider().padding(.leading, 48)
                    infoRow(
                        icon: "star.fill",
                        label: String(localized: "Rating", bundle: AppState.currentBundle),
                        value: String(format: "%.1f", rating)
                    )
                }
                if let genres = movie.genres, !genres.isEmpty {
                    Divider().padding(.leading, 48)
                    infoRow(
                        icon: "tag",
                        label: String(localized: "Genres", bundle: AppState.currentBundle),
                        value: genres.prefix(3).joined(separator: ", ")
                    )
                }
                Divider().padding(.leading, 48)
                infoRow(
                    icon: "arrow.down.circle",
                    label: String(localized: "Downloaded", bundle: AppState.currentBundle),
                    value: movie.addedDate.formatted(date: .abbreviated, time: .shortened)
                )
            }
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .primary.opacity(0.12), radius: 6, y: 2)
            .padding(.horizontal, 16)
        }
        .padding(.top, 16)
    }

    private func infoRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Episode List

    private var episodeListSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(seasonNumbers, id: \.self) { sNum in
                if let sEps = seasons[sNum] {
                    let seasonSize = sEps.compactMap(\.fileSize).reduce(0, +)

                    HStack(spacing: 8) {
                        let seasonIds = Set(sEps.map(\.id))
                        let allSeasonSelected = isSelecting && seasonIds.isSubset(of: selectedIds)

                        if isSelecting {
                            Image(systemName: allSeasonSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(allSeasonSelected ? Color.accentColor : .secondary)
                                .onTapGesture {
                                    if allSeasonSelected {
                                        selectedIds.subtract(seasonIds)
                                    } else {
                                        selectedIds.formUnion(seasonIds)
                                    }
                                }
                        }

                        Text(verbatim: sNum == 0
                            ? String(localized: "Special Episodes", bundle: AppState.currentBundle)
                            : "\(String(localized: "Season", bundle: AppState.currentBundle)) \(sNum)")
                            .font(.title3.bold())

                        Spacer()

                        Text(formatBytes(seasonSize))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 24)
                    .padding(.bottom, 10)

                    VStack(spacing: 0) {
                        ForEach(sEps) { ep in
                            episodeRow(ep)
                            if ep.id != sEps.last?.id {
                                Divider().padding(.leading, 108)
                            }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
                    .shadow(color: .primary.opacity(0.12), radius: 6, y: 2)
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.top, 16)
    }

    // MARK: - Episode Row

    private func episodeRow(_ ep: DownloadedItem) -> some View {
        let thumbURL = DownloadManager.localPosterURL(itemId: ep.id)
            ?? DownloadManager.localBackdropURL(itemId: ep.id)
            ?? JellyfinAPI.shared.imageURL(serverURL: appState.serverURL,
                                            itemId: ep.id, imageType: "Primary", maxWidth: 200)
        let isSelected = selectedIds.contains(ep.id)
        return HStack(spacing: 12) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .onTapGesture { toggleSelection(ep.id) }
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            Button {
                if isSelecting {
                    toggleSelection(ep.id)
                } else {
                    playTarget = ep.toJellyfinItem()
                }
            } label: {
                ZStack {
                    AsyncImage(url: thumbURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color(.systemGray5)
                        }
                    }
                    .frame(width: 92, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.5), in: Circle())
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                episodeTextContent(ep)
                if let overview = ep.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            if !isSelecting {
                Button {
                    deleteTarget = ep.id
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isSelecting)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                toggleSelection(ep.id)
            } else if isSheet, let onNavigate {
                let item = ep.toJellyfinItem()
                dismiss()
                onNavigate(item)
            } else {
                navigationTarget = ep.toJellyfinItem()
            }
        }
        .contextMenu {
            Button { playTarget = ep.toJellyfinItem() } label: {
                Label(String(localized: "Play", bundle: AppState.currentBundle), systemImage: "play.fill")
            }
            Button(role: .destructive) { deleteTarget = ep.id } label: {
                Label(String(localized: "Delete", bundle: AppState.currentBundle), systemImage: "trash")
            }
        }
    }

    private func episodeTextContent(_ ep: DownloadedItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let epNum = ep.episodeNumber {
                Text(verbatim: String(format: String(localized: "Episode %lld", bundle: AppState.currentBundle), Int64(epNum)))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            Text(ep.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)

            HStack(spacing: 6) {
                Text(ep.quality)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(ep.quality == "Direct" ? .green : Color.accentColor)
                if !ep.formattedSize.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(ep.formattedSize)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let ticks = ep.runTimeTicks, ticks > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text(formatDuration(ticks))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            if isSelecting {
                if !selectedIds.isEmpty {
                    let selectedSize = episodes.filter { selectedIds.contains($0.id) }.compactMap(\.fileSize).reduce(0, +)
                    Button(role: .destructive) {
                        showDeleteSelected = true
                    } label: {
                        HStack {
                            Image(systemName: "trash")
                            Text(String(format: String(localized: "Delete Selected (%lld)", bundle: AppState.currentBundle), Int64(selectedIds.count)))
                            Spacer()
                            Text(formatBytes(selectedSize))
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
            } else if allItems.count > 1 {
                Button(role: .destructive) {
                    showDeleteAll = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(String(localized: "Delete All Downloads", bundle: AppState.currentBundle))
                        Spacer()
                        Text(formattedTotalSize)
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            } else if let item = allItems.first {
                Button(role: .destructive) {
                    deleteTarget = item.id
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text(String(localized: "Delete Download", bundle: AppState.currentBundle))
                        Spacer()
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06), lineWidth: 1))
        .shadow(color: .primary.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 24)
    }

    // MARK: - Helpers

    private func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
    }

    private func formatDuration(_ ticks: Int64) -> String {
        let totalSeconds = Int(ticks / 10_000_000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return String(format: String(localized: "%lld h %lld m", bundle: AppState.currentBundle), Int64(hours), Int64(minutes))
        }
        return String(format: String(localized: "%lld m", bundle: AppState.currentBundle), Int64(minutes))
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}

