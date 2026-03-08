import SwiftUI

struct ItemDetailView: View {
    let item: JellyfinItem

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = ItemDetailViewModel()
    @State private var activeItem: JellyfinItem
    @State private var itemToPlay: JellyfinItem?   // non-nil = player açık
    @State private var selectedSeason: JellyfinItem?
    @State private var showSeasonPicker = false

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
                        Label(vm.isFavorite ? "Favorilerden Çıkar" : "Favorilere Ekle",
                              systemImage: vm.isFavorite ? "heart.slash" : "heart")
                    }
                    Button {
                        Task { await vm.toggleWatched(item: item, appState: appState) }
                    } label: {
                        Label(vm.isWatched ? "İzlenmedi İşaretle" : "İzlendi İşaretle",
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
            PlayerView(item: ep)
                .environmentObject(appState)
        }
        .task {
            await vm.load(item: item, appState: appState)
            selectedSeason = vm.seasons.first(where: { $0.indexNumber == item.parentIndexNumber })
                ?? vm.seasons.first
            // For series: auto-load first season episodes to find resume
            if let sid = selectedSeason?.id {
                await vm.loadEpisodes(seasonId: sid, appState: appState)
            }
        }
        .onChange(of: selectedSeason) { _, newSeason in
            guard let sid = newSeason?.id else { return }
            Task { await vm.loadEpisodes(seasonId: sid, appState: appState) }
        }
        .confirmationDialog("Sezon Seç", isPresented: $showSeasonPicker, titleVisibility: .visible) {
            ForEach(vm.seasons) { season in
                Button(season.name) { selectedSeason = season }
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
            if let mins = activeItem.runtimeMinutes {
                Text("\(mins) dk.")
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
        VStack(spacing: 12) {
            // Primary: Play / Resume
            Button {
                Task { await startPlayback() }
            } label: {
                HStack {
                    Image(systemName: "play.fill")
                    playButtonLabel
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 16)

            // Secondary icons
            HStack(spacing: 0) {
                actionIcon(
                    systemImage: vm.isWatched ? "eye.fill" : "eye",
                    label: "İzlendi",
                    active: vm.isWatched
                ) {
                    Task { await vm.toggleWatched(item: activeItem, appState: appState) }
                }
                actionIcon(systemImage: "bookmark", label: "Listele") {}
                actionIcon(systemImage: "star", label: "Puan") {}
                actionIcon(
                    systemImage: vm.isFavorite ? "heart.fill" : "heart",
                    label: "Favori",
                    active: vm.isFavorite
                ) {
                    Task { await vm.toggleFavorite(item: activeItem, appState: appState) }
                }
                actionIcon(systemImage: "arrow.down.circle", label: "İndir") {}
            }
            .padding(.horizontal, 8)
        }
    }

    @ViewBuilder
    private func actionIcon(systemImage: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 22))
                    .foregroundStyle(active ? Color.accentColor : .white)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
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
        VStack(alignment: .leading, spacing: 14) {
            // Season picker header
            Button { showSeasonPicker = true } label: {
                HStack(spacing: 6) {
                    Text(selectedSeason?.name ?? "Sezon")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 16)

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
        AppDelegate.orientationLock = .allButUpsideDown
        if activeItem.isMovie || activeItem.isEpisode {
            itemToPlay = activeItem
        } else if activeItem.isSeries {
            let ep = await vm.resumeEpisodeForSeries(appState: appState)
            guard let ep else {
                AppDelegate.orientationLock = .portrait
                return
            }
            itemToPlay = ep
        }
    }

    @ViewBuilder
    private var playButtonLabel: some View {
        if activeItem.isEpisode || activeItem.isMovie,
           let pos = activeItem.userData?.resumePositionSeconds, pos > 60 {
            Text("Devam Et  \(formatTimestamp(pos))")
        } else if activeItem.isSeries {
            let ep = selectedSeason.flatMap { vm.resumeEpisode(seasonId: $0.id) }
            if let ep, let pos = ep.userData?.resumePositionSeconds, pos > 60 {
                Text("Devam Et  S\(ep.parentIndexNumber ?? 1)B\(ep.indexNumber ?? 1)")
            } else if let ep, let epNum = ep.indexNumber {
                Text("Oynat  S\(ep.parentIndexNumber ?? 1)B\(epNum)")
            } else {
                Text("Oynat")
            }
        } else {
            Text("Oynat")
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
            Text("Kast ve Ekip")
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
