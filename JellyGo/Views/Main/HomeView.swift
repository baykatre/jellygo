import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = HomeViewModel()
    @State private var heroPlayItem: JellyfinItem?

    var body: some View {
        TabView {
            mainTab
                .tabItem { Label("Ana Sayfa", systemImage: "house.fill") }

            LibraryBrowseView()
                .tabItem { Label("Kütüphane", systemImage: "square.grid.2x2.fill") }

            SearchView()
                .tabItem { Label("Ara", systemImage: "magnifyingglass") }

            NavigationStack {
                ProfileView()
            }
            .tabItem { Label("Profil", systemImage: "person.fill") }
        }
        .task { await vm.load(appState: appState) }
    }

    // MARK: - Main Tab

    private var mainTab: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // Hero Banner
                    if vm.isLoading {
                        HeroBannerPlaceholder()
                    } else if !vm.featuredItems.isEmpty {
                        HeroBannerView(
                            items: vm.featuredItems,
                            serverURL: appState.serverURL,
                            onPlay: { item in
                                AppDelegate.orientationLock = .allButUpsideDown
                                heroPlayItem = item
                            }
                        )
                    }

                    // Content
                    VStack(alignment: .leading, spacing: 32) {
                        if !vm.continueWatching.isEmpty {
                            continueWatchingSection
                        }
                        if !vm.nextUp.isEmpty {
                            nextUpSection
                        }
                        if !vm.latestMovies.isEmpty {
                            latestMoviesSection
                        }
                        if !vm.latestShows.isEmpty {
                            latestShowsSection
                        }
                        if !vm.libraries.isEmpty {
                            librariesSection
                        }
                        if !vm.isLoading && vm.continueWatching.isEmpty && vm.nextUp.isEmpty &&
                           vm.latestMovies.isEmpty && vm.latestShows.isEmpty {
                            emptyView
                        }
                    }
                    .padding(.top, 28)
                    .padding(.bottom, 40)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationTitle("")
            .refreshable { await vm.load(appState: appState) }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
            .navigationDestination(for: JellyfinLibrary.self) { library in
                LibraryView(library: library)
            }
            .overlay(alignment: .bottom) {
                if let error = vm.error {
                    errorBanner(message: error)
                }
            }
            .fullScreenCover(item: $heroPlayItem, onDismiss: {
                AppDelegate.orientationLock = .portrait
                PlayerView.rotate(to: .portrait)
            }) { item in
                PlayerView(item: item)
                    .environmentObject(appState)
            }
        }
    }

    // MARK: - Sections

    private var continueWatchingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Devam Et")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.continueWatching) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var nextUpSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Sıradaki Bölüm")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(vm.nextUp) { item in
                        NavigationLink(value: item) {
                            BackdropCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var latestMoviesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Son Eklenen Filmler")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.latestMovies) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var latestShowsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Son Eklenen Diziler")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.latestShows) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private var librariesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeaderView(title: "Kütüphaneler")
            VStack(spacing: 8) {
                ForEach(vm.libraries) { library in
                    NavigationLink(value: library) {
                        LibraryCardView(library: library)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    // MARK: - States

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("İçerik bulunamadı")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

// MARK: - Shimmer Placeholder

struct ShimmerRowView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 140, height: 18)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
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

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showLogoutAlert = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.username)
                            .font(.headline)
                        Text(appState.serverName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("Sunucu") {
                LabeledContent("Adres", value: appState.serverURL)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("Dil Ayarları", systemImage: "globe")
                }
            }

            Section {
                Button(role: .destructive) {
                    showLogoutAlert = true
                } label: {
                    Label("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        .navigationTitle("Profil")
        .alert("Çıkış Yap", isPresented: $showLogoutAlert) {
            Button("Çıkış Yap", role: .destructive) { appState.logout() }
            Button("İptal", role: .cancel) {}
        } message: {
            Text("Hesabınızdan çıkmak istediğinize emin misiniz?")
        }
    }
}

#Preview {
    HomeView()
        .environmentObject(AppState())
}
