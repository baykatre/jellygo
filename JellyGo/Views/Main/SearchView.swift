import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = SearchViewModel()
    @State private var query = ""

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterChips
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()

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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Ara")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Film, dizi, bölüm...")
            .onChange(of: query) { _, new in
                vm.search(query: new, appState: appState)
            }
            .navigationDestination(for: JellyfinItem.self) { item in
                ItemDetailView(item: item)
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SearchViewModel.SearchFilter.allCases, id: \.self) { filter in
                    Button {
                        vm.filter = filter
                    } label: {
                        Label(LocalizedStringKey(filter.rawValue), systemImage: filter.icon)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(
                                vm.filter == filter
                                    ? Color.accentColor
                                    : Color(.secondarySystemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(vm.filter == filter ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: vm.filter)
                }
            }
        }
    }

    // MARK: - Recent Grid

    private var recentGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Son Arananlar")
                        .font(.title3.bold())
                    Spacer()
                    Button("Temizle") { vm.clearRecent() }
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
            Text("Film veya dizi ara")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Adını yazmaya başla")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Search Result Card

private struct SearchResultCard: View {
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
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 120, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                typeTag
            }

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
            Color(.secondarySystemBackground)
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
        case "Movie":   return "Film"
        case "Series":  return "Dizi"
        case "Episode": return "Bölüm"
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
