import SwiftUI

struct ItemDetailView: View {
    let item: JellyfinItem

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = ItemDetailViewModel()
    @State private var activeItem: JellyfinItem
    @State private var itemToPlay: JellyfinItem?   // non-nil = player açık
    @State private var selectedSeason: JellyfinItem?

    init(item: JellyfinItem) {
        self.item = item
        _activeItem = State(initialValue: item)
    }

    // Genres/people/resolution come from vm.fullItem; everything else from activeItem
    private var displayItem: JellyfinItem { vm.fullItem ?? activeItem }
    private var activeDisplayItem: JellyfinItem { activeItem }  // for episode-specific fields

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    backdropSection
                    mainContent
                }
            }
            .ignoresSafeArea(edges: .top)
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.white)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await vm.toggleFavorite(item: item, appState: appState) }
                    } label: {
                        Label(vm.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                              systemImage: vm.isFavorite ? "heart.slash" : "heart")
                    }
                    Button {
                        Task { await vm.toggleWatched(item: item, appState: appState) }
                    } label: {
                        Label(vm.isWatched ? "Mark as Unwatched" : "Mark as Watched",
                              systemImage: vm.isWatched ? "eye.slash" : "eye")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .fullScreenCover(item: $itemToPlay, onDismiss: {
            AppDelegate.orientationLock = .portrait
            PlayerView.rotate(to: .portrait)
        }) { ep in
            PlayerContainerView(item: ep)
                .environmentObject(appState)
        }
        .task {
            await vm.load(item: item, appState: appState)
            if item.isSeries {
                // Find the season+episode where the user left off and jump straight to it
                let season = await vm.bestSeasonToOpen(appState: appState)
                selectedSeason = season
                if let sid = season?.id, let ep = vm.resumeEpisode(seasonId: sid) {
                    activeItem = ep   // show episode backdrop/meta/play button immediately
                }
            } else {
                selectedSeason = vm.seasons.first(where: { $0.indexNumber == item.parentIndexNumber })
                    ?? vm.seasons.first
                if let sid = selectedSeason?.id {
                    await vm.loadEpisodes(seasonId: sid, appState: appState)
                }
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            guard let sid = newSeason?.id else { return }
            Task { await vm.loadEpisodes(seasonId: sid, appState: appState) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackStopped)) { _ in
            Task {
                if let updated = try? await JellyfinAPI.shared.getItemDetails(
                    serverURL: appState.serverURL,
                    itemId: activeItem.id,
                    userId: appState.userId,
                    token: appState.token
                ) {
                    activeItem = updated
                }
            }
        }
    }

    // MARK: - Backdrop

    private var backdropSection: some View {
        ZStack(alignment: .bottomLeading) {
            let backdropId = activeItem.isEpisode ? (activeItem.seriesId ?? activeItem.id) : activeItem.id
            let url = JellyfinAPI.shared.backdropURL(serverURL: appState.serverURL, itemId: backdropId, maxWidth: 1280)

            GeometryReader { geo in
                Group {
                    if let url {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().aspectRatio(contentMode: .fill)
                                    .frame(width: geo.size.width, height: 360)
                                    .clipped()
                            default:
                                Rectangle().fill(Color(white: 0.12)).frame(height: 360)
                            }
                        }
                    } else {
                        Rectangle().fill(Color(white: 0.12)).frame(height: 360)
                    }
                }
            }
            .frame(height: 360)

            // Gradient overlay
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.5), location: 0.55),
                    .init(color: .black, location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 360)

            // Title overlay
            VStack(alignment: .leading, spacing: 6) {
                // Logo or title text
                let logoItemId = activeItem.isEpisode ? (activeItem.seriesId ?? activeItem.id) : activeItem.id
                LogoTitleView(
                    title: activeItem.isEpisode ? (activeItem.seriesName ?? activeItem.name) : activeItem.name,
                    logoURL: JellyfinAPI.shared.logoURL(serverURL: appState.serverURL, itemId: logoItemId)
                )

                // Episode subtitle
                if activeItem.isEpisode {
                    let sLabel = activeItem.parentIndexNumber.map { "S\($0)" } ?? ""
                    let eLabel = activeItem.indexNumber.map { "B\($0)" } ?? ""
                    Text("\(sLabel) • \(eLabel) - \(activeItem.name)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.85))
                }

                // Metadata chips
                metaChips

                // Genres
                if let genres = displayItem.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: ", "))
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private var metaChips: some View {
        HStack(spacing: 8) {
            if activeItem.isSeries {
                // Show season count for series
                let count = (displayItem.childCount ?? activeItem.childCount) ?? vm.seasons.count
                if count > 0 {
                    Text(count == 1 ? "1 Season" : "\(count) Seasons")
                        .metaStyle()
                }
            } else if activeItem.isSeason {
                // Show episode count for seasons
                if let seasonId = activeItem.id.isEmpty ? nil : activeItem.id,
                   let eps = vm.episodes[seasonId] {
                    let count = eps.count
                    if count > 0 {
                        Text(count == 1 ? "1 Episode" : "\(count) Episodes")
                            .metaStyle()
                    }
                }
            } else if let mins = activeItem.runtimeMinutes, mins > 0 {
                Text(String(format: NSLocalizedString("%lld min.", comment: ""), Int64(mins)))
                    .metaStyle()
            }
            if let date = activeItem.formattedPremiereDate {
                Text(date)
                    .metaStyle()
            }
            if let rating = displayItem.officialRating ?? activeItem.officialRating {
                Text(rating)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.5), lineWidth: 1))
            }
            if let res = displayItem.videoResolution ?? activeItem.videoResolution {
                Text(res)
                    .metaStyle()
            }
        }
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            actionButtons
            overviewSection
            ratingsSection
            if item.isSeries || item.isEpisode, !vm.seasons.isEmpty {
                episodeSection
            }
            if let people = displayItem.people, !people.isEmpty {
                castSection(people: people)
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            // Primary: Play / Resume with progress bar
            Button {
                Task { await startPlayback() }
            } label: {
                playButtonContent
            }
            .padding(.horizontal, 16)

            // Secondary glass buttons
            HStack(spacing: 10) {
                glassButton(
                    systemImage: vm.isWatched ? "eye.fill" : "eye",
                    label: vm.isWatched ? "Watched" : "Mark Watched",
                    active: vm.isWatched
                ) {
                    Task { await vm.toggleWatched(item: activeItem, appState: appState) }
                }
                glassButton(
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    label: "Favorite",
                    active: vm.isFavorite
                ) {
                    Task { await vm.toggleFavorite(item: activeItem, appState: appState) }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func glassButton(systemImage: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(active ? Color.accentColor : .white)
                    .frame(height: 26)
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
        .modify {
            if #available(iOS 26, *) {
                $0.glassEffect(in: Capsule())
            } else {
                $0.background(.ultraThinMaterial, in: Capsule())
                  .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.8))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Overview

    @ViewBuilder
    private var overviewSection: some View {
        if let overview = activeItem.overview ?? displayItem.overview, !overview.isEmpty {
            Text(overview)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .lineSpacing(3)
                .padding(.horizontal, 16)
        }
    }

    // MARK: - Ratings

    @ViewBuilder
    private var ratingsSection: some View {
        let hasRatings = displayItem.communityRating != nil || displayItem.criticRating != nil
        if hasRatings {
            HStack(spacing: 20) {
                if let rating = displayItem.communityRating {
                    VStack(spacing: 2) {
                        Text("TMDB")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text(String(format: "%.1f", rating))
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                    }
                }
                if let critic = displayItem.criticRating {
                    VStack(spacing: 2) {
                        Text("Critic")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.5))
                        Text("\(Int(critic))")
                            .font(.title3.bold())
                            .foregroundStyle(critic >= 60 ? .green : .red)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Episodes

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Inline season chips
            if vm.seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(vm.seasons) { season in
                            Button { selectedSeason = season } label: {
                                Text(season.name)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(selectedSeason?.id == season.id ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        selectedSeason?.id == season.id ? Color.white : Color.white.opacity(0.15),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                            .animation(.easeInOut(duration: 0.15), value: selectedSeason?.id)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            } else if let name = selectedSeason?.name {
                Text(name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
            }

            // Episode horizontal scroll
            if let seasonId = selectedSeason?.id, let eps = vm.episodes[seasonId] {
                let highlightId = currentHighlightId(seasonId: seasonId)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(eps) { episode in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        activeItem = episode
                                    }
                                } label: {
                                    EpisodeThumbnailView(
                                        episode: episode,
                                        serverURL: appState.serverURL,
                                        isCurrent: episode.id == highlightId
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(episode.id)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onAppear {
                        if let hid = highlightId {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                withAnimation { proxy.scrollTo(hid, anchor: .center) }
                            }
                        }
                    }
                    .onChange(of: activeItem.id) { _, _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            withAnimation { proxy.scrollTo(activeItem.id, anchor: .center) }
                        }
                    }
                }
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }

    // MARK: - Playback

    private func startPlayback() async {
        let target: JellyfinItem?
        if activeItem.isMovie || activeItem.isEpisode {
            target = activeItem
        } else if activeItem.isSeries {
            target = await vm.resumeEpisodeForSeries(appState: appState)
        } else {
            target = nil
        }
        guard let target else { return }
        AppDelegate.orientationLock = .allButUpsideDown
        itemToPlay = target
    }

    @ViewBuilder
    private var playButtonContent: some View {
        let resumePos = activeItem.userData?.resumePositionSeconds
        let totalSecs = activeItem.runTimeTicks.map { Double($0) / 10_000_000 }
        let hasResume = (resumePos ?? 0) > 60

        ZStack(alignment: .leading) {
            // Progress bar fill behind glass
            if hasResume, let pos = resumePos, let total = totalSecs, total > 0 {
                let progress = min(pos / total, 1)
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(width: geo.size.width * progress)
                        .clipped()
                }
            }

            // Label
            HStack(spacing: 8) {
                Image(systemName: hasResume ? "play.fill" : "play.fill")
                playButtonLabel
            }
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .modify {
            if #available(iOS 26, *) {
                $0.glassEffect(in: Capsule())
            } else {
                $0.background(.ultraThinMaterial, in: Capsule())
                  .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 0.8))
            }
        }
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        if activeItem.isEpisode || activeItem.isMovie,
           let pos = activeItem.userData?.resumePositionSeconds, pos > 60 {
            Text(String(format: NSLocalizedString("Continue  %@", comment: ""), formatTimestamp(pos)))
        } else if activeItem.isSeries {
            let ep = selectedSeason.flatMap { vm.resumeEpisode(seasonId: $0.id) }
            if let ep, let pos = ep.userData?.resumePositionSeconds, pos > 60 {
                Text(String(format: NSLocalizedString("Continue  S%lldE%lld", comment: ""), Int64(ep.parentIndexNumber ?? 1), Int64(ep.indexNumber ?? 1)))
            } else if let ep, let epNum = ep.indexNumber {
                Text(String(format: NSLocalizedString("Play  S%lldE%lld", comment: ""), Int64(ep.parentIndexNumber ?? 1), Int64(epNum)))
            } else {
                Text("Play")
            }
        } else {
            Text("Play")
        }
    }

    // MARK: - Helpers

    /// The episode ID to highlight in the list.
    /// - If we're viewing an episode: that episode.
    /// - If viewing a series: the resume/next episode.
    private func currentHighlightId(seasonId: String) -> String? {
        if activeItem.isEpisode { return activeItem.id }
        return vm.resumeEpisode(seasonId: seasonId)?.id
    }

    // MARK: - Cast

    private func castSection(people: [JellyfinPerson]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cast & Crew")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(people.prefix(15)) { person in
                        CastCardView(person: person, serverURL: appState.serverURL)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Helpers

    private func formatTimestamp(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%02d:%02d:%02d", h, m, s) }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Episode Thumbnail Card

struct EpisodeThumbnailView: View {
    let episode: JellyfinItem
    let serverURL: String
    let isCurrent: Bool

    private let cardWidth: CGFloat = 160
    private var cardHeight: CGFloat { cardWidth * 9 / 16 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                FallbackAsyncImage(
                    primaryURL: JellyfinAPI.shared.imageURL(serverURL: serverURL, itemId: episode.id, imageType: "Primary", maxWidth: 320),
                    fallbackURL: episode.seriesId.flatMap {
                        JellyfinAPI.shared.backdropURL(serverURL: serverURL, itemId: $0, maxWidth: 640)
                    },
                    placeholder: RoundedRectangle(cornerRadius: 10)
                        .fill(Color(white: 0.2))
                        .overlay(Image(systemName: "play.rectangle").foregroundStyle(.gray))
                )
                .frame(width: cardWidth, height: cardHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // Progress bar
                if let pos = episode.userData?.resumePositionSeconds,
                   let ticks = episode.runTimeTicks, ticks > 0 {
                    let progress = min(pos / (Double(ticks) / 10_000_000), 1.0)
                    VStack {
                        Spacer()
                        ProgressView(value: progress)
                            .tint(.white)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 4)
                    }
                    .frame(width: cardWidth, height: cardHeight)
                }

                // Watched badge
                if episode.userData?.played == true {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.white)
                                .background(Color.green, in: Circle())
                                .font(.caption)
                                .padding(5)
                        }
                        Spacer()
                    }
                    .frame(width: cardWidth, height: cardHeight)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isCurrent ? Color.accentColor : Color.clear, lineWidth: 2.5)
            )

            if let ep = episode.indexNumber {
                Text("\(ep). \(episode.name)")
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? .white : .white.opacity(0.65))
                    .lineLimit(2)
                    .frame(width: cardWidth, alignment: .leading)
            }
        }
    }
}

// MARK: - Logo Title

struct LogoTitleView: View {
    let title: String
    let logoURL: URL?

    @State private var logoFailed = false

    var body: some View {
        if !logoFailed, let url = logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 100, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 6)
                case .failure:
                    fallbackText.onAppear { logoFailed = true }
                case .empty:
                    fallbackText.opacity(0)
                @unknown default:
                    fallbackText
                }
            }
        } else {
            fallbackText
        }
    }

    private var fallbackText: some View {
        Text(title)
            .font(.system(size: 30, weight: .bold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 4)
            .lineLimit(3)
    }
}

// MARK: - Cast Card

struct CastCardView: View {
    let person: JellyfinPerson
    let serverURL: String

    var body: some View {
        VStack(spacing: 8) {
            let url = JellyfinAPI.shared.personImageURL(serverURL: serverURL, person: person)
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                default:
                    Circle().fill(Color(white: 0.25))
                        .overlay(
                            Text(String(person.name.prefix(1)))
                                .font(.title2.bold())
                                .foregroundStyle(.white.opacity(0.6))
                        )
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(Circle())

            VStack(spacing: 2) {
                Text(person.name)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(width: 80)
        }
    }
}

// MARK: - Meta text style

private extension Text {
    func metaStyle() -> some View {
        self
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.75))
    }
}

// MARK: - Conditional modifier helper

private extension View {
    @ViewBuilder
    func modify<Content: View>(@ViewBuilder _ transform: (Self) -> Content) -> some View {
        transform(self)
    }
}
