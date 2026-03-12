import SwiftUI

struct MediaBrowseView: View {
    let category: String
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: MediaBrowseViewModel
    @State private var selectedGenre: String?
    @State private var heroPlayItem: JellyfinItem?
    @State private var heroPullDown: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var isRefreshing = false
    @State private var pullTriggered = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !vm.availableGenres.isEmpty {
                    genreBar
                }

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Hero Banner
                        if vm.isLoading {
                            HeroBannerPlaceholder()
                        } else if !vm.featuredItems.isEmpty {
                            HeroBannerView(
                                items: vm.featuredItems,
                                serverURL: vm.serverURL,
                                pullDown: heroPullDown,
                                onPlay: { item in
                                    if item.isMovie || item.isEpisode {
                                        AppDelegate.orientationLock = .landscape
                                        PlayerContainerView.rotate(to: .landscapeRight)
                                        Task {
                                            try? await Task.sleep(for: .milliseconds(300))
                                            heroPlayItem = item
                                        }
                                    }
                                }
                            )
                        }

                        // Content sections
                        VStack(alignment: .leading, spacing: 32) {
                            if !vm.recentlyAdded.isEmpty {
                                posterSection(
                                    title: LocalizedStringKey("Recently Added"),
                                    items: vm.recentlyAdded
                                )
                            }

                            if !vm.topRated.isEmpty {
                                posterSection(
                                    title: LocalizedStringKey("Top Rated"),
                                    items: vm.topRated
                                )
                            }

                            if !vm.favorites.isEmpty {
                                posterSection(
                                    title: LocalizedStringKey("Favorites"),
                                    items: vm.favorites
                                )
                            }

                            // Genre sub-sections
                            ForEach(vm.genreSections, id: \.genre) { section in
                                posterSection(
                                    title: LocalizedStringKey(section.genre),
                                    items: section.items
                                )
                            }

                            // All items grid
                            if !vm.allItems.isEmpty {
                                allItemsGrid
                            }
                        }
                        .padding(.top, 28)
                        .padding(.bottom, 40)
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geo in
                    geo.contentOffset.y + geo.contentInsets.top
                } action: { _, offset in
                    scrollOffset = offset
                    heroPullDown = max(0, -offset)
                    if offset < -100 && !isRefreshing && !pullTriggered {
                        pullTriggered = true
                        isRefreshing = true
                        Task {
                            await vm.loadCategory(category: category, appState: appState, genre: selectedGenre, isRefresh: true)
                            isRefreshing = false
                        }
                    }
                    if offset >= 0 && pullTriggered {
                        pullTriggered = false
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                categoryTitle
                    .opacity(max(0.0, 1.0 - (scrollOffset / 100.0)))
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .top) {
                if isRefreshing {
                    ProgressView()
                        .tint(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.top, 44)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isRefreshing)
            .ignoresSafeArea(edges: .top)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .fullScreenCover(item: $heroPlayItem, onDismiss: {
                appState.isPlayerActive = false
                AppDelegate.orientationLock = .portrait
                PlayerContainerView.rotate(to: .portrait)
            }) { item in
                PlayerContainerView(item: item)
                    .environmentObject(appState)
                    .onAppear { appState.isPlayerActive = true }
            }
        }
        .task(id: appState.sessionId) {
            guard vm.featuredItems.isEmpty else { return }
            await vm.loadGenres(category: category, appState: appState)
            await vm.loadCategory(category: category, appState: appState, genre: selectedGenre)
        }
    }

    // MARK: - Category Title

    private var categoryTitle: some View {
        Text(category == "Movie"
             ? String(localized: "Movies", bundle: AppState.currentBundle)
             : String(localized: "TV Shows", bundle: AppState.currentBundle))
            .font(.largeTitle.bold())
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
            .padding(.horizontal, 20)
            .padding(.top, 80)
    }

    // MARK: - Genre Bar

    @Namespace private var genreNamespace

    private var genreBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    genreChip(String(localized: "All", bundle: AppState.currentBundle), genre: nil)

                    ForEach(vm.availableGenres, id: \.self) { genre in
                        genreChip(genre, genre: genre)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .onChange(of: selectedGenre) { _, newValue in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(newValue ?? "all_chip", anchor: .center)
                }
            }
        }
        .background {
            VStack {
                Spacer()
                Rectangle()
                    .fill(.quaternary)
                    .frame(height: 0.5)
            }
        }
    }

    private func genreChip(_ label: String, genre: String?) -> some View {
        let isSelected = selectedGenre == genre
        return Button {
            guard !isSelected else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedGenre = genre
            }
            Task { await vm.loadCategory(category: category, appState: appState, genre: genre) }
        } label: {
            Text(label)
                .font(.subheadline.weight(isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? .white : .secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.tint)
                            .matchedGeometryEffect(id: "genreChip", in: genreNamespace)
                    } else {
                        Capsule()
                            .fill(.quaternary)
                    }
                }
        }
        .buttonStyle(.plain)
        .id(genre ?? "all_chip")
    }

    // MARK: - Poster Section

    private func posterSection(title: LocalizedStringKey, items: [JellyfinItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: vm.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    // MARK: - All Items Grid

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

    private var allItemsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "All")

            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(vm.allItems) { item in
                    NavigationLink(value: item) {
                        PosterCardView(item: item, serverURL: vm.serverURL, showYear: true)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == vm.allItems.last?.id {
                            Task { await vm.loadMore(appState: appState) }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)

            if vm.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
    }
}
