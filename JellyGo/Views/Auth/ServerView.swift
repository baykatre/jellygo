import SwiftUI
import Network
import Combine

// MARK: - Network Scanner

@MainActor
final class JellyfinNetworkScanner: ObservableObject {
    @Published var results: [DiscoveredServer] = []
    @Published var isScanning = false

    struct DiscoveredServer: Identifiable {
        let id = UUID()
        let name: String
        let url: String
    }

    private var browser: NWBrowser?
    private var stopTask: Task<Void, Never>?

    func scan() {
        results = []
        isScanning = true

        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: "_jellyfin._tcp.", domain: "local."), using: params)
        browser = b

        b.browseResultsChangedHandler = { [weak self] newResults, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for result in newResults {
                    guard case let .service(name, _, _, _) = result.endpoint else { continue }
                    self.resolveEndpoint(result.endpoint, name: name)
                }
            }
        }

        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                if case .failed = state { self?.isScanning = false }
            }
        }

        b.start(queue: .main)

        stopTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    nonisolated private func resolveEndpoint(_ endpoint: NWEndpoint, name: String) {
        guard case .service = endpoint else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                var url: String?
                if let remote = connection.currentPath?.remoteEndpoint,
                   case let .hostPort(host, port) = remote {
                    let hostStr: String
                    switch host {
                    case .name(let n, _): hostStr = n
                    case .ipv4(let addr): hostStr = "\(addr)"
                    case .ipv6(let addr): hostStr = "[\(addr)]"
                    @unknown default: hostStr = ""
                    }
                    url = "http://\(hostStr):\(port)"
                }
                connection.cancel()
                if let url {
                    let server = DiscoveredServer(name: name, url: url)
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if !self.results.contains(where: { $0.url == url }) {
                            self.results.append(server)
                        }
                    }
                }
            } else if case .failed = state {
                connection.cancel()
            }
        }
        connection.start(queue: .main)
    }

    func stopScan() {
        stopTask?.cancel()
        browser?.cancel()
        browser = nil
        isScanning = false
    }
}

// MARK: - ServerView

struct ServerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var serverURL = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigateToLogin = false
    @State private var serverInfo: JellyfinServerInfo?
    @FocusState private var isURLFocused: Bool
    @StateObject private var scanner = JellyfinNetworkScanner()

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 0) {
                        // Logo
                        VStack(spacing: 16) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 72))
                                .foregroundStyle(.tint)
                                .symbolEffect(.pulse, isActive: isLoading)

                            Text("JellyGo")
                                .font(.largeTitle.bold())

                            Text(String(localized: "Connect to your Jellyfin server", bundle: AppState.currentBundle))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 36)

                        VStack(spacing: 20) {
                            // Saved servers quick-select
                            if !uniqueServers.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(String(localized: "Saved Servers", bundle: AppState.currentBundle))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 8) {
                                        ForEach(uniqueServers, id: \.url) { server in
                                            Button {
                                                serverURL = server.url
                                                Task { await connect() }
                                            } label: {
                                                serverRow(name: server.name, url: server.url, icon: "server.rack")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(isLoading)
                                        }
                                    }
                                }
                            }

                            // Discovered servers
                            if !scanner.results.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(String(localized: "Found on Network", bundle: AppState.currentBundle))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 8) {
                                        ForEach(scanner.results) { server in
                                            Button {
                                                serverURL = server.url
                                                scanner.stopScan()
                                                Task { await connect() }
                                            } label: {
                                                serverRow(name: server.name, url: server.url, icon: "wifi")
                                            }
                                            .buttonStyle(.plain)
                                            .disabled(isLoading)
                                        }
                                    }
                                }
                            }

                            // Manual form
                            VStack(alignment: .leading, spacing: 10) {
                                Text(uniqueServers.isEmpty ? String(localized: "Server Address", bundle: AppState.currentBundle) : String(localized: "Add New Server", bundle: AppState.currentBundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 12) {
                                    TextField("http://192.168.1.1:8096", text: $serverURL)
                                        .textFieldStyle(.plain)
                                        .keyboardType(.URL)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                        .focused($isURLFocused)
                                        .padding(14)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(errorMessage != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                                        )
                                        .contentShape(RoundedRectangle(cornerRadius: 12))
                                        .onTapGesture { isURLFocused = true }

                                    if let error = errorMessage {
                                        Label(error, systemImage: "exclamationmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 4)
                                    }

                                    HStack(spacing: 10) {
                                        // Scan button
                                        Button {
                                            isURLFocused = false
                                            if scanner.isScanning {
                                                scanner.stopScan()
                                            } else {
                                                scanner.scan()
                                            }
                                        } label: {
                                            Group {
                                                if scanner.isScanning {
                                                    HStack(spacing: 6) {
                                                        ProgressView().tint(.primary)
                                                        Text(String(localized: "Scanning\u{2026}", bundle: AppState.currentBundle))
                                                    }
                                                } else {
                                                    Label(String(localized: "Scan", bundle: AppState.currentBundle), systemImage: "wifi.circle")
                                                }
                                            }
                                            .frame(height: 50)
                                            .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.large)
                                        .disabled(isLoading)

                                        // Connect button
                                        Button {
                                            isURLFocused = false
                                            Task { await connect() }
                                        } label: {
                                            Group {
                                                if isLoading {
                                                    ProgressView().tint(.white)
                                                } else {
                                                    Text(String(localized: "Connect", bundle: AppState.currentBundle))
                                                        .fontWeight(.semibold)
                                                }
                                            }
                                            .frame(maxWidth: .infinity)
                                            .frame(height: 50)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.large)
                                        .disabled(serverURL.isEmpty || isLoading)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationDestination(isPresented: $navigateToLogin) {
                if let info = serverInfo {
                    LoginView(serverURL: normalizedURL, serverInfo: info)
                }
            }
        }
    }

    private func serverRow(name: String, url: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
    }

    private var uniqueServers: [(url: String, name: String)] {
        var seen = Set<String>()
        var result: [(url: String, name: String)] = []
        for account in appState.savedAccounts {
            if !seen.contains(account.serverURL) {
                seen.insert(account.serverURL)
                result.append((url: account.serverURL, name: account.serverName))
            }
        }
        return result
    }

    private var normalizedURL: String {
        var url = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
            url = "http://" + url
        }
        return url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    private func connect() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await JellyfinAPI.shared.checkServer(url: normalizedURL)
            serverInfo = info
            navigateToLogin = true
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
