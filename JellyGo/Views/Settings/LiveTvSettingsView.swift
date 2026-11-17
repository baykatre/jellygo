import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared bits

private func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppState.currentBundle)
}

private let brandRed = JGColor.brand
private let toggleTint = JGColor.brand

private func intervalLabel(_ hours: Int) -> String {
    hours == 0 ? loc("Manual") : String(format: loc("Every %d hours"), hours)
}

private func offsetLabel(_ minutes: Int) -> String {
    let sign = minutes < 0 ? "−" : "+"
    let m = abs(minutes)
    return String(format: "%@%d:%02d", sign, m / 60, m % 60)
}

private func dateLabel(_ date: Date?, locale: Locale) -> String {
    guard let date else { return loc("Never") }
    let f = RelativeDateTimeFormatter()
    f.locale = locale
    f.unitsStyle = .short
    return f.localizedString(for: date, relativeTo: Date())
}

// MARK: - Live TV Settings

/// Settings ▸ Live TV: the Pro-locked Live TV switch, device-side M3U/XMLTV sources,
/// server-side tuners / guide providers (administrators), channel visibility and data.
struct LiveTvSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = ExternalLiveTvStore.shared

    private enum SheetTarget: Identifiable {
        case newPlaylist, editPlaylist(UUID), newGuide, editGuide(UUID)
        var id: String {
            switch self {
            case .newPlaylist: return "np"
            case .editPlaylist(let id): return "ep-\(id)"
            case .newGuide: return "ng"
            case .editGuide(let id): return "eg-\(id)"
            }
        }
    }

    private enum ServerState {
        case loading
        case notAdministrator
        case failed(String)
        case ready(JellyfinLiveTvServerConfig)
    }

    @State private var sheet: SheetTarget?
    @State private var playlistToDelete: ExternalPlaylistSource?
    @State private var guideToDelete: ExternalGuideSource?
    @State private var showClearGuideAlert = false

    @State private var serverState: ServerState = .loading
    @State private var serverBusy = false
    @State private var serverMessage: String?
    @State private var serverMessageIsError = false
    @State private var tunerToRemove: JellyfinTunerHost?
    @State private var providerToRemove: JellyfinListingProvider?

    private var featureActive: Bool { appState.experimentalLiveTv && appState.isPro }

    var body: some View {
        List {
            Group {
                mainSection
                if featureActive {
                    sourcesSection
                    guideSection
                    serverSection
                    channelsSection
                    dataSection
                }
            }
            .listRowBackground(SettingsRowBackground())
        }
        .tint(toggleTint)
        .ambientList()
        .navigationTitle(loc("Live TV Settings"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: featureActive) {
            guard featureActive else { return }
            await store.loadCacheIfNeeded()
            await loadServer()
        }
        .sheet(item: $sheet) { target in
            sheetContent(target)
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                // Plain black: neither the system's grey sheet material nor a gradient.
                .presentationBackground(JGColor.sheet)
        }
        .alert(loc("Delete Playlist?"), isPresented: Binding(
            get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } })) {
            Button(loc("Delete"), role: .destructive) {
                if let p = playlistToDelete { store.deletePlaylist(p.id) }
                playlistToDelete = nil
            }
            Button(loc("Cancel"), role: .cancel) { playlistToDelete = nil }
        } message: {
            Text(playlistToDelete?.name ?? "")
        }
        .alert(loc("Delete Guide?"), isPresented: Binding(
            get: { guideToDelete != nil }, set: { if !$0 { guideToDelete = nil } })) {
            Button(loc("Delete"), role: .destructive) {
                if let g = guideToDelete { store.deleteGuide(g.id) }
                guideToDelete = nil
            }
            Button(loc("Cancel"), role: .cancel) { guideToDelete = nil }
        } message: {
            Text(guideToDelete?.name ?? "")
        }
        .alert(loc("Clear Guide Cache?"), isPresented: $showClearGuideAlert) {
            Button(loc("Clear"), role: .destructive) { store.clearGuideCache() }
            Button(loc("Cancel"), role: .cancel) {}
        } message: {
            Text(loc("Programme data is removed from this device and downloaded again on the next refresh."))
        }
        .alert(loc("Remove from Server?"), isPresented: Binding(
            get: { tunerToRemove != nil || providerToRemove != nil },
            set: { if !$0 { tunerToRemove = nil; providerToRemove = nil } })) {
            Button(loc("Remove"), role: .destructive) {
                let tuner = tunerToRemove, provider = providerToRemove
                tunerToRemove = nil; providerToRemove = nil
                Task { await removeFromServer(tuner: tuner, provider: provider) }
            }
            Button(loc("Cancel"), role: .cancel) { tunerToRemove = nil; providerToRemove = nil }
        } message: {
            Text(loc("This changes the Live TV setup of the Jellyfin server for every user."))
        }
    }

    // MARK: Sections

    private var mainSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { appState.experimentalLiveTv },
                set: { newValue in
                    if newValue && !appState.isPro {
                        appState.showPaywall = true
                    } else {
                        appState.experimentalLiveTv = newValue
                    }
                }
            )) {
                Label(loc("Live TV"), systemImage: "tv.fill")
            }
            if featureActive {
                Toggle(isOn: $store.showJellyfinChannels) {
                    Label(loc("Show Jellyfin Channels"), systemImage: "server.rack")
                }
                Toggle(isOn: $store.showExternalChannels) {
                    Label(loc("Show External Playlists"), systemImage: "list.bullet.rectangle")
                }
            }
        } footer: {
            if !appState.isPro {
                Text(loc("Live TV and external playlists are part of JellyGo Pro."))
            }
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach(store.playlists) { p in
                sourceRow(title: p.name,
                          detail: playlistDetail(p),
                          error: p.lastError,
                          isOn: Binding(get: { p.isEnabled }, set: { store.setPlaylistEnabled(p.id, $0) }))
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .editPlaylist(p.id) }
                    .swipeActions {
                        Button(role: .destructive) { playlistToDelete = p } label: {
                            Label(loc("Delete"), systemImage: "trash")
                        }
                    }
            }
            Button { sheet = .newPlaylist } label: {
                Label(loc("Add Playlist"), systemImage: "plus")
            }
        } header: {
            Text(loc("Sources"))
        } footer: {
            Text(loc("M3U lists played directly on this device. Addresses are stored in the Keychain. Movies and series in a list are skipped."))
        }
    }

    private func playlistDetail(_ p: ExternalPlaylistSource) -> String {
        var parts: [String] = []
        if p.channelCount > 0 { parts.append(String(format: loc("%d channels"), p.channelCount)) }
        if p.origin == .file { parts.append(p.fileName ?? loc("File")) } else {
            let masked = store.maskedPlaylistAddress(p.id)
            parts.append(URLComponents(string: masked)?.host ?? masked)
        }
        return parts.joined(separator: " · ")
    }

    private func sourceRow(title: String, detail: String, error: String?, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(JGColor.danger)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private var guideSection: some View {
        Section {
            ForEach(store.guides) { g in
                let masked = store.maskedGuideAddress(g.id)
                let host = URLComponents(string: masked)?.host ?? masked
                let detail = g.programCount > 0 ? String(format: loc("%d programmes"), g.programCount) + " · " + host : host
                sourceRow(title: g.name, detail: detail, error: g.lastError,
                          isOn: Binding(get: { g.isEnabled }, set: { store.setGuideEnabled(g.id, $0) }))
                    .contentShape(Rectangle())
                    .onTapGesture { sheet = .editGuide(g.id) }
                    .swipeActions {
                        Button(role: .destructive) { guideToDelete = g } label: {
                            Label(loc("Delete"), systemImage: "trash")
                        }
                    }
            }
            Button { sheet = .newGuide } label: {
                Label(loc("Add Guide"), systemImage: "plus")
            }

            Picker(loc("Playlist Refresh"), selection: $store.playlistRefreshHours) {
                ForEach(ExternalLiveTvStore.refreshIntervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
            }
            Picker(loc("Guide Refresh"), selection: $store.guideRefreshHours) {
                ForEach(ExternalLiveTvStore.refreshIntervals, id: \.self) { Text(intervalLabel($0)).tag($0) }
            }
            Stepper(value: $store.guideOffsetMinutes, in: -720...720, step: 30) {
                HStack {
                    Text(loc("Time Offset"))
                    Spacer()
                    Text(offsetLabel(store.guideOffsetMinutes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(loc("Guide"))
        } footer: {
            Text(loc("XMLTV guides (.xml or .xml.gz). Only programmes of your channels from 2 hours ago to 36 hours ahead are kept. Use the time offset if programme times are shifted."))
        }
    }

    // MARK: Server (administrators)

    @ViewBuilder
    private var serverSection: some View {
        Section {
            switch serverState {
            case .loading:
                HStack {
                    Text(loc("Checking server permissions…")).foregroundStyle(.secondary)
                    Spacer()
                    ProgressView()
                }
            case .notAdministrator:
                Label(loc("Administrator required"), systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).font(.caption).foregroundStyle(JGColor.danger)
                    Button(loc("Retry")) { Task { await loadServer() } }
                }
            case .ready(let config):
                serverRows(config)
            }
            if let serverMessage {
                Text(serverMessage)
                    .font(.caption)
                    .foregroundStyle(serverMessageIsError ? JGColor.danger : Color.secondary)
            }
        } header: {
            Text(loc("Server"))
        } footer: {
            switch serverState {
            case .notAdministrator:
                Text(loc("Only a Jellyfin administrator can add tuners and guide providers to the server. You are signed in as a regular user."))
            default:
                Text(loc("Adds the same addresses to Jellyfin as an M3U tuner and an XMLTV guide provider. The server then downloads and streams them for every user."))
            }
        }
    }

    @ViewBuilder
    private func serverRows(_ config: JellyfinLiveTvServerConfig) -> some View {
        if config.tunerHosts.isEmpty && config.listingProviders.isEmpty {
            Text(loc("No tuners or guide providers on the server."))
                .foregroundStyle(.secondary)
        }
        ForEach(config.tunerHosts) { tuner in
            serverItemRow(icon: "antenna.radiowaves.left.and.right",
                          title: tuner.friendlyName?.isEmpty == false ? tuner.friendlyName! : tuner.type.uppercased(),
                          detail: tuner.type.uppercased() + " · " + LiveTvURLMasker.mask(tuner.url)) {
                tunerToRemove = tuner
            }
        }
        ForEach(config.listingProviders) { provider in
            serverItemRow(icon: "calendar",
                          title: provider.type.lowercased() == "xmltv" ? "XMLTV" : provider.type,
                          detail: provider.path.map(LiveTvURLMasker.mask) ?? (provider.listingsId ?? "")) {
                providerToRemove = provider
            }
        }

        let remoteLists = store.playlists.filter { $0.origin == .remote }
        Menu {
            ForEach(remoteLists) { p in
                Button(p.name) { Task { await addPlaylistToServer(p) } }
            }
        } label: {
            Label(loc("Add Playlist to Server"), systemImage: "plus.rectangle.on.rectangle")
        }
        .disabled(remoteLists.isEmpty || serverBusy)

        Menu {
            ForEach(store.guides) { g in
                Button(g.name) { Task { await addGuideToServer(g) } }
            }
        } label: {
            Label(loc("Add Guide to Server"), systemImage: "calendar.badge.plus")
        }
        .disabled(store.guides.isEmpty || serverBusy)
    }

    private func serverItemRow(icon: String, title: String, detail: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(JGColor.danger)
            }
            .buttonStyle(.plain)
            .disabled(serverBusy)
        }
    }

    private func loadServer() async {
        serverState = .loading
        do {
            let isAdmin = try await JellyfinAPI.shared.currentUserIsAdministrator(
                serverURL: appState.serverURL, token: appState.token)
            guard isAdmin else { serverState = .notAdministrator; return }
            let config = try await JellyfinAPI.shared.getLiveTvServerConfig(
                serverURL: appState.serverURL, token: appState.token)
            serverState = .ready(config)
        } catch JellyfinLiveTvAdminError.notAdministrator {
            serverState = .notAdministrator
        } catch {
            serverState = .failed(error.localizedDescription)
        }
    }

    private func runServerChange(success: String, _ work: () async throws -> Void) async {
        serverBusy = true
        defer { serverBusy = false }
        do {
            try await work()
            serverMessage = success
            serverMessageIsError = false
            await loadServer()
        } catch {
            serverMessage = error.localizedDescription
            serverMessageIsError = true
            if case JellyfinLiveTvAdminError.notAdministrator = error { serverState = .notAdministrator }
        }
    }

    private func addPlaylistToServer(_ p: ExternalPlaylistSource) async {
        guard let address = store.playlistAddress(p.id) else { return }
        await runServerChange(success: loc("Added to the server. Jellyfin is refreshing its guide.")) {
            try await JellyfinAPI.shared.addM3UTunerHost(
                serverURL: appState.serverURL, token: appState.token,
                address: address, name: p.name, userAgent: p.userAgent)
            NotificationCenter.default.post(name: .liveTvServerSourcesChanged, object: nil)
        }
    }

    private func addGuideToServer(_ g: ExternalGuideSource) async {
        guard let address = store.guideAddress(g.id) else { return }
        await runServerChange(success: loc("Added to the server. Jellyfin is refreshing its guide.")) {
            try await JellyfinAPI.shared.addXmlTvListingProvider(
                serverURL: appState.serverURL, token: appState.token, address: address)
            NotificationCenter.default.post(name: .liveTvServerSourcesChanged, object: nil)
        }
    }

    private func removeFromServer(tuner: JellyfinTunerHost?, provider: JellyfinListingProvider?) async {
        await runServerChange(success: loc("Removed from the server.")) {
            if let tuner {
                try await JellyfinAPI.shared.deleteTunerHost(serverURL: appState.serverURL, token: appState.token, id: tuner.id)
            }
            if let provider {
                try await JellyfinAPI.shared.deleteListingProvider(serverURL: appState.serverURL, token: appState.token, id: provider.id)
            }
            NotificationCenter.default.post(name: .liveTvServerSourcesChanged, object: nil)
        }
    }

    // MARK: Channels / data

    private var channelsSection: some View {
        Section {
            NavigationLink {
                LiveTvChannelVisibilityView()
            } label: {
                HStack {
                    Text(loc("Groups & Channels"))
                    Spacer()
                    let hidden = store.hiddenGroups.count + store.hiddenChannelIds.count
                    if hidden > 0 {
                        Text(String(format: loc("%d hidden"), hidden))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(store.channels.isEmpty)
        } header: {
            Text(loc("Channels"))
        }
    }

    private var lastPlaylistRefresh: Date? {
        store.playlists.filter(\.isEnabled).compactMap(\.lastRefresh).max()
    }

    private var dataSection: some View {
        Section {
            LabeledContent(loc("Playlists Updated"), value: dateLabel(lastPlaylistRefresh, locale: appState.currentLocale))
            LabeledContent(loc("Guide Updated"), value: dateLabel(store.lastGuideRefresh, locale: appState.currentLocale))
            if store.guideProgrammeCount > 0 {
                LabeledContent(loc("Guide"), value: String(format: loc("%d programmes · %d channels matched"),
                                                           store.guideProgrammeCount, store.matchedChannelCount))
            }
            if let err = store.lastGuideError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(JGColor.danger)
                    .lineLimit(3)
            }
            Button {
                Task { await store.refreshAll() }
            } label: {
                HStack {
                    Label(loc("Refresh Now"), systemImage: "arrow.clockwise")
                    Spacer()
                    if store.isRefreshingPlaylists || store.isRefreshingGuide { ProgressView() }
                }
            }
            .disabled(store.isRefreshingPlaylists || store.isRefreshingGuide || (store.playlists.isEmpty && store.guides.isEmpty))
            Button(role: .destructive) { showClearGuideAlert = true } label: {
                Label(loc("Clear Guide Cache"), systemImage: "xmark.bin")
                    .foregroundStyle(JGColor.danger)
            }
        } header: {
            Text(loc("Data"))
        }
    }

    @ViewBuilder
    private func sheetContent(_ target: SheetTarget) -> some View {
        switch target {
        case .newPlaylist:
            LiveTvPlaylistEditSheet(editingId: nil).presentationDetents([.height(560), .large])
        case .editPlaylist(let id):
            LiveTvPlaylistEditSheet(editingId: id).presentationDetents([.height(520), .large])
        case .newGuide:
            LiveTvGuideEditSheet(editingId: nil).presentationDetents([.height(400)])
        case .editGuide(let id):
            LiveTvGuideEditSheet(editingId: id).presentationDetents([.height(400)])
        }
    }
}

// MARK: - Sheet building blocks (QuickConnect sheet style)

private struct SheetHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(LinearGradient(
                    colors: [JGColor.brand, JGColor.brandDeep],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(spacing: 6) {
                Text(title).font(.title3.bold())
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// Text field whose placeholder stays small, drawn the same way as the Quick Connect sheet.
private struct SheetField: View {
    let placeholder: String
    @Binding var text: String
    var isURL = false

    var body: some View {
        TextField("", text: $text)
            .font(.body)
            .keyboardType(isURL ? .URL : .default)
            .textInputAutocapitalization(isURL ? .never : .words)
            .autocorrectionDisabled(isURL)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct PrimarySheetButton: View {
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(brandRed, in: Capsule())
                .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

private func isWebAddress(_ s: String) -> Bool {
    guard let c = URLComponents(string: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let scheme = c.scheme?.lowercased(), c.host?.isEmpty == false else { return false }
    return scheme == "http" || scheme == "https"
}

// MARK: - Playlist sheet

struct LiveTvPlaylistEditSheet: View {
    let editingId: UUID?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ExternalLiveTvStore.shared

    @State private var name = ""
    @State private var address = ""
    @State private var userAgent = ""
    @State private var useEmbeddedGuide = true
    @State private var importedFile: URL?
    @State private var showImporter = false
    @State private var error: String?
    @State private var loaded = false

    private var editing: ExternalPlaylistSource? {
        editingId.flatMap { id in store.playlists.first { $0.id == id } }
    }
    private var isFileSource: Bool { editing?.origin == .file || importedFile != nil }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if isFileSource { return true }
        if editing != nil { return address.isEmpty || isWebAddress(address) }
        return isWebAddress(address)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SheetHeader(icon: "list.bullet.rectangle",
                            title: editing == nil ? loc("Add Playlist") : loc("Edit Playlist"),
                            subtitle: loc("An M3U or M3U8 list of live channels."))
                    .padding(.bottom, 4)

                SheetField(placeholder: loc("Name"), text: $name)

                if let file = importedFile {
                    fileChip(file.lastPathComponent)
                } else if editing?.origin == .file {
                    fileChip(editing?.fileName ?? loc("File"))
                } else {
                    SheetField(placeholder: editing == nil ? loc("Playlist address (http…)") : loc("New address (leave empty to keep)"),
                               text: $address, isURL: true)
                    if let editing {
                        Text(store.maskedPlaylistAddress(editing.id))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }
                }

                if editing == nil && importedFile == nil {
                    Button { showImporter = true } label: {
                        Label(loc("Import from Files"), systemImage: "folder")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }

                SheetField(placeholder: loc("User-Agent (optional)"), text: $userAgent, isURL: true)

                Toggle(isOn: $useEmbeddedGuide) {
                    Text(loc("Use the guide listed in the playlist"))
                        .font(.subheadline)
                }
                .tint(toggleTint)
                .padding(.horizontal, 4)

                if let error {
                    Text(error).font(.caption).foregroundStyle(JGColor.danger)
                }

                PrimarySheetButton(title: loc("Save"), enabled: canSave) { save() }
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .scrollBounceBehavior(.basedOnSize)
        .onAppear(perform: loadExisting)
        .onChange(of: address) { _, _ in error = nil }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "m3u") ?? .plainText,
                                            UTType(filenameExtension: "m3u8") ?? .plainText,
                                            .plainText, .data]) { result in
            switch result {
            case .success(let url):
                importedFile = url
                if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            case .failure(let err):
                error = err.localizedDescription
            }
        }
    }

    private func fileChip(_ fileName: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary)
            Text(fileName).font(.subheadline).lineLimit(1)
            Spacer()
            if importedFile != nil {
                Button { importedFile = nil } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadExisting() {
        guard !loaded else { return }
        loaded = true
        if let editing {
            name = editing.name
            userAgent = editing.userAgent ?? ""
            useEmbeddedGuide = editing.useEmbeddedGuide
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: UUID
        if let editing {
            store.editPlaylist(editing.id, name: trimmedName,
                               address: trimmedAddress.isEmpty ? nil : trimmedAddress,
                               userAgent: userAgent, useEmbeddedGuide: useEmbeddedGuide)
            id = editing.id
        } else if let file = importedFile {
            do {
                id = try store.importPlaylist(name: trimmedName, from: file, userAgent: userAgent, useEmbeddedGuide: useEmbeddedGuide)
            } catch {
                self.error = error.localizedDescription
                return
            }
        } else {
            id = store.addPlaylist(name: trimmedName, address: trimmedAddress, userAgent: userAgent, useEmbeddedGuide: useEmbeddedGuide)
        }
        dismiss()
        Task {
            await store.refreshPlaylist(id)
            await store.refreshGuide()
        }
    }
}

// MARK: - Guide sheet

struct LiveTvGuideEditSheet: View {
    let editingId: UUID?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = ExternalLiveTvStore.shared

    @State private var name = ""
    @State private var address = ""
    @State private var loaded = false

    private var editing: ExternalGuideSource? {
        editingId.flatMap { id in store.guides.first { $0.id == id } }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if editing != nil { return address.isEmpty || isWebAddress(address) }
        return isWebAddress(address)
    }

    var body: some View {
        VStack(spacing: 14) {
            SheetHeader(icon: "calendar",
                        title: editing == nil ? loc("Add Guide") : loc("Edit Guide"),
                        subtitle: loc("An XMLTV guide address (.xml or .xml.gz)."))
                .padding(.bottom, 4)
            SheetField(placeholder: loc("Name"), text: $name)
            SheetField(placeholder: editing == nil ? loc("Guide address (http…)") : loc("New address (leave empty to keep)"),
                       text: $address, isURL: true)
            if let editing {
                Text(store.maskedGuideAddress(editing.id))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            PrimarySheetButton(title: loc("Save"), enabled: canSave) { save() }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing { name = editing.name }
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let editing {
            store.editGuide(editing.id, name: trimmedName, address: trimmedAddress.isEmpty ? nil : trimmedAddress)
        } else {
            store.addGuide(name: trimmedName, address: trimmedAddress)
        }
        dismiss()
        Task { await store.refreshGuide() }
    }
}

// MARK: - Groups & channels

struct LiveTvChannelVisibilityView: View {
    @ObservedObject private var store = ExternalLiveTvStore.shared

    var body: some View {
        List {
            Group {
                ForEach(store.playlists.filter(\.isEnabled)) { p in
                    Section(p.name) {
                        ForEach(store.groups(for: p.id), id: \.self) { group in
                            NavigationLink {
                                LiveTvGroupChannelsView(sourceId: p.id, group: group)
                            } label: {
                                HStack {
                                    Text(group.isEmpty ? loc("Ungrouped") : group)
                                        .foregroundStyle(store.isGroupHidden(p.id, group) ? .secondary : .primary)
                                    Spacer()
                                    if store.isGroupHidden(p.id, group) {
                                        Image(systemName: "eye.slash").foregroundStyle(.secondary)
                                    }
                                    Text("\(store.channels(for: p.id).filter { ($0.info.groupTitle ?? "") == group }.count)")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .listRowBackground(SettingsRowBackground())
        }
        .tint(toggleTint)
        .ambientList()
        .navigationTitle(loc("Groups & Channels"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LiveTvGroupChannelsView: View {
    let sourceId: UUID
    let group: String
    @ObservedObject private var store = ExternalLiveTvStore.shared

    private var channels: [ExternalChannel] {
        store.channels(for: sourceId).filter { ($0.info.groupTitle ?? "") == group }
    }

    var body: some View {
        List {
            Group {
                Section {
                    Toggle(loc("Show Group"), isOn: Binding(
                        get: { !store.isGroupHidden(sourceId, group) },
                        set: { store.setGroupHidden(sourceId, group, hidden: !$0) }))
                }
                Section(loc("Channels")) {
                    ForEach(channels) { ch in
                        Toggle(isOn: Binding(
                            get: { !store.isChannelHidden(ch.id) },
                            set: { store.setChannelHidden(ch.id, hidden: !$0) })) {
                            HStack(spacing: 6) {
                                if let n = ch.info.channelNumber {
                                    Text(n).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                Text(ch.info.name).lineLimit(1)
                            }
                        }
                    }
                }
                .disabled(store.isGroupHidden(sourceId, group))
            }
            .listRowBackground(SettingsRowBackground())
        }
        .tint(toggleTint)
        .ambientList()
        .navigationTitle(group.isEmpty ? loc("Ungrouped") : group)
        .navigationBarTitleDisplayMode(.inline)
    }
}
