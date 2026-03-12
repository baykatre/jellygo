import SwiftUI

struct LibraryView: View {
    var library: JellyfinLibrary? = nil
    var itemTypes: [String]? = nil
    var title: String? = nil

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = LibraryViewModel()

    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 140), spacing: 14)
    ]

    var body: some View {
        ScrollView {
            if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
            } else if vm.items.isEmpty {
                ContentUnavailableView("No Content Found", systemImage: "folder")
                    .padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(vm.items) { item in
                        NavigationLink(value: item) {
                            PosterCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if item.id == vm.items.last?.id {
                                Task { await vm.loadMore() }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                if vm.isLoadingMore {
                    ProgressView()
                        .padding()
                }
            }
        }
        .navigationTitle(title ?? library?.name ?? "")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: JellyfinItem.self) { item in
            ItemDetailView(item: item)
        }
        .task { await loadContent() }
        .refreshable { await loadContent() }
    }

    private func loadContent() async {
        if let itemTypes {
            await vm.load(itemTypes: itemTypes, appState: appState)
        } else if let library {
            await vm.load(libraryId: library.id, appState: appState)
        }
    }
}
