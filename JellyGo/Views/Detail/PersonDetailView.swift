import SwiftUI

struct PersonDetailView: View {
    let person: JellyfinPerson

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = PersonDetailViewModel()

    private let columns = [GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 12)]

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                header
                content
                    .padding(.top, 24)
                    .padding(.bottom, 60)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .task { await vm.load(person: person, appState: appState) }
    }

    private func personImageURL(maxWidth: Int) -> URL? {
        guard var components = URLComponents(string: appState.serverURL) else { return nil }
        components.path = "/Items/\(person.id)/Images/Primary"
        var items = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        if vm.imageVersion > 0 {
            items.append(URLQueryItem(name: "v", value: "\(vm.imageVersion)"))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Header

    private var header: some View {
        ZStack(alignment: .bottom) {
            // Blurred bg from person image
            AsyncImage(url: personImageURL(maxWidth: 400)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                        .frame(height: 240)
                        .clipped()
                        .blur(radius: 30)
                        .overlay(Color(.systemBackground).opacity(0.55))
                } else {
                    Color(.systemGray6).frame(height: 240)
                }
            }

            VStack(spacing: 12) {
                // Circle photo
                Group {
                    AsyncImage(url: personImageURL(maxWidth: 400)) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Circle().fill(Color(.systemGray4))
                                .overlay(
                                    Text(String(person.name.prefix(1)))
                                        .font(.system(size: 44, weight: .bold))
                                        .foregroundStyle(.secondary)
                                )
                        }
                    }
                }
                .frame(width: 120, height: 120)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)

                VStack(spacing: 4) {
                    Text(person.name)
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                    if !person.type.isEmpty && person.type != "Unknown" {
                        Text(person.type)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 20)
            }
        }
        .frame(height: 320)
        .clipped()
    }

    // MARK: - Content

    // MARK: - Info helpers

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f
    }()

    private var ageText: String? {
        guard let birth = vm.birthDate else { return nil }
        let end = vm.deathDate ?? Date()
        let components = Calendar.current.dateComponents([.year], from: birth, to: end)
        guard let years = components.year, years >= 0 else { return nil }
        return "\(years)"
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 28) {
            if vm.birthDate != nil || vm.birthPlace != nil || vm.knownForDepartment != nil {
                infoSection
            }
            if let bio = vm.biography, !bio.isEmpty {
                biographySection(bio)
            }
            if !vm.filmography.isEmpty {
                filmographySection
            } else if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let dept = vm.knownForDepartment {
                infoRow(label: "Known For", value: dept)
            }
            if let birth = vm.birthDate {
                let text: String = {
                    let dateStr = Self.displayDateFormatter.string(from: birth)
                    if let age = ageText, vm.deathDate == nil {
                        return "\(dateStr) (age \(age))"
                    }
                    return dateStr
                }()
                infoRow(label: "Born", value: text)
            }
            if let place = vm.birthPlace {
                infoRow(label: "Birthplace", value: place)
            }
            if let death = vm.deathDate {
                let text: String = {
                    let dateStr = Self.displayDateFormatter.string(from: death)
                    if let age = ageText {
                        return "\(dateStr) (age \(age))"
                    }
                    return dateStr
                }()
                infoRow(label: "Died", value: text)
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minWidth: 80, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func biographySection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Biography")
                .font(.title3.bold())
            Text(bio)
                .font(.subheadline)
                .foregroundStyle(Color(.label).opacity(0.72))
                .lineSpacing(4)
        }
    }

    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Known For")
                .font(.title3.bold())

            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(vm.filmography) { item in
                    NavigationLink {
                        ItemDetailView(item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            AsyncImage(url: JellyfinAPI.shared.imageURL(
                                serverURL: appState.serverURL,
                                itemId: item.id,
                                imageType: "Primary",
                                maxWidth: 280
                            )) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable().aspectRatio(contentMode: .fill)
                                default:
                                    Color(.systemGray5)
                                }
                            }
                            .aspectRatio(2/3, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            Text(item.name)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(2)

                            if let year = item.productionYear {
                                Text(String(year))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
