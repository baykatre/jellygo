import SwiftUI

struct ServerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var serverURL = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var navigateToLogin = false
    @State private var serverInfo: JellyfinServerInfo?

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

                            Text("Connect to your Jellyfin server")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 36)

                        VStack(spacing: 20) {
                            // Saved servers quick-select
                            if !uniqueServers.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Saved Servers")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    VStack(spacing: 8) {
                                        ForEach(uniqueServers, id: \.url) { server in
                                            Button {
                                                serverURL = server.url
                                                Task { await connect() }
                                            } label: {
                                                HStack(spacing: 12) {
                                                    Image(systemName: "server.rack")
                                                        .foregroundStyle(.tint)
                                                        .frame(width: 28)

                                                    VStack(alignment: .leading, spacing: 2) {
                                                        Text(server.name)
                                                            .font(.subheadline.weight(.medium))
                                                            .foregroundStyle(.primary)
                                                        Text(server.url)
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
                                            .buttonStyle(.plain)
                                            .disabled(isLoading)
                                        }
                                    }
                                }
                            }

                            // Manual form
                            VStack(alignment: .leading, spacing: 10) {
                                Text(uniqueServers.isEmpty ? "Server Address" : "Add New Server")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 12) {
                                    TextField("http://192.168.1.1:8096", text: $serverURL)
                                        .textFieldStyle(.plain)
                                        .keyboardType(.URL)
                                        .autocorrectionDisabled()
                                        .textInputAutocapitalization(.never)
                                        .padding(14)
                                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .strokeBorder(errorMessage != nil ? Color.red.opacity(0.6) : Color.clear, lineWidth: 1)
                                        )

                                    if let error = errorMessage {
                                        Label(error, systemImage: "exclamationmark.circle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 4)
                                    }

                                    Button {
                                        Task { await connect() }
                                    } label: {
                                        Group {
                                            if isLoading {
                                                ProgressView().tint(.white)
                                            } else {
                                                Text("Connect")
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
                        .padding(.horizontal, 24)
                        .padding(.bottom, 48)
                    }
                }
            }
            .navigationDestination(isPresented: $navigateToLogin) {
                if let info = serverInfo {
                    LoginView(serverURL: normalizedURL, serverInfo: info)
                }
            }
        }
    }

    /// All saved server URLs, deduplicated by URL
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
