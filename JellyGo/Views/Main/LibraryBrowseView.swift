import SwiftUI

struct LibraryBrowseView: View {
    @EnvironmentObject private var appState: AppState
    @State private var libraries: [JellyfinLibrary] = []
    @State private var isLoading = false
    @State private var favoriteCoverURL: URL? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            // Favorites card
                            NavigationLink(destination: FavoritesView()) {
                                favoritesCard()
                            }
                            .buttonStyle(.plain)

                            // Library cards
                            ForEach(libraries) { library in
                                NavigationLink(value: library) {
                                    libraryCard(library)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .navigationDestination(for: JellyfinLibrary.self) { library in
                LibraryView(library: library)
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .task {
                guard libraries.isEmpty else { return }
                isLoading = true
                async let libs = JellyfinAPI.shared.getLibraries(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token
                )
                async let favs = JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    sortBy: "Random",
                    startIndex: 0,
                    limit: 10,
                    recursive: true,
                    filters: "IsFavorite"
                )
                libraries = (try? await libs) ?? []
                if let response = try? await favs, let item = response.items.randomElement() {
                    favoriteCoverURL = JellyfinAPI.shared.imageURL(
                        serverURL: appState.serverURL,
                        itemId: item.id,
                        imageType: "Primary",
                        maxWidth: 800
                    )
                }
                isLoading = false
            }
            .refreshable {
                async let libs = JellyfinAPI.shared.getLibraries(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token
                )
                async let favs = JellyfinAPI.shared.getItems(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token,
                    sortBy: "Random",
                    startIndex: 0,
                    limit: 10,
                    recursive: true,
                    filters: "IsFavorite"
                )
                libraries = (try? await libs) ?? []
                if let response = try? await favs, let item = response.items.randomElement() {
                    favoriteCoverURL = JellyfinAPI.shared.imageURL(
                        serverURL: appState.serverURL,
                        itemId: item.id,
                        imageType: "Primary",
                        maxWidth: 800
                    )
                }
            }
        }
    }

    // MARK: - Library Image Card

    private func libraryCard(_ library: JellyfinLibrary) -> some View {
        let primaryURL = JellyfinAPI.shared.imageURL(
            serverURL: appState.serverURL,
            itemId: library.id,
            imageType: "Primary",
            maxWidth: 800
        )

        return ZStack(alignment: .bottomLeading) {
            AsyncImage(url: primaryURL) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(.secondarySystemGroupedBackground)
                        .overlay(
                            Image(systemName: libraryIcon(library.collectionType))
                                .font(.system(size: 40))
                                .foregroundStyle(.tertiary)
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipped()

            // Gradient overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                if let ct = library.collectionType {
                    Text(collectionLabel(ct))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Favorites Card

    private func favoritesCard() -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let url = favoriteCoverURL {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color(.secondarySystemGroupedBackground)
                        }
                    }
                } else {
                    Color(.secondarySystemGroupedBackground)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .clipped()

            // Black tint overlay
            Color.black.opacity(0.35)

            LinearGradient(
                colors: [.clear, .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Favoriler")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                Text("Beğendiklerim")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 140)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func libraryIcon(_ type: String?) -> String {
        switch type {
        case "movies":    return "film.stack"
        case "tvshows":   return "tv"
        case "music":     return "music.note"
        case "books":     return "books.vertical"
        case "photos":    return "photo.on.rectangle"
        case "playlists": return "list.bullet"
        default:          return "folder"
        }
    }

    private func collectionLabel(_ type: String) -> String {
        switch type {
        case "movies":    return "Filmler"
        case "tvshows":   return "Diziler"
        case "music":     return "Müzik"
        case "books":     return "Kitaplar"
        case "photos":    return "Fotoğraflar"
        case "playlists": return "Çalma Listeleri"
        default:          return type.capitalized
        }
    }
}

// MARK: - Favorites View

struct FavoritesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [JellyfinItem] = []
    @State private var isLoading = false
    @State private var totalCount = 0

    private let pageSize = 50
    private let gridColumns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView(
                    "Favori Yok",
                    systemImage: "heart.slash",
                    description: Text("Beğendiğiniz içerikleri favorilere ekleyin.")
                )
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: gridColumns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(value: item) {
                                PosterCardView(item: item, serverURL: appState.serverURL)
                            }
                            .buttonStyle(.plain)
                            .onAppear {
                                if item.id == items.last?.id && items.count < totalCount {
                                    Task { await loadMore() }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)

                    if isLoading {
                        ProgressView().padding()
                    }
                }
            }
        }
        .navigationTitle("Favoriler")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadInitial() }
        .refreshable { await loadInitial() }
    }

    private func loadInitial() async {
        isLoading = true
        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                sortBy: "SortName",
                startIndex: 0,
                limit: pageSize,
                recursive: true,
                filters: "IsFavorite"
            )
            items = response.items
            totalCount = response.totalRecordCount
        } catch {}
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoading, items.count < totalCount else { return }
        isLoading = true
        do {
            let response = try await JellyfinAPI.shared.getItems(
                serverURL: appState.serverURL,
                userId: appState.userId,
                token: appState.token,
                sortBy: "SortName",
                startIndex: items.count,
                limit: pageSize,
                recursive: true,
                filters: "IsFavorite"
            )
            items.append(contentsOf: response.items)
            totalCount = response.totalRecordCount
        } catch {}
        isLoading = false
    }
}
