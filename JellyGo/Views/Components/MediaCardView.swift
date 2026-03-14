import SwiftUI
import Combine

// MARK: - Fallback Async Image

struct FallbackAsyncImage<Placeholder: View>: View {
    let primaryURL: URL?
    let fallbackURL: URL?
    let placeholder: Placeholder

    @State private var useFallback = false

    var body: some View {
        let url = (useFallback ? fallbackURL : primaryURL) ?? fallbackURL

        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Group {
                        if !useFallback && fallbackURL != nil {
                            Color.clear.onAppear { useFallback = true }
                        } else {
                            placeholder
                        }
                    }
                case .empty:
                    placeholder.overlay(ProgressView().tint(.secondary))
                @unknown default:
                    placeholder
                }
            }
        } else {
            placeholder
        }
    }

}

// MARK: - Hero Banner

var bannerSize: CGSize {
    let screen = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first?.screen.bounds.size ?? CGSize(width: 390, height: 844)
    return CGSize(width: screen.width, height: 680)
}

/// Image occupies top portion; bottom fills with dominant color
private var bannerImageHeight: CGFloat { 590 }

struct HeroBannerView: View {
    let items: [JellyfinItem]
    let serverURL: String
    var pullDown: CGFloat = 0
    var scrollOffset: CGFloat = 0
    var onPlay: (JellyfinItem) -> Void = { _ in }

    // Two stable layers: A and B. One is "current", the other is "next".
    // On commit we toggle which is current — NO AsyncImage URL changes at snap time.
    @State private var indexA = 0
    @State private var indexB = 0
    @State private var aIsCurrent = true
    @State private var dragOffset: CGFloat = 0
    @State private var isTransitioning = false
    @State private var isDragging = false
    @State private var pauseUntil: Date = .distantPast
    @State private var dominantColor: Color = Color(white: 0.12)

    private let autoTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    private var progress: CGFloat {
        let size = bannerSize
        guard size.width > 0 else { return 0 }
        return dragOffset / size.width
    }

    private var currentItemIndex: Int { aIsCurrent ? indexA : indexB }

    var body: some View {
        let size = bannerSize
        // Crossfade: amplified so ~35% drag ≈ 100% opacity swap
        let rawProg = min(abs(progress), 1.0)
        let fadeProg = min(rawProg * 2.8, 1.0)
        // Parallax: tracks raw finger movement, keeps drifting after crossfade is done
        let curParallax = progress * 60
        let nxtParallax = -progress * 20

        ZStack(alignment: .bottom) {
            // Dominant color background
            dominantColor.animation(.easeInOut(duration: 0.5), value: dominantColor)

            // Layer A — stable identity, never changes URL at snap time
            backdropLayer(item: items[indexA], size: size,
                          parallaxOffset: aIsCurrent ? curParallax : nxtParallax)
                .opacity(Double(aIsCurrent ? 1.0 - fadeProg : fadeProg))

            // Layer B — stable identity
            backdropLayer(item: items[indexB], size: size,
                          parallaxOffset: aIsCurrent ? nxtParallax : curParallax)
                .opacity(Double(aIsCurrent ? fadeProg : 1.0 - fadeProg))

            // Progressive blur + subtle gradient
            gradientOverlay(size: size)

            // Content — hides during drag/transition
            contentOverlay(item: items[currentItemIndex], size: size)
                .opacity(isDragging ? 0 : 1)
                .animation(.easeOut(duration: isDragging ? 0.08 : 0.25), value: isDragging)

            // Dot indicator
            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == currentItemIndex ? Color.white : Color.white.opacity(0.35))
                            .frame(width: i == currentItemIndex ? 20 : 5, height: 5)
                            .animation(.spring(duration: 0.3), value: currentItemIndex)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .frame(width: size.width, height: size.height + pullDown)
        .offset(y: -pullDown)
        .padding(.bottom, -pullDown)
        .contentShape(Rectangle())
        .onTapGesture {
            onPlay(items[currentItemIndex])
        }
        .gesture(items.count > 1 ? dragGesture(size: size) : nil)
        .onReceive(autoTimer) { now in
            guard items.count > 1, now >= pauseUntil, !isTransitioning else { return }
            commitTransition(direction: -1, size: size)
        }
        .onAppear { extractDominantColor(for: items[currentItemIndex]) }
        .onChange(of: currentItemIndex) { _, newIndex in
            extractDominantColor(for: items[newIndex])
        }
    }

    // MARK: - Drag Gesture

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard !isTransitioning else { return }
                isDragging = true
                dragOffset = value.translation.width
                // Update the "next" slot's index
                let nextItemIdx: Int
                if dragOffset < 0 {
                    nextItemIdx = (currentItemIndex + 1) % items.count
                } else {
                    nextItemIdx = (currentItemIndex - 1 + items.count) % items.count
                }
                if aIsCurrent { indexB = nextItemIdx } else { indexA = nextItemIdx }
            }
            .onEnded { value in
                guard !isTransitioning else { return }
                let threshold = size.width * 0.2
                let velocity = value.predictedEndTranslation.width - value.translation.width
                if abs(dragOffset) > threshold || abs(velocity) > 200 {
                    commitTransition(direction: dragOffset < 0 ? -1 : 1, size: size)
                } else {
                    withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) {
                        isDragging = false
                    }
                }
                pauseUntil = Date().addingTimeInterval(8)
            }
    }

    private func commitTransition(direction: CGFloat, size: CGSize) {
        isTransitioning = true
        isDragging = true

        // Compute the pending next index
        let pending: Int
        if direction < 0 {
            pending = (currentItemIndex + 1) % items.count
        } else {
            pending = (currentItemIndex - 1 + items.count) % items.count
        }

        // Auto-advance: seed the next slot and animate crossfade
        if dragOffset == 0 {
            if aIsCurrent { indexB = pending } else { indexA = pending }
            dragOffset = direction < 0 ? -1 : 1

            let target = direction < 0 ? -size.width : size.width
            withAnimation(.easeOut(duration: 0.3)) { dragOffset = target }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                finishTransition()
            }
            return
        }

        // User drag: crossfade already done visually — snap in place, no animation
        finishTransition()
    }

    private func finishTransition() {
        var t = Transaction(animation: nil)
        withTransaction(t) {
            aIsCurrent.toggle()
            dragOffset = 0
        }
        isTransitioning = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            isDragging = false
        }
    }

    // MARK: - Extracted Layers

    @ViewBuilder
    private func backdropLayer(item: JellyfinItem, size: CGSize, parallaxOffset: CGFloat = 0) -> some View {
        let verticalParallax = scrollOffset > 0 ? scrollOffset * 0.5 : 0

        return VStack(spacing: 0) {
            AsyncImage(url: bannerBackdropURL(item: item)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                        .offset(x: parallaxOffset, y: verticalParallax)
                default:
                    Color(white: 0.12)
                }
            }
            .frame(width: size.width, height: bannerImageHeight + pullDown)
            .clipped()

            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height + pullDown)
    }

    @ViewBuilder
    private func gradientOverlay(size: CGSize) -> some View {
        ZStack(alignment: .bottom) {
            // Progressive blur
            VariableBlurView(startPoint: 0.45, endPoint: 0.7)

            // Subtle dark gradient for readability
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.4),
                    .init(color: .black.opacity(0.3), location: 0.7),
                    .init(color: .black.opacity(0.5), location: 1)
                ],
                startPoint: .top, endPoint: .bottom
            )
        }
        .frame(width: size.width, height: size.height + pullDown)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func contentOverlay(item: JellyfinItem, size: CGSize) -> some View {
        VStack(alignment: .center, spacing: 10) {
            LogoTitleView(
                title: item.name,
                logoURL: bannerLogoURL(item: item)
            )
            .frame(maxWidth: 280, alignment: .center)
            .multilineTextAlignment(.center)

            // Genre line: Type · Genre1 · Genre2
            genreLine(item: item)

            HStack(spacing: 10) {
                Button { onPlay(item) } label: { bannerPlayLabel }

                Button { onPlay(item) } label: {
                    Image(systemName: "info.circle")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 38)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func genreLine(item: JellyfinItem) -> some View {
        let typeLabel: String = if item.isMovie {
            String(localized: "Movie", bundle: AppState.currentBundle)
        } else if item.isEpisode {
            String(localized: "Episode", bundle: AppState.currentBundle)
        } else {
            String(localized: "Series", bundle: AppState.currentBundle)
        }
        let genres = item.genres ?? []
        let parts = [typeLabel] + genres.prefix(2)
        Text(parts.joined(separator: " \u{00B7} "))
            .font(.caption.weight(.medium))
            .foregroundStyle(.white.opacity(0.75))
            .allowsHitTesting(false)
    }

    private var bannerPlayLabel: some View {
        Label(String(localized: "Play", bundle: AppState.currentBundle), systemImage: "play.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 52)
            .padding(.vertical, 14)
            .background(.white, in: Capsule())
    }

    // MARK: - Dominant Color

    private func extractDominantColor(for item: JellyfinItem) {
        guard let url = bannerBackdropURL(item: item) else { return }
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let uiImage = UIImage(data: data) else { return }
            let color = uiImage.averageBottomColor()
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.5)) {
                    dominantColor = Color(color)
                }
            }
        }
    }

    // MARK: - URLs

    private func bannerBackdropURL(item: JellyfinItem) -> URL? {
        if let local = DownloadManager.localBackdropURL(itemId: item.id)
            ?? DownloadManager.localPosterURL(itemId: item.id) {
            return local
        }
        return JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: item.id, maxWidth: 1280)
    }

    private func bannerLogoURL(item: JellyfinItem) -> URL? {
        DownloadManager.localLogoURL(itemId: item.id)
            ?? JellyfinAPI.shared.logoURL(serverURL: serverURL, itemId: item.id)
    }
}

// MARK: - Cached Backdrop Image

/// Caches UIImage in @State so it persists across SwiftUI view rebuilds (e.g. returning from player).
private struct CachedBackdropImage: View {
    let url: URL?
    var parallaxX: CGFloat = 0
    var parallaxY: CGFloat = 0

    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        if let image {
            Image(uiImage: image)
                .resizable().aspectRatio(contentMode: .fill)
                .offset(x: parallaxX, y: parallaxY)
        } else {
            Color(white: 0.12)
                .onAppear { loadImage() }
        }
    }

    private func loadImage() {
        guard let url, url != loadedURL else { return }
        loadedURL = url
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url),
                  let img = UIImage(data: data) else { return }
            await MainActor.run { image = img }
        }
    }
}

// Skeleton placeholder while loading
struct HeroBannerPlaceholder: View {
    @State private var shimmer = false

    var body: some View {
        let size = bannerSize
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .center, spacing: 12) {
                // Logo placeholder
                RoundedRectangle(cornerRadius: 6)
                    .fill(.white.opacity(shimmer ? 0.12 : 0.07))
                    .frame(width: 180, height: 38)
                // Meta row
                RoundedRectangle(cornerRadius: 4)
                    .fill(.white.opacity(shimmer ? 0.1 : 0.05))
                    .frame(width: 110, height: 14)
                // Buttons
                HStack(spacing: 10) {
                    Capsule()
                        .fill(.white.opacity(shimmer ? 0.18 : 0.1))
                        .frame(width: 120, height: 44)
                    Capsule()
                        .fill(.white.opacity(shimmer ? 0.1 : 0.06))
                        .frame(width: 120, height: 44)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 38)
        }
        .frame(width: size.width, height: size.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                shimmer = true
            }
        }
    }
}


// MARK: - Poster Card (2:3) — gradient title overlay

struct PosterCardView: View {
    let item: JellyfinItem
    let serverURL: String
    var width: CGFloat = 120
    var showYear: Bool = true
    var showShadow: Bool = true

    var height: CGFloat { width * 3 / 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                posterImage
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // Gradient title overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.7)],
                    startPoint: .center, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    if item.userData?.played == true {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .background(Color.green, in: Circle())
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.horizontal, 6)
                    }
                    Text(displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .padding(.horizontal, 7)
                        .padding(.bottom, 6)
                }
                .frame(width: width, height: height)
            }
            .shadow(color: showShadow ? .black.opacity(0.3) : .clear, radius: 6, y: 3)

            if showYear, let year = item.productionYear {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width)
    }

    // For episodes in Latest Shows, show the parent series poster + name
    private var displayId: String { item.isEpisode ? (item.seriesId ?? item.id) : item.id }
    private var displayName: String { item.isEpisode ? (item.seriesName ?? item.name) : item.name }

    @ViewBuilder
    private var posterImage: some View {
        FallbackAsyncImage(
            primaryURL: DownloadManager.localPosterURL(itemId: displayId)
                ?? JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: displayId, imageType: "Primary", maxWidth: Int(width * 2)),
            fallbackURL: nil,
            placeholder: RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: item.isMovie ? "film" : "tv")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                )
        )
    }
}

// MARK: - Backdrop Card (16:9)

struct BackdropCardView<MenuContent: View>: View {
    let item: JellyfinItem
    let serverURL: String
    var width: CGFloat = 280
    var showPlayOverlay: Bool = false
    var overlayMenu: (() -> MenuContent)?

    var height: CGFloat { width * 9 / 16 }
}

extension BackdropCardView where MenuContent == EmptyView {
    init(item: JellyfinItem, serverURL: String, width: CGFloat = 280, showPlayOverlay: Bool = false) {
        self.item = item
        self.serverURL = serverURL
        self.width = width
        self.showPlayOverlay = showPlayOverlay
        self.overlayMenu = nil
    }
}

extension BackdropCardView {

    private var progressValue: Double? {
        guard let userData = item.userData,
              let position = userData.resumePositionSeconds,
              let totalTicks = item.runTimeTicks else { return nil }
        let total = Double(totalTicks) / 10_000_000
        guard total > 0 else { return nil }
        return min(position / total, 1.0)
    }

    private var remainingTimeString: String {
        guard let totalTicks = item.runTimeTicks else { return "" }
        let totalSeconds = Double(totalTicks) / 10_000_000
        let resumeSeconds = item.userData?.resumePositionSeconds ?? 0
        let remaining = max(totalSeconds - resumeSeconds, 0)
        let hours = Int(remaining) / 3600
        let minutes = (Int(remaining) % 3600) / 60
        if hours > 0 {
            return "\(hours) sa. \(minutes) dk."
        } else {
            return "\(minutes) dk."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                backdropImage
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

                if showPlayOverlay {
                    // Play overlay with blur
                    playOverlay
                } else {
                    // Bottom gradient
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.65)],
                        startPoint: .center, endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Progress bar
                    if let progress = progressValue {
                        VStack {
                            Spacer()
                            ProgressView(value: progress)
                                .tint(.white)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                        }
                        .frame(width: width, height: height)
                    }
                }

                // Watched badge
                if item.userData?.played == true {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                                .background(Color.green, in: Circle())
                                .padding(7)
                        }
                        Spacer()
                    }
                    .frame(width: width, height: height)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.isEpisode ? (item.seriesName ?? item.name) : item.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)

                if item.isEpisode, let season = item.parentIndexNumber, let ep = item.indexNumber {
                    Text(String(localized: "S\(season) \u{00B7} B\(ep) \u{2014} \(item.name)", bundle: AppState.currentBundle))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let mins = item.runtimeMinutes {
                    Text(String(format: NSLocalizedString("%lld min", comment: ""), Int64(mins)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playOverlay: some View {
        VStack {
            Spacer()

            // Blur background with fade
            VariableBlurView(startPoint: 0, endPoint: 0.5, style: .systemUltraThinMaterialDark)
                .frame(width: width, height: 44)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
                .overlay(alignment: .bottom) {
                    // Content — pinned to bottom of blur
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.caption)
                            .foregroundStyle(.white)

                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white)
                                .frame(width: 32 * (progressValue ?? 0))
                        }
                        .frame(width: 32, height: 4)

                        Text(remainingTimeString)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize()

                        Spacer()

                        if let overlayMenu {
                            Menu {
                                overlayMenu()
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.8))
                                    .frame(width: 24, height: 24)
                                    .contentShape(Rectangle())
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
        }
        .frame(width: width, height: height)
    }

    private var backdropPrimaryURL: URL? {
        // Prefer local cache for offline support
        if let local = DownloadManager.localBackdropURL(itemId: item.id)
            ?? DownloadManager.localPosterURL(itemId: item.id) {
            return local
        }
        if item.isEpisode {
            // Always try episode's own thumbnail first
            return JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: item.id, imageType: "Primary", maxWidth: Int(width * 2))
        }
        return JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: item.id, maxWidth: Int(width * 2))
            ?? JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: item.id, maxWidth: Int(width * 2))
    }

    private var backdropFallbackURL: URL? {
        if item.isEpisode, let seriesId = item.seriesId {
            // Fallback to series backdrop
            return DownloadManager.localBackdropURL(itemId: seriesId)
                ?? JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: seriesId, maxWidth: Int(width * 2))
        }
        return JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: item.id, maxWidth: Int(width * 2))
    }

    private var backdropImage: some View {
        FallbackAsyncImage(
            primaryURL: backdropPrimaryURL,
            fallbackURL: backdropFallbackURL,
            placeholder: RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay(
                    Image(systemName: "play.rectangle")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                )
        )
    }
}

// MARK: - Library Card

struct LibraryCardView: View {
    let library: JellyfinLibrary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            Text(library.name)
                .font(.subheadline.weight(.medium))

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var iconName: String {
        switch library.collectionType {
        case "movies":    return "film.stack"
        case "tvshows":   return "tv"
        case "music":     return "music.note"
        case "photos":    return "photo.on.rectangle"
        case "books":     return "book"
        default:          return "folder"
        }
    }
}

// MARK: - Section Header

struct SectionHeaderView: View {
    let title: LocalizedStringKey
    var action: (() -> Void)? = nil

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.bold())
            Spacer()
            if let action {
                Button(action: action) {
                    HStack(spacing: 3) {
                        Text(String(localized: "All", bundle: AppState.currentBundle))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 20)
    }
}
