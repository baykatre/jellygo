import SwiftUI

struct ExploreSectionListView: View {
    let destination: ExploreBrowseDestination
    @EnvironmentObject private var appState: AppState
    @State private var items: [JellyfinItem] = []
    @State private var totalItems: Int = 0
    @State private var isLoading = true
    @State private var isLoadingMore = false

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(items) { item in
                    NavigationLink(value: item) {
                        PosterCardView(item: item, serverURL: appState.serverURL, showYear: true)
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        if item.id == items.last?.id {
                            Task { await loadMore() }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 40)

            if isLoading || isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            }
        }
        .navigationTitle(destination.title)
        .navigationDestination(for: JellyfinItem.self) { item in
            ItemDetailView(item: item)
        }
        .task {
            guard items.isEmpty else { return }
            await loadInitial()
        }
    }

    private func loadInitial() async {
        isLoading = true
        let response = try? await JellyfinAPI.shared.getItems(
            serverURL: appState.serverURL,
            userId: appState.userId,
            token: appState.token,
            itemTypes: destination.itemTypes,
            sortBy: destination.sortBy,
            sortOrder: destination.sortOrder,
            limit: 50,
            recursive: true,
            filters: destination.filters
        )
        items = response?.items ?? []
        totalItems = response?.totalRecordCount ?? 0
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, items.count < totalItems else { return }
        isLoadingMore = true
        let response = try? await JellyfinAPI.shared.getItems(
            serverURL: appState.serverURL,
            userId: appState.userId,
            token: appState.token,
            itemTypes: destination.itemTypes,
            sortBy: destination.sortBy,
            sortOrder: destination.sortOrder,
            startIndex: items.count,
            limit: 50,
            recursive: true,
            filters: destination.filters
        )
        if let newItems = response?.items {
            items.append(contentsOf: newItems)
        }
        isLoadingMore = false
    }
}
