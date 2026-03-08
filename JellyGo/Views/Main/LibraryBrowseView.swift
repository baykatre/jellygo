import SwiftUI

struct LibraryBrowseView: View {
    @EnvironmentObject private var appState: AppState
    @State private var libraries: [JellyfinLibrary] = []
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if libraries.isEmpty {
                    ContentUnavailableView("Kütüphane Bulunamadı", systemImage: "square.grid.2x2")
                } else {
                    List {
                        ForEach(libraries) { library in
                            NavigationLink(value: library) {
                                LibraryRowView(library: library)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Kütüphane")
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
                libraries = (try? await JellyfinAPI.shared.getLibraries(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token
                )) ?? []
                isLoading = false
            }
            .refreshable {
                libraries = (try? await JellyfinAPI.shared.getLibraries(
                    serverURL: appState.serverURL,
                    userId: appState.userId,
                    token: appState.token
                )) ?? []
            }
        }
    }
}

private struct LibraryRowView: View {
    let library: JellyfinLibrary

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(library.name)
                    .font(.headline)
                if let ct = library.collectionType {
                    Text(collectionLabel(ct))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var icon: String {
        switch library.collectionType {
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
        case "playlists": return "Oynatma Listeleri"
        default:          return type.capitalized
        }
    }
}
