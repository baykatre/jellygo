import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var serverURL: String = ""
    @Published var serverName: String = ""
    @Published var userId: String = ""
    @Published var username: String = ""
    @Published var token: String = ""

    init() {
        restore()
    }

    private func restore() {
        guard
            let token = KeychainService.shared.getToken(),
            let url = UserDefaults.standard.string(forKey: "jellygo.serverURL"),
            let userId = UserDefaults.standard.string(forKey: "jellygo.userId")
        else { return }

        self.token = token
        self.serverURL = url
        self.userId = userId
        self.serverName = UserDefaults.standard.string(forKey: "jellygo.serverName") ?? ""
        self.username = UserDefaults.standard.string(forKey: "jellygo.username") ?? ""
        self.isAuthenticated = true
    }

    func login(serverURL: String, serverName: String, userId: String, username: String, token: String) {
        self.serverURL = serverURL
        self.serverName = serverName
        self.userId = userId
        self.username = username
        self.token = token

        KeychainService.shared.saveToken(token)
        UserDefaults.standard.set(serverURL, forKey: "jellygo.serverURL")
        UserDefaults.standard.set(serverName, forKey: "jellygo.serverName")
        UserDefaults.standard.set(userId, forKey: "jellygo.userId")
        UserDefaults.standard.set(username, forKey: "jellygo.username")

        withAnimation { isAuthenticated = true }
    }

    func logout() {
        KeychainService.shared.deleteToken()
        UserDefaults.standard.removeObject(forKey: "jellygo.serverURL")
        UserDefaults.standard.removeObject(forKey: "jellygo.serverName")
        UserDefaults.standard.removeObject(forKey: "jellygo.userId")
        UserDefaults.standard.removeObject(forKey: "jellygo.username")

        token = ""
        serverURL = ""
        serverName = ""
        userId = ""
        username = ""

        withAnimation { isAuthenticated = false }
    }
}
