import SwiftUI

struct LoginView: View {
    let serverURL: String
    let serverInfo: JellyfinServerInfo

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showDuplicateAlert = false
    @State private var showLoginForm = false   // revealed only when adding a new user
    @FocusState private var focusedField: Field?

    // QuickConnect
    @State private var quickConnectEnabled = false
    @State private var quickConnectCode: String?
    @State private var quickConnectSecret: String?
    @State private var quickConnectPolling = false
    @State private var quickConnectTask: Task<Void, Never>?

    enum Field { case username, password }

    // Existing accounts on this server, deduplicated by userId
    private var knownUsers: [SavedAccount] {
        var seen = Set<String>()
        var result: [SavedAccount] = []
        for account in appState.savedAccounts {
            let matchesServer = (account.serverId.map { !$0.isEmpty && $0 == serverInfo.id } ?? false)
                             || account.serverURL == serverURL
            guard matchesServer, !seen.contains(account.userId) else { continue }
            seen.insert(account.userId)
            result.append(account)
        }
        return result
    }

    private var isAddingMode: Bool { appState.isAddingAccount }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 40)

                    // Server header
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 44))
                            .foregroundStyle(.tint)

                        VStack(spacing: 4) {
                            Text(serverInfo.serverName)
                                .font(.title2.bold())
                            Text(serverURL)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        if !(isAddingMode && !knownUsers.isEmpty) {
                            Text(String(localized: "Sign in", bundle: AppState.currentBundle))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.bottom, 36)

                    VStack(spacing: 20) {
                        // Known users — instant add without password
                        if isAddingMode && !knownUsers.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(String(localized: "Add existing account", bundle: AppState.currentBundle))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                VStack(spacing: 8) {
                                    ForEach(knownUsers) { account in
                                        Button { addExisting(account) } label: {
                                            HStack(spacing: 12) {
                                                ZStack {
                                                    Circle()
                                                        .fill(Color.accentColor.opacity(0.15))
                                                        .frame(width: 40, height: 40)
                                                    Text(account.username.prefix(1).uppercased())
                                                        .font(.headline.bold())
                                                        .foregroundStyle(.tint)
                                                }

                                                Text(account.username)
                                                    .font(.subheadline.weight(.medium))
                                                    .foregroundStyle(.primary)

                                                Spacer()

                                                if isLoading {
                                                    ProgressView().scaleEffect(0.8)
                                                } else {
                                                    Image(systemName: "plus.circle.fill")
                                                        .foregroundStyle(.tint)
                                                        .font(.title3)
                                                }
                                            }
                                            .padding(14)
                                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(isLoading)
                                    }
                                }
                            }

                            // Divider before "different user" option
                            Button {
                                withAnimation { showLoginForm.toggle() }
                            } label: {
                                HStack {
                                    VStack { Divider() }
                                    Text(showLoginForm ? String(localized: "Hide", bundle: AppState.currentBundle) : String(localized: "Sign in as a different user", bundle: AppState.currentBundle))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize()
                                    VStack { Divider() }
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        // Login form (always shown when not adding, togglable when adding)
                        if !isAddingMode || knownUsers.isEmpty || showLoginForm {
                            loginForm
                        }

                        // QuickConnect
                        if quickConnectEnabled {
                            quickConnectSection
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 48)
                }
            }
        }
        .navigationTitle(String(localized: "Login", bundle: AppState.currentBundle))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isAddingMode || knownUsers.isEmpty { focusedField = .username }
            Task { await checkQuickConnect() }
        }
        .onDisappear {
            quickConnectTask?.cancel()
        }
        .alert(String(localized: "Account Already Added", bundle: AppState.currentBundle), isPresented: $showDuplicateAlert) {
            Button(String(localized: "OK", bundle: AppState.currentBundle)) { appState.closeAddAccountSheet = true }
        } message: {
            Text(String(localized: "\(username) on \(serverInfo.serverName) is already in your account list.", bundle: AppState.currentBundle))
        }
    }

    // MARK: - Login Form

    private var loginForm: some View {
        VStack(spacing: 12) {
            VStack(spacing: 8) {
                TextField(String(localized: "Username", bundle: AppState.currentBundle), text: $username)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit { focusedField = .password }

                SecureField(String(localized: "Password", bundle: AppState.currentBundle), text: $password)
                    .textFieldStyle(.plain)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .padding(14)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .onSubmit {
                        guard !username.isEmpty && !password.isEmpty else { return }
                        Task { await loginWithPassword() }
                    }
            }
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
                Task { await loginWithPassword() }
            } label: {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Text(String(localized: "Sign In", bundle: AppState.currentBundle)).fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(username.isEmpty || isLoading)
        }
    }

    // MARK: - QuickConnect Section

    private var quickConnectSection: some View {
        VStack(spacing: 12) {
            // Divider
            HStack {
                VStack { Divider() }
                Text(String(localized: "or", bundle: AppState.currentBundle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VStack { Divider() }
            }

            if let code = quickConnectCode {
                // Show the code
                VStack(spacing: 12) {
                    Label(String(localized: "Quick Connect", bundle: AppState.currentBundle), systemImage: "bolt.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(code)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .kerning(6)
                        .foregroundStyle(.tint)

                    Text(String(localized: "Enter this code in your Jellyfin dashboard to sign in.", bundle: AppState.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if quickConnectPolling {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text(String(localized: "Waiting for approval\u{2026}", bundle: AppState.currentBundle))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(.background, in: RoundedRectangle(cornerRadius: 12))
            } else {
                // Initiate button
                Button {
                    Task { await initiateQuickConnect() }
                } label: {
                    Label(String(localized: "Quick Connect", bundle: AppState.currentBundle), systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isLoading)
            }
        }
    }

    // MARK: - Actions

    /// Add a known user to this URL without re-authenticating — reuse the shared token.
    private func addExisting(_ account: SavedAccount) {
        let token = KeychainService.shared.getToken(forAccountId: account.tokenKey) ?? appState.token
        let isDuplicate = appState.addAccount(
            serverURL: serverURL,
            serverName: serverInfo.serverName,
            userId: account.userId,
            username: account.username,
            token: token,
            serverId: serverInfo.id
        )
        if isDuplicate { showDuplicateAlert = true }
    }

    // MARK: - QuickConnect Actions

    private func checkQuickConnect() async {
        quickConnectEnabled = (try? await JellyfinAPI.shared.quickConnectEnabled(serverURL: serverURL)) ?? false
    }

    private func initiateQuickConnect() async {
        errorMessage = nil
        do {
            let result = try await JellyfinAPI.shared.quickConnectInitiate(serverURL: serverURL)
            quickConnectCode = result.code
            quickConnectSecret = result.secret
            startPolling()
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startPolling() {
        quickConnectPolling = true
        quickConnectTask?.cancel()
        quickConnectTask = Task {
            guard let secret = quickConnectSecret else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }

                let authenticated = (try? await JellyfinAPI.shared.quickConnectCheck(serverURL: serverURL, secret: secret)) ?? false
                if authenticated {
                    await completeQuickConnect(secret: secret)
                    return
                }
            }
        }
    }

    private func completeQuickConnect(secret: String) async {
        quickConnectPolling = false
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await JellyfinAPI.shared.quickConnectAuthenticate(serverURL: serverURL, secret: secret)

            if appState.isAddingAccount {
                let isDuplicate = appState.addAccount(
                    serverURL: serverURL,
                    serverName: serverInfo.serverName,
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
                if isDuplicate { showDuplicateAlert = true }
            } else {
                appState.login(
                    serverURL: serverURL,
                    serverName: serverInfo.serverName,
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
            }
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }

        quickConnectCode = nil
        quickConnectSecret = nil
    }

    private func loginWithPassword() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await JellyfinAPI.shared.login(
                serverURL: serverURL,
                username: username,
                password: password
            )

            if appState.isAddingAccount {
                let isDuplicate = appState.addAccount(
                    serverURL: serverURL,
                    serverName: serverInfo.serverName,
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
                if isDuplicate { showDuplicateAlert = true }
            } else {
                appState.login(
                    serverURL: serverURL,
                    serverName: serverInfo.serverName,
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
            }
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
