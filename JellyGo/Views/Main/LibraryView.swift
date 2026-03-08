import SwiftUI

struct LibraryView: View {
    let library: JellyfinLibrary

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
                ContentUnavailableView("İçerik Bulunamadı", systemImage: "folder")
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
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: JellyfinItem.self) { item in
            ItemDetailView(item: item)
        }
        .task { await vm.load(libraryId: library.id, appState: appState) }
        .refreshable { await vm.load(libraryId: library.id, appState: appState) }
    }
}
