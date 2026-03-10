import SwiftUI

struct PersonDetailView: View {
    let person: JellyfinPerson

    @EnvironmentObject private var appState: AppState
    @StateObject private var vm = PersonDetailViewModel()
    @Environment(\.dismiss) private var dismiss
    @State private var bioExpanded = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headerSection
                        .padding(.top, 8)
                    mainContent
                        .padding(.top, 24)
                        .padding(.bottom, 60)
                }
            }
            .background(Color(.systemBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .task {
                await vm.load(person: person, appState: appState)
            }
        }
    }

    // MARK: - Person Image Helper

    private func personImageURL(maxWidth: Int) -> URL? {
        if let local = DownloadManager.localPersonURL(personId: person.id) { return local }
        guard !(AppState.shared?.manualOffline ?? false),
              var components = URLComponents(string: appState.serverURL) else { return nil }
        components.path = "/Items/\(person.id)/Images/Primary"
        var items = [URLQueryItem(name: "maxWidth", value: "\(maxWidth)")]
        if vm.imageVersion > 0 {
            items.append(URLQueryItem(name: "v", value: "\(vm.imageVersion)"))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Person photo
            AsyncImage(url: personImageURL(maxWidth: 400)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                default:
                    Color(.systemGray5)
                        .overlay(
                            Text(String(person.name.prefix(1)))
                                .font(.system(size: 44, weight: .bold))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(width: 140, height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 12, y: 4)

            // Name + role
            VStack(spacing: 4) {
                Text(person.name)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                if let dept = vm.knownForDepartment {
                    Text(dept)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else if !person.type.isEmpty && person.type != "Unknown" {
                    Text(person.type)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Info chips
            if vm.birthDate != nil || vm.birthPlace != nil || vm.deathDate != nil {
                infoChips
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: - Info Chips

    private var infoChips: some View {
        FlowLayout(spacing: 8) {
            if let birth = vm.birthDate {
                let dateStr = Self.displayDateFormatter.string(from: birth)
                if let age = ageText, vm.deathDate == nil {
                    chipView(icon: "birthday.cake", text: "\(dateStr) (\(age))")
                } else {
                    chipView(icon: "birthday.cake", text: dateStr)
                }
            }
            if let place = vm.birthPlace {
                chipView(icon: "mappin", text: place)
            }
            if let death = vm.deathDate {
                let dateStr = Self.displayDateFormatter.string(from: death)
                if let age = ageText {
                    chipView(icon: nil, text: "\u{2020} \(dateStr) (\(age))")
                } else {
                    chipView(icon: nil, text: "\u{2020} \(dateStr)")
                }
            }
        }
    }

    private func chipView(icon: String? = nil, text: String) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.secondarySystemFill), in: Capsule())
    }

    // MARK: - Main Content

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let bio = vm.biography, !bio.isEmpty {
                biographySection(bio)
            }
            if !vm.filmography.isEmpty {
                filmographySection
            } else if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Biography

    private func biographySection(_ bio: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Biography", bundle: AppState.currentBundle))
                .font(.headline)

            Text(bio)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .lineLimit(bioExpanded ? nil : 4)

            if bio.count > 200 {
                Text(bioExpanded
                     ? String(localized: "Show Less", bundle: AppState.currentBundle)
                     : String(localized: "Show More", bundle: AppState.currentBundle))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.25)) { bioExpanded.toggle() }
        }
    }

    // MARK: - Filmography

    private var filmographySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Known For", bundle: AppState.currentBundle))
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(vm.filmography) { item in
                        Button {
                            dismiss()
                            // Post after dismiss animation so parent can navigate
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                NotificationCenter.default.post(
                                    name: .personFilmographySelected,
                                    object: item
                                )
                            }
                        } label: {
                            PosterCardView(item: item, serverURL: appState.serverURL)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private static let displayDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
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
}

// MARK: - Flow Layout (wrapping horizontal chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }

    private struct ArrangeResult {
        var size: CGSize
        var frames: [CGRect]
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> ArrangeResult {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let totalWidth = frames.reduce(0) { max($0, $1.maxX) }
        let totalHeight = frames.reduce(0) { max($0, $1.maxY) }
        return ArrangeResult(size: CGSize(width: totalWidth, height: totalHeight), frames: frames)
    }
}
