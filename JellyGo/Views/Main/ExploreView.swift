import SwiftUI

struct ExploreView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: ExploreViewModel
    @State private var heroPlayItem: JellyfinItem?
    @State private var heroPullDown: CGFloat = 0
    @State private var titleOpacity: Double = 1
    @State private var isRefreshing = false
    @State private var pullTriggered = false
    @State private var showSearch = false

    var body: some View {
        NavigationStack {
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
                            },
                        )
                    }

                    // Sabit section'lar (hep yüklü, progressive olarak dolar)
                    VStack(alignment: .leading, spacing: 32) {
                        if !vm.latestMovies.isEmpty {
                            posterSection(
                                title: LocalizedStringKey("Recently Added Movies"),
                                items: vm.latestMovies,
                                destination: .latestMovies()
                            )
                        }

                        if !vm.latestSeries.isEmpty {
                            posterSection(
                                title: LocalizedStringKey("Recently Added TV Shows"),
                                items: vm.latestSeries,
                                destination: .latestSeries()
                            )
                        }

                        if !vm.topRatedMovies.isEmpty {
                            posterSection(
                                title: LocalizedStringKey("Top Rated Movies"),
                                items: vm.topRatedMovies,
                                destination: .topRatedMovies()
                            )
                        }

                        if !vm.topRatedSeries.isEmpty {
                            posterSection(
                                title: LocalizedStringKey("Top Rated TV Shows"),
                                items: vm.topRatedSeries,
                                destination: .topRatedSeries()
                            )
                        }

                        if !vm.favorites.isEmpty {
                            posterSection(
                                title: LocalizedStringKey("Favorites"),
                                items: vm.favorites,
                                destination: .favorites()
                            )
                        }
                    }
                    .padding(.top, 28)

                    // Genre section'lar — LazyVStack'in direkt child'ı,
                    // sadece ekrana gelince yüklenir
                    ForEach(vm.pendingGenres, id: \.self) { genre in
                        Group {
                            if let section = vm.genreSections.first(where: { $0.genre == genre }) {
                                posterSection(
                                    title: LocalizedStringKey(section.genre),
                                    items: section.items
                                )
                            } else {
                                // Yüklenirken iskelet göster
                                genreSkeletonRow
                            }
                        }
                        .padding(.top, 32)
                        .task { await vm.loadGenreIfNeeded(genre) }
                    }

                    Color.clear.frame(height: 40)
                }
            }
            .ignoresSafeArea(edges: .top)
            .scrollEdgeEffectStyle(.none, for: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y + geo.contentInsets.top
            } action: { _, offset in
                heroPullDown = max(0, -offset)
                let opacity = max(0.0, 1.0 - (offset / 100.0))
                if abs(opacity - titleOpacity) > 0.02 { titleOpacity = opacity }
                if offset < -100 && !isRefreshing && !pullTriggered {
                    pullTriggered = true
                    isRefreshing = true
                    Task {
                        await vm.refresh(appState: appState)
                        isRefreshing = false
                    }
                }
                if offset >= 0 && pullTriggered {
                    pullTriggered = false
                }
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
            .overlay(alignment: .top) {
                HStack {
                    Text(String(localized: "Explore", bundle: AppState.currentBundle))
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 4, y: 2)

                    Spacer()

                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 4, y: 2)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 4)
                .opacity(titleOpacity)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationDestination(for: JellyfinItem.self) { item in
                ExploreDetailWrapper(item: item)
            }
            .navigationDestination(for: ExploreBrowseDestination.self) { dest in
                ExploreSectionListView(destination: dest)
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
            .fullScreenCover(isPresented: $showSearch) {
                SearchView()
                    .environmentObject(appState)
            }
        }
        .task(id: appState.sessionId) {
            guard vm.featuredItems.isEmpty else { return }
            await vm.load(appState: appState)
        }
    }

    // MARK: - Poster Section

    private func posterSection(
        title: LocalizedStringKey,
        items: [JellyfinItem],
        destination: ExploreBrowseDestination? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let destination {
                NavigationLink(value: destination) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.bold())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            } else {
                SectionHeaderView(title: title)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
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

    // MARK: - Genre Skeleton

    private var genreSkeletonRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 140, height: 18)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(0..<5, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 10)
                            .fill(.quaternary)
                            .frame(width: 120, height: 180)
                    }
                }
                .padding(.horizontal, 20)
            }
            .disabled(true)
        }
    }
}

// MARK: - Detail Wrapper (X button instead of back)

private struct ExploreDetailWrapper: View {
    let item: JellyfinItem

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ItemDetailView(item: item)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                    }
                }
            }
    }
}

// MARK: - Navigation Destination

struct ExploreBrowseDestination: Hashable {
    let title: String
    let itemTypes: [String]
    let sortBy: String
    let sortOrder: String
    let filters: String?

    static func latestMovies() -> Self {
        .init(title: String(localized: "Recently Added Movies", bundle: AppState.currentBundle),
              itemTypes: ["Movie"], sortBy: "DateCreated", sortOrder: "Descending", filters: nil)
    }
    static func latestSeries() -> Self {
        .init(title: String(localized: "Recently Added TV Shows", bundle: AppState.currentBundle),
              itemTypes: ["Series"], sortBy: "DateCreated", sortOrder: "Descending", filters: nil)
    }
    static func topRatedMovies() -> Self {
        .init(title: String(localized: "Top Rated Movies", bundle: AppState.currentBundle),
              itemTypes: ["Movie"], sortBy: "CommunityRating", sortOrder: "Descending", filters: nil)
    }
    static func topRatedSeries() -> Self {
        .init(title: String(localized: "Top Rated TV Shows", bundle: AppState.currentBundle),
              itemTypes: ["Series"], sortBy: "CommunityRating", sortOrder: "Descending", filters: nil)
    }
    static func favorites() -> Self {
        .init(title: String(localized: "Favorites", bundle: AppState.currentBundle),
              itemTypes: ["Movie", "Series"], sortBy: "SortName", sortOrder: "Ascending", filters: "IsFavorite")
    }
}
