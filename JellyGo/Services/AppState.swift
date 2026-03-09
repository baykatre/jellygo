import SwiftUI
import Combine
import Network

// MARK: - Saved Account

struct SavedAccount: Codable, Identifiable, Equatable {
    let userId: String
    let username: String
    let serverURL: String
    let serverName: String
    var serverId: String?                       // Jellyfin server UUID — nil for migrated accounts
    var alias: String?                          // user-defined label, e.g. "Home", "Remote"
    var id: String { "\(userId)@\(serverURL)" } // composite — same user, different URL = separate

    /// Keychain key shared across all URL variants of the same user+server pair.
    /// Falls back to URL-based key for accounts without serverId (migration compat).
    var tokenKey: String {
        if let sid = serverId, !sid.isEmpty { return "\(userId)@\(sid)" }
        return "\(userId)@\(serverURL)"
    }

    /// Shows alias if set, otherwise the host portion of the URL.
    var displayLabel: String {
        if let a = alias, !a.isEmpty { return a }
        return URL(string: serverURL)?.host ?? serverURL
    }
}

// MARK: - Enums

enum VideoQuality: String, CaseIterable, Identifiable {
    case direct = "Direct"
    case auto   = "Auto"
    case p4k    = "4K"
    case p1080  = "1080p"
    case p720   = "720p"
    case p480   = "480p"
    case p360   = "360p"

    var id: String { rawValue }

    /// nil = no limit (Jellyfin decides). Direct uses the raw stream URL.
    var maxBitrate: Int? {
        switch self {
        case .direct: return nil
        case .auto:   return nil
        case .p4k:    return 80_000_000
        case .p1080:  return 8_000_000
        case .p720:   return 4_000_000
        case .p480:   return 2_000_000
        case .p360:   return 1_000_000
        }
    }

    /// Direct play: skip PlaybackInfo entirely, stream the file as-is.
    var forceDirectPlay: Bool { self == .direct }

    /// Resolves .auto to the right quality based on current network type.
    /// WiFi → Direct, Cellular → 720p
    var resolved: VideoQuality {
        guard self == .auto else { return self }
        return NetworkMonitor.shared.isWiFi ? .direct : .p720
    }
}

// MARK: - Network Monitor

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "jellygo.network", qos: .utility)

    private(set) var isWiFi: Bool = true
    @Published var isConnected: Bool = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi)
            let connected = path.status == .satisfied
            DispatchQueue.main.async {
                self?.isWiFi = wifi
                self?.isConnected = connected
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // MARK: Session
    @Published var isAuthenticated = false
    @Published var sessionId: UUID = UUID()   // changes on every account switch → triggers reloads
    @Published var serverURL: String = ""
    @Published var serverName: String = ""
    @Published var serverId: String = ""
    @Published var userId: String = ""
    @Published var username: String = ""
    @Published var token: String = ""

    // MARK: Accounts
    @Published var savedAccounts: [SavedAccount] = []
    @Published var isAddingAccount: Bool = false
    @Published var closeAddAccountSheet: Bool = false  // set true to dismiss the sheet from anywhere

    // MARK: Playback
    @Published var defaultVideoQuality: VideoQuality = VideoQuality(
        rawValue: UserDefaults.standard.string(forKey: "jellygo.defaultQuality") ?? ""
    ) ?? .auto {
        didSet { UserDefaults.standard.set(defaultVideoQuality.rawValue, forKey: "jellygo.defaultQuality") }
    }

    // MARK: Audio
    @Published var preferredAudioLanguage: String =
        UserDefaults.standard.string(forKey: "jellygo.audioLang") ?? "" {
        didSet { UserDefaults.standard.set(preferredAudioLanguage, forKey: "jellygo.audioLang") }
    }

    // MARK: Subtitles
    @Published var preferredSubtitleLanguage: String =
        UserDefaults.standard.string(forKey: "jellygo.subtitleLang") ?? "" {
        didSet { UserDefaults.standard.set(preferredSubtitleLanguage, forKey: "jellygo.subtitleLang") }
    }
    @Published var subtitlesEnabledByDefault: Bool =
        UserDefaults.standard.bool(forKey: "jellygo.subtitleEnabled") {
        didSet { UserDefaults.standard.set(subtitlesEnabledByDefault, forKey: "jellygo.subtitleEnabled") }
    }
    /// VLC freetype-rel-fontsize: lower = bigger text. Default 20.
    @Published var subtitleFontSize: Int = {
        let v = UserDefaults.standard.integer(forKey: "jellygo.subtitleFontSize")
        return v == 0 ? 20 : v
    }() {
        didSet { UserDefaults.standard.set(subtitleFontSize, forKey: "jellygo.subtitleFontSize") }
    }
    @Published var subtitleBackgroundEnabled: Bool =
        UserDefaults.standard.bool(forKey: "jellygo.subtitleBg") {
        didSet { UserDefaults.standard.set(subtitleBackgroundEnabled, forKey: "jellygo.subtitleBg") }
    }
    @Published var subtitleBold: Bool =
        UserDefaults.standard.bool(forKey: "jellygo.subtitleBold") {
        didSet { UserDefaults.standard.set(subtitleBold, forKey: "jellygo.subtitleBold") }
    }
    /// "white" or "yellow"
    @Published var subtitleColor: String =
        UserDefaults.standard.string(forKey: "jellygo.subtitleColor") ?? "white" {
        didSet { UserDefaults.standard.set(subtitleColor, forKey: "jellygo.subtitleColor") }
    }

    // MARK: App Language
    @Published var appLanguage: String =
        UserDefaults.standard.string(forKey: "jellygo.appLanguage") ?? "" {
        didSet {
            UserDefaults.standard.set(appLanguage, forKey: "jellygo.appLanguage")
            AppState.updateLocalizationBundle(appLanguage)
        }
    }

    // MARK: - Localization (static, accessible from any thread)

    nonisolated(unsafe) static private(set) var currentBundle: Bundle = {
        let code = UserDefaults.standard.string(forKey: "jellygo.appLanguage") ?? ""
        return AppState.bundle(for: code)
    }()

    var currentLocale: Locale {
        appLanguage.isEmpty ? .current : Locale(identifier: appLanguage)
    }

    nonisolated static func bundle(for code: String) -> Bundle {
        guard !code.isEmpty,
              let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return .main }
        return b
    }

    nonisolated static func updateLocalizationBundle(_ code: String) {
        currentBundle = bundle(for: code)
    }

    init() {
        restore()
    }

    // MARK: - Migration

    /// One-time migration: fetch serverId from the server (no auth required) and
    /// copy the active token to the shared `userId@serverId` Keychain key so that
    /// all URL variants of the same user+server share one session token.
    func migrateServerIdIfNeeded() async {
        guard serverId.isEmpty, !serverURL.isEmpty, !token.isEmpty else { return }
        guard let info = try? await JellyfinAPI.shared.checkServer(url: serverURL) else { return }

        let sid = info.id
        self.serverId = sid
        UserDefaults.standard.set(sid, forKey: "jellygo.serverId")

        // Write active token under the new shared key
        KeychainService.shared.saveToken(token, forAccountId: "\(userId)@\(sid)")

        // Propagate serverId + shared token to all accounts for the same user
        savedAccounts = savedAccounts.map { account in
            guard account.userId == self.userId else { return account }
            let updated = SavedAccount(userId: account.userId, username: account.username,
                                       serverURL: account.serverURL, serverName: account.serverName,
                                       serverId: sid, alias: account.alias)
            KeychainService.shared.saveToken(token, forAccountId: updated.tokenKey)
            return updated
        }
        persistAccountList()
    }

    // MARK: - Restore

    private func restore() {
        if let data = UserDefaults.standard.data(forKey: "jellygo.savedAccounts"),
           let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data) {
            self.savedAccounts = accounts
        }

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
        self.serverId = UserDefaults.standard.string(forKey: "jellygo.serverId") ?? ""
        self.isAuthenticated = true

        // Migration: ensure the active session's token is stored under the composite key
        // and the account exists in savedAccounts (first run after multi-account update).
        let currentAccount = SavedAccount(userId: userId, username: self.username,
                                          serverURL: url, serverName: self.serverName,
                                          serverId: self.serverId.isEmpty ? nil : self.serverId)
        if KeychainService.shared.getToken(forAccountId: currentAccount.tokenKey) == nil {
            KeychainService.shared.saveToken(token, forAccountId: currentAccount.tokenKey)
        }
        if !savedAccounts.contains(where: { $0.id == currentAccount.id }) {
            savedAccounts.append(currentAccount)
            persistAccountList()
        }
    }

    // MARK: - Login / Logout

    func login(serverURL: String, serverName: String, userId: String, username: String, token: String, serverId: String = "") {
        let userChanged = !isAuthenticated || userId != self.userId

        self.serverURL = serverURL
        self.serverName = serverName
        self.serverId = serverId
        self.userId = userId
        self.username = username
        self.token = token

        KeychainService.shared.saveToken(token)
        UserDefaults.standard.set(serverURL, forKey: "jellygo.serverURL")
        UserDefaults.standard.set(serverName, forKey: "jellygo.serverName")
        UserDefaults.standard.set(userId, forKey: "jellygo.userId")
        UserDefaults.standard.set(username, forKey: "jellygo.username")
        UserDefaults.standard.set(serverId, forKey: "jellygo.serverId")

        persistAccount(serverURL: serverURL, serverName: serverName,
                       userId: userId, username: username, token: token, serverId: serverId)

        if userChanged { sessionId = UUID() }
        if !isAuthenticated { withAnimation { isAuthenticated = true } }
    }

    func logout() {
        // Remove current account from the saved list
        removeAccount(SavedAccount(userId: userId, username: username,
                                   serverURL: serverURL, serverName: serverName))
    }

    // MARK: - Multi-Account

    /// Called from LoginView when isAddingAccount == true.
    /// Returns true if the account was already in the list (duplicate).
    /// On success, SettingsView observes savedAccounts.count to close the sheet.
    /// On duplicate, LoginView shows an alert; tapping OK sets closeAddAccountSheet.
    @discardableResult
    func addAccount(serverURL: String, serverName: String, userId: String, username: String, token: String, serverId: String = "") -> Bool {
        let candidate = SavedAccount(userId: userId, username: username,
                                     serverURL: serverURL, serverName: serverName,
                                     serverId: serverId.isEmpty ? nil : serverId)
        if savedAccounts.contains(where: { $0.id == candidate.id }) {
            return true  // duplicate — caller handles the alert
        }
        persistAccount(serverURL: serverURL, serverName: serverName,
                       userId: userId, username: username, token: token, serverId: serverId)
        return false
    }

    @discardableResult
    func switchAccount(_ account: SavedAccount) -> Bool {
        guard let token = KeychainService.shared.getToken(forAccountId: account.tokenKey) else { return false }
        login(serverURL: account.serverURL, serverName: account.serverName,
              userId: account.userId, username: account.username, token: token,
              serverId: account.serverId ?? "")
        return true
    }

    func removeAccount(_ account: SavedAccount) {
        // Only delete the shared token if no other account uses the same tokenKey
        let sharesToken = savedAccounts.contains { $0.id != account.id && $0.tokenKey == account.tokenKey }
        if !sharesToken {
            KeychainService.shared.deleteToken(forAccountId: account.tokenKey)
        }
        savedAccounts.removeAll { $0.id == account.id }
        persistAccountList()

        if account.id == "\(userId)@\(serverURL)" {
            if let next = savedAccounts.first {
                switchAccount(next)
            } else {
                clearSession()
            }
        }
    }

    // MARK: - Private

    /// Alias is per server URL — applies to all accounts on the same URL.
    func updateAlias(_ alias: String, forAccountId accountId: String) {
        guard let ref = savedAccounts.first(where: { $0.id == accountId }) else { return }
        let value: String? = alias.isEmpty ? nil : alias
        savedAccounts = savedAccounts.map { account in
            guard account.serverURL == ref.serverURL else { return account }
            return SavedAccount(userId: account.userId, username: account.username,
                                serverURL: account.serverURL, serverName: account.serverName,
                                alias: value)
        }
        persistAccountList()
    }

    private func persistAccount(serverURL: String, serverName: String,
                                userId: String, username: String, token: String, serverId: String = "") {
        // Preserve existing alias when refreshing an account
        let existing = savedAccounts.first(where: { $0.id == "\(userId)@\(serverURL)" })
        let account = SavedAccount(userId: userId, username: username,
                                   serverURL: serverURL, serverName: serverName,
                                   serverId: serverId.isEmpty ? nil : serverId,
                                   alias: existing?.alias)
        KeychainService.shared.saveToken(token, forAccountId: account.tokenKey)
        if let idx = savedAccounts.firstIndex(where: { $0.id == account.id }) {
            savedAccounts[idx] = account
        } else {
            savedAccounts.append(account)
        }
        persistAccountList()
    }

    private func persistAccountList() {
        if let data = try? JSONEncoder().encode(savedAccounts) {
            UserDefaults.standard.set(data, forKey: "jellygo.savedAccounts")
        }
    }

    private func clearSession() {
        KeychainService.shared.deleteToken()
        UserDefaults.standard.removeObject(forKey: "jellygo.serverURL")
        UserDefaults.standard.removeObject(forKey: "jellygo.serverName")
        UserDefaults.standard.removeObject(forKey: "jellygo.userId")
        UserDefaults.standard.removeObject(forKey: "jellygo.username")
        UserDefaults.standard.removeObject(forKey: "jellygo.serverId")

        token = ""
        serverURL = ""
        serverName = ""
        serverId = ""
        userId = ""
        username = ""

        withAnimation { isAuthenticated = false }
    }
}
