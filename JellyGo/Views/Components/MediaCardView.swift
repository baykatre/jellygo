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
    return CGSize(width: screen.width, height: screen.height * 0.62)
}

struct HeroBannerView: View {
    let items: [JellyfinItem]
    let serverURL: String
    var pullDown: CGFloat = 0
    var onPlay: (JellyfinItem) -> Void = { _ in }

    // Start at 1: looped array is [last, ...items..., first]
    @State private var currentIndex = 1
    @State private var pauseUntil: Date = .distantPast
    @State private var isAutoAdvance = false
    @State private var ignoreNextChange = false

    private let autoTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    // [items.last] + items + [items.first]
    private var looped: [JellyfinItem] {
        guard items.count > 1 else { return items }
        return [items[items.count - 1]] + items + [items[0]]
    }

    // Dot indicator maps looped index → real index
    private var dotIndex: Int {
        guard items.count > 1 else { return 0 }
        return max(0, min(currentIndex - 1, items.count - 1))
    }

    var body: some View {
        let size = bannerSize
        ZStack(alignment: .bottom) {
            TabView(selection: $currentIndex) {
                ForEach(Array(looped.enumerated()), id: \.offset) { i, item in
                    BannerPageView(item: item, serverURL: serverURL, size: size, pullDown: pullDown, onPlay: onPlay)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: size.width, height: size.height + pullDown)
            .onChange(of: currentIndex) { _, new in
                // Silent loop-jump triggered by us — skip all logic
                if ignoreNextChange {
                    ignoreNextChange = false
                    isAutoAdvance = false
                    return
                }
                defer { isAutoAdvance = false }

                // User swiped — pause timer
                if !isAutoAdvance {
                    pauseUntil = Date().addingTimeInterval(8)
                }

                // Hit duplicate boundary → silently snap to real counterpart
                if new == 0 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        ignoreNextChange = true
                        currentIndex = items.count   // last real item
                    }
                } else if new == looped.count - 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        ignoreNextChange = true
                        currentIndex = 1             // first real item
                    }
                }
            }

            if items.count > 1 {
                HStack(spacing: 5) {
                    ForEach(items.indices, id: \.self) { i in
                        Capsule()
                            .fill(i == dotIndex ? Color.white : Color.white.opacity(0.35))
                            .frame(width: i == dotIndex ? 20 : 5, height: 5)
                            .animation(.spring(duration: 0.3), value: dotIndex)
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .offset(y: -pullDown)
        .padding(.bottom, -pullDown)
        .onReceive(autoTimer) { now in
            guard items.count > 1, now >= pauseUntil else { return }
            isAutoAdvance = true
            withAnimation(.easeInOut(duration: 0.9)) {
                currentIndex += 1
            }
        }
    }
}

// Skeleton placeholder while loading
struct HeroBannerPlaceholder: View {
    @State private var shimmer = false

    var body: some View {
        let size = bannerSize
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(white: 0.18), Color(white: 0.08)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
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
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(shimmer ? 0.18 : 0.1))
                        .frame(width: 126, height: 44)
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.white.opacity(shimmer ? 0.1 : 0.06))
                        .frame(width: 126, height: 44)
                }
            }
            .padding(.horizontal, 20)
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

struct BannerPageView: View {
    let item: JellyfinItem
    let serverURL: String
    let size: CGSize
    var pullDown: CGFloat = 0
    let onPlay: (JellyfinItem) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            // Background image + gradients — tapping navigates to detail
            NavigationLink(value: item) {
                ZStack {
                    // Backdrop image — grows with pullDown
                    AsyncImage(url: backdropURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color(white: 0.12)
                        }
                    }
                    .frame(width: size.width, height: size.height + pullDown)
                    .clipped()

                    // Bottom gradient
                    VStack(spacing: 0) {
                        Spacer()
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.75), location: 0.5),
                                .init(color: .black, location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                        .frame(height: 280)
                    }

                    // Placeholder for button area so NavigationLink doesn't cover buttons
                    VStack {
                        Spacer()
                        Color.clear.frame(height: 82)
                    }
                }
                .frame(width: size.width, height: size.height + pullDown)
            }
            .buttonStyle(.plain)

            // Content overlay — outside NavigationLink
            VStack(alignment: .leading, spacing: 10) {
                LogoTitleView(
                    title: item.name,
                    logoURL: logoURL
                )
                .frame(maxWidth: 280, alignment: .leading)

                HStack(spacing: 8) {
                    if let year = item.productionYear {
                        Text(String(year))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Text(item.isMovie ? LocalizedStringKey("Movie") : LocalizedStringKey("Series"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.2), in: Capsule())
                    if let r = item.communityRating {
                        Label(String(format: "%.1f", r), systemImage: "star.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.yellow)
                    }
                }
                .allowsHitTesting(false)

                HStack(spacing: 10) {
                    // Oynat — film ise direkt player, dizi ise detail
                    if item.isMovie || item.isEpisode {
                        Button { onPlay(item) } label: { playLabel }
                    } else {
                        NavigationLink(value: item) { playLabel }.buttonStyle(.plain)
                    }

                    // Bilgi Al — her zaman detail
                    NavigationLink(value: item) {
                        Label(String(localized: "More Info", bundle: AppState.currentBundle), systemImage: "info.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 126, height: 44)
                            .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(.white.opacity(0.25), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 38)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
        .frame(width: size.width, height: size.height + pullDown)
    }

    private var playLabel: some View {
        Label(String(localized: "Play", bundle: AppState.currentBundle), systemImage: "play.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.black)
            .frame(width: 126, height: 44)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
    }

    private var backdropURL: URL? {
        // Prefer local cache for offline support
        if let local = DownloadManager.localBackdropURL(itemId: item.id)
            ?? DownloadManager.localPosterURL(itemId: item.id) {
            return local
        }
        return JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: item.id, maxWidth: 1280)
    }

    private var logoURL: URL? {
        DownloadManager.localLogoURL(itemId: item.id)
            ?? JellyfinAPI.shared.logoURL(serverURL: serverURL, itemId: item.id)
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

struct BackdropCardView: View {
    let item: JellyfinItem
    let serverURL: String
    var width: CGFloat = 280

    var height: CGFloat { width * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                backdropImage
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)

                // Bottom gradient
                LinearGradient(
                    colors: [.clear, .black.opacity(0.65)],
                    startPoint: .center, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))

                // Progress bar
                if let userData = item.userData,
                   let position = userData.resumePositionSeconds,
                   let totalTicks = item.runTimeTicks {
                    let total = Double(totalTicks) / 10_000_000
                    let progress = min(position / total, 1.0)
                    VStack {
                        Spacer()
                        ProgressView(value: progress)
                            .tint(.white)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 6)
                    }
                    .frame(width: width, height: height)
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
                    Text(String(localized: "S\(season) · B\(ep) — \(item.name)", bundle: AppState.currentBundle))
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
