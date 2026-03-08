import SwiftUI

struct ServerView: View {
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

                VStack(spacing: 0) {
                    Spacer()

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
                    .padding(.bottom, 48)

                    // Form
                    VStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server Address")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)

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
                        }

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
                                    ProgressView()
                                        .tint(.white)
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
                    .padding(.horizontal, 24)

                    Spacer()
                    Spacer()
                }
            }
            .navigationDestination(isPresented: $navigateToLogin) {
                if let info = serverInfo {
                    LoginView(serverURL: normalizedURL, serverInfo: info)
                }
            }
        }
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

#Preview {
    ServerView()
}
