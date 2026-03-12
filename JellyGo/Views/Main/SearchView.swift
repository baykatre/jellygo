import SwiftUI

struct SearchView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SearchViewModel()
    @State private var query = ""
    @State private var isSearchFocused = false
    @State private var hasAppeared = false

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
        Group {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                if vm.recentItems.isEmpty {
                    emptyPrompt
                } else {
                    recentGrid
                }
            } else if vm.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.filteredResults.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                resultsGrid
            }
        }
        .navigationTitle(String(localized: "Search", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $query, isPresented: $isSearchFocused, placement: .navigationBarDrawer(displayMode: .always), prompt: String(localized: "Movies, series...", bundle: AppState.currentBundle))
        .onAppear {
            guard !hasAppeared else { return }
            hasAppeared = true
            isSearchFocused = true
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
        }
        .onChange(of: query) { _, new in
            vm.search(query: new, appState: appState)
        }
        .navigationDestination(for: JellyfinItem.self) { item in
            ItemDetailView(item: item)
        }
        }
    }

    // MARK: - Filter Menu

    private var filterMenu: some View {
        Menu {
            ForEach(SearchViewModel.SearchFilter.allCases, id: \.self) { filter in
                Button {
                    vm.filter = filter
                } label: {
                    Label(LocalizedStringKey(filter.rawValue), systemImage: filter.icon)
                    if vm.filter == filter {
                        Image(systemName: "checkmark")
                    }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .symbolVariant(vm.filter == .all ? .none : .fill)
        }
    }

    // MARK: - Recent Grid

    private var recentGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(String(localized: "Recent Searches", bundle: AppState.currentBundle))
                        .font(.title3.bold())
                    Spacer()
                    Button(String(localized: "Clear", bundle: AppState.currentBundle)) { vm.clearRecent() }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(vm.recentItems) { hint in
                        NavigationLink(value: JellyfinItem(fromHint: hint)) {
                            SearchResultCard(hint: hint, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Results Grid

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(vm.filteredResults) { hint in
                    NavigationLink(value: JellyfinItem(fromHint: hint)) {
                        SearchResultCard(hint: hint, serverURL: appState.serverURL)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded { vm.addToRecent(hint) })
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 32)
        }
    }

    // MARK: - Empty State

    private var emptyPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(String(localized: "Search for movies or series", bundle: AppState.currentBundle))
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(String(localized: "Start typing the name", bundle: AppState.currentBundle))
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search Result Card

struct SearchResultCard: View {
    let hint: JellyfinSearchHint
    let serverURL: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    fallbackPoster
                default:
                    Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) { typeTag }

            Text(hint.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(width: 120, alignment: .leading)

            if let year = hint.productionYear {
                Text(String(year))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let series = hint.series {
                Text(series)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 120)
    }

    private var posterURL: URL? {
        guard let base = URL(string: serverURL) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items/\(hint.itemId)/Images/Primary"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "240")]
        return components?.url
    }

    private var fallbackPoster: some View {
        ZStack {
            Color.secondary.opacity(0.15)
            VStack(spacing: 8) {
                Image(systemName: typeIcon)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(hint.name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .lineLimit(3)
            }
        }
    }

    private var typeTag: some View {
        Text(typeLabel)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(5)
    }

    private var typeLabel: LocalizedStringKey {
        switch hint.type {
        case "Movie":   return "Movie"
        case "Series":  return "Series"
        case "Episode": return "Episode"
        default:        return LocalizedStringKey(hint.type)
        }
    }

    private var typeIcon: String {
        switch hint.type {
        case "Movie":   return "film"
        case "Series":  return "tv"
        default:        return "play.rectangle"
        }
    }
}
