import SwiftUI

struct LoginView: View {
    let serverURL: String
    let serverInfo: JellyfinServerInfo

    @EnvironmentObject private var appState: AppState

    @State private var username = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    enum Field { case username, password }

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Server badge
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

                    Text("Giriş yapın")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 40)

                // Form
                VStack(spacing: 12) {
                    VStack(spacing: 8) {
                        TextField("Kullanıcı adı", text: $username)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .padding(14)
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .onSubmit { focusedField = .password }

                        SecureField("Şifre", text: $password)
                            .textFieldStyle(.plain)
                            .submitLabel(.go)
                            .focused($focusedField, equals: .password)
                            .padding(14)
                            .background(.background, in: RoundedRectangle(cornerRadius: 12))
                            .onSubmit {
                                guard !username.isEmpty && !password.isEmpty else { return }
                                Task { await login() }
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
                        Task { await login() }
                    } label: {
                        Group {
                            if isLoading {
                                ProgressView().tint(.white)
                            } else {
                                Text("Giriş Yap")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(username.isEmpty || isLoading)
                }
                .padding(.horizontal, 24)

                Spacer()
                Spacer()
            }
        }
        .navigationTitle("Giriş")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { focusedField = .username }
    }

    private func login() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await JellyfinAPI.shared.login(
                serverURL: serverURL,
                username: username,
                password: password
            )
            appState.login(
                serverURL: serverURL,
                serverName: serverInfo.serverName,
                userId: response.user.id,
                username: response.user.name,
                token: response.accessToken
            )
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
