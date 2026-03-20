import SwiftUI
import Network
import Combine

// MARK: - Network Scanner

@MainActor
final class JellyfinNetworkScanner: ObservableObject {
    @Published var results: [DiscoveredServer] = []
    @Published var isScanning = false

    struct DiscoveredServer: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let url: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.url == rhs.url }
    }

    private var scanTask: Task<Void, Never>?
    private var readSource: DispatchSourceRead?
    private var socketFD: Int32 = -1

    func scan() {
        results = []
        isScanning = true

        scanTask = Task { [weak self] in
            await self?.triggerLocalNetworkPermission()
            try? await Task.sleep(for: .milliseconds(300))
            await MainActor.run { self?.udpDiscovery() }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.stopScan() }
        }
    }

    private func triggerLocalNetworkPermission() async {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_jellyfin._tcp.", domain: "local."), using: .init())
        browser.start(queue: .main)
        try? await Task.sleep(for: .seconds(1))
        browser.cancel()
    }

    private func udpDiscovery() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        socketFD = fd

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr.s_addr = INADDR_ANY
        withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        readSource = source
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            var srcAddr = sockaddr_in()
            var srcLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &srcAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &srcLen)
                }
            }
            guard n > 0 else { return }
            let data = Data(buffer[..<n])
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["Name"] as? String else { return }

            let ipBytes = withUnsafeBytes(of: srcAddr.sin_addr.s_addr) { Array($0) }
            let sourceIP = ipBytes.map { String($0) }.joined(separator: ".")
            let port = (json["Address"] as? String).flatMap { URLComponents(string: $0)?.port } ?? 8096
            let url = "http://\(sourceIP):\(port)"

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if !self.results.contains(where: { $0.url == url }) {
                    self.results.append(DiscoveredServer(name: name, url: url))
                }
            }
        }
        source.resume()

        // Subnet broadcast (255.255.255.255 doesn't work on iOS)
        var broadcastAddr: in_addr_t = INADDR_BROADCAST
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifaddrsPtr) == 0, let first = ifaddrsPtr {
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let ifa = ptr {
                if String(cString: ifa.pointee.ifa_name) == "en0",
                   ifa.pointee.ifa_addr.pointee.sa_family == sa_family_t(AF_INET),
                   let addr = ifa.pointee.ifa_addr,
                   let mask = ifa.pointee.ifa_netmask {
                    let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    let netmask = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    broadcastAddr = ip | ~netmask
                    break
                }
                ptr = ifa.pointee.ifa_next
            }
            freeifaddrs(first)
        }

        var destAddr = sockaddr_in()
        destAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = UInt16(7359).bigEndian
        destAddr.sin_addr.s_addr = broadcastAddr
        let message = "Who is JellyfinServer?".data(using: .utf8)!
        message.withUnsafeBytes { buf in
            withUnsafePointer(to: &destAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 { close(socketFD); socketFD = -1 }
        isScanning = false
    }
}

// MARK: - ServerView

struct ServerView: View {
    @EnvironmentObject private var appState: AppState

    // Server
    @State private var serverHost = ""
    @State private var serverPort = "8096"
    @State private var useHTTPS = false
    @State private var serverInfo: JellyfinServerInfo?
    @StateObject private var scanner = JellyfinNetworkScanner()

    // Login
    @State private var showLogin = false
    @State private var username = ""
    @State private var password = ""
    @State private var showLoginForm = false
    @State private var quickConnectEnabled = false
    @State private var quickConnectCode: String?
    @State private var quickConnectSecret: String?
    @State private var quickConnectPolling = false
    @State private var quickConnectTask: Task<Void, Never>?
    @State private var showDuplicateAlert = false

    // Shared
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var appeared = false
    @FocusState private var focusedField: InputField?

    private enum InputField { case host, port, username, password }

    private let accentColor = Color(red: 0.75, green: 0.15, blue: 0.20)
    private let backdropImages = ["Backdrop1", "Backdrop2", "Backdrop3", "Backdrop4", "Backdrop5", "Backdrop6"]
    @State private var currentBackdrop = 0
    @State private var trendingItems: [TMDBService.TrendingItem] = []

    var body: some View {
        GeometryReader { geo in
            let screenH = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom

            ZStack(alignment: .bottom) {
                // MARK: Katman 1 — Backdrop carousel
                ZStack {
                    if trendingItems.isEmpty {
                        ForEach(Array(backdropImages.enumerated()), id: \.offset) { index, name in
                            Image(name)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: screenH)
                                .clipped()
                                .opacity(index == currentBackdrop ? 1 : 0)
                                .animation(.easeInOut(duration: 1.5), value: currentBackdrop)
                                .scaleEffect(index == currentBackdrop ? 1.05 : 1.0)
                                .animation(.easeInOut(duration: 8), value: currentBackdrop)
                        }
                    } else {
                        ForEach(Array(trendingItems.enumerated()), id: \.offset) { index, item in
                            AsyncImage(url: URL(string: item.posterURL)) { phase in
                                switch phase {
                                case .success(let image):
                                    image.resizable().scaledToFill()
                                default:
                                    Image(backdropImages[index % backdropImages.count])
                                        .resizable().scaledToFill()
                                }
                            }
                            .frame(width: geo.size.width, height: screenH)
                            .clipped()
                            .opacity(index == currentBackdrop ? 1 : 0)
                            .animation(.easeInOut(duration: 1.5), value: currentBackdrop)
                            .scaleEffect(index == currentBackdrop ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 8), value: currentBackdrop)
                        }
                    }
                }
                .frame(width: geo.size.width, height: screenH)
                .onTapGesture { focusedField = nil }
                .onAppear {
                    let total = trendingItems.isEmpty ? backdropImages.count : trendingItems.count
                    Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { _ in
                        withAnimation { currentBackdrop = (currentBackdrop + 1) % total }
                    }
                }
                .task {
                    let items = await TMDBService.fetchTrending()
                    if !items.isEmpty {
                        currentBackdrop = 0
                        trendingItems = items
                    }
                }

                // MARK: Katman 2+3 — Blur + Form
                VStack(spacing: 0) {
                    if showLogin {
                        Spacer()
                        loginContent
                        Spacer()
                    } else {
                        Spacer().frame(height: 200)
                        serverContent
                    }
                }
                .padding(.bottom, showLogin ? 0 : geo.safeAreaInsets.bottom)
                .frame(height: showLogin ? screenH : nil)
                .background(
                    ZStack {
                        if showLogin {
                            Rectangle().fill(.ultraThinMaterial)
                            Color.black.opacity(0.3)
                        } else {
                            Rectangle()
                                .fill(.ultraThinMaterial)
                                .mask(
                                    LinearGradient(
                                        stops: [
                                            .init(color: .clear, location: 0.0),
                                            .init(color: .white, location: 0.45),
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black.opacity(0.15), location: 0.35),
                                    .init(color: .black.opacity(0.4), location: 0.65),
                                    .init(color: .black.opacity(0.55), location: 1.0),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        }
                    }
                )
                .animation(.easeInOut(duration: 0.4), value: showLogin)
            }
        }
        .ignoresSafeArea(.container, edges: .all)
        // Title overlay
        .overlay(alignment: .top) {
            HStack {
                if showLogin {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showLogin = false
                            errorMessage = nil
                            username = ""
                            password = ""
                            quickConnectTask?.cancel()
                            quickConnectCode = nil
                            quickConnectSecret = nil
                            quickConnectPolling = false
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }

                if !isAddingMode {
                    Text("JellyGo")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3, x: 0, y: 1)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "film")
                        .font(.system(size: 8, weight: .bold))
                    Text("TMDB")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.3))
            }
            .padding(.horizontal, 20)
            .padding(.top, isAddingMode ? 16 : 4)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.6)) { appeared = true }
        }
        .onChange(of: scanner.results) { results in
            if let first = results.first {
                parseURL(first.url)
            }
        }
        .onChange(of: serverHost) { host in
            let shouldBeHTTPS = hostLooksLikeDomain(host)
            if useHTTPS != shouldBeHTTPS {
                useHTTPS = shouldBeHTTPS
                serverPort = shouldBeHTTPS ? "443" : "8096"
            }
        }
        .alert(String(localized: "Account Already Added", bundle: AppState.currentBundle), isPresented: $showDuplicateAlert) {
            Button(String(localized: "OK", bundle: AppState.currentBundle)) { appState.closeAddAccountSheet = true }
        } message: {
            if let info = serverInfo {
                Text(String(localized: "\(username) on \(info.serverName) is already in your account list.", bundle: AppState.currentBundle))
            }
        }
    }

    // MARK: - Server Content

    private var serverContent: some View {
        VStack(spacing: 16) {
            // Saved servers
            if !uniqueServers.isEmpty {
                sectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(uniqueServers.enumerated()), id: \.element.url) { index, server in
                            if index > 0 {
                                Divider().padding(.leading, 52)
                            }
                            Button {
                                parseURL(server.url)
                                Task { await connect() }
                            } label: {
                                serverRow(name: server.name, url: server.url, icon: "server.rack", iconColor: accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                } header: {
                    String(localized: "Saved Servers", bundle: AppState.currentBundle)
                }
            }

            // Discovered servers
            if !scanner.results.isEmpty {
                sectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(scanner.results.enumerated()), id: \.element.id) { index, server in
                            if index > 0 {
                                Divider().padding(.leading, 52)
                            }
                            Button {
                                parseURL(server.url)
                                scanner.stopScan()
                                Task { await connect() }
                            } label: {
                                serverRow(name: server.name, url: server.url, icon: "wifi", iconColor: accentColor)
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                } header: {
                    String(localized: "Found on Network", bundle: AppState.currentBundle)
                }
            }

            // Manual entry
            sectionCard {
                VStack(spacing: 14) {
                    HStack(spacing: 0) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                useHTTPS.toggle()
                                serverPort = useHTTPS ? "443" : "8096"
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: useHTTPS ? "lock.fill" : "lock.open.fill")
                                    .font(.system(size: 9, weight: .bold))
                                Text(useHTTPS ? "https" : "http")
                                    .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            }
                            .foregroundStyle(useHTTPS ? .green : .white.opacity(0.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(useHTTPS ? Color.green.opacity(0.15) : .white.opacity(0.08)))
                        }
                        .padding(.leading, 10)
                        .padding(.trailing, 6)

                        TextField("", text: $serverHost, prompt: Text("192.168.1.1").foregroundStyle(.white.opacity(0.25)))
                            .textFieldStyle(.plain)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .focused($focusedField, equals: .host)
                            .foregroundStyle(.white)
                            .font(.subheadline)
                            .tint(accentColor)

                        Text(":")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.25))

                        TextField("", text: $serverPort, prompt: Text(useHTTPS ? "443" : "8096").foregroundStyle(.white.opacity(0.25)))
                            .textFieldStyle(.plain)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .port)
                            .foregroundStyle(.white.opacity(0.7))
                            .font(.system(.subheadline, design: .monospaced))
                            .tint(accentColor)
                            .frame(width: 48)
                            .padding(.trailing, 14)
                    }
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(
                                        errorMessage != nil ? Color.red.opacity(0.5) :
                                        (focusedField == .host || focusedField == .port) ? accentColor.opacity(0.4) : .white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    )

                    if let error = errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption2)
                            Text(error)
                                .font(.caption)
                        }
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    HStack(spacing: 10) {
                        Button {
                            focusedField = nil
                            if scanner.isScanning { scanner.stopScan() } else { scanner.scan() }
                        } label: {
                            HStack(spacing: 6) {
                                if scanner.isScanning {
                                    ProgressView().scaleEffect(0.7).tint(.white.opacity(0.7))
                                    Text(String(localized: "Scanning\u{2026}", bundle: AppState.currentBundle))
                                } else {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                    Text(String(localized: "Scan", bundle: AppState.currentBundle))
                                }
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 20)
                            .frame(height: 48)
                            .background(.regularMaterial, in: Capsule())
                        }
                        .disabled(isLoading)

                        Button {
                            focusedField = nil
                            Task { await connect() }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView().tint(.black)
                                } else {
                                    Image(systemName: "arrow.right")
                                    Text(String(localized: "Connect", bundle: AppState.currentBundle))
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(serverHost.isEmpty || isLoading ? .black.opacity(0.3) : .black)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background { Capsule().fill(serverHost.isEmpty || isLoading ? .white.opacity(0.4) : .white) }
                        }
                        .disabled(serverHost.isEmpty || isLoading)
                    }
                }
            } header: {
                uniqueServers.isEmpty
                    ? String(localized: "Server Address", bundle: AppState.currentBundle)
                    : String(localized: "Add New Server", bundle: AppState.currentBundle)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
    }

    // MARK: - Login Content

    private var loginContent: some View {
        VStack(spacing: 16) {
            // Server info header
            if let info = serverInfo {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(accentColor.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: "server.rack")
                            .font(.subheadline)
                            .foregroundStyle(accentColor)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.serverName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Text(normalizedURL)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
            }

            // Known users (adding account mode)
            if isAddingMode && !knownUsers.isEmpty {
                sectionCard {
                    VStack(spacing: 0) {
                        ForEach(Array(knownUsers.enumerated()), id: \.element.id) { index, account in
                            if index > 0 {
                                Divider().padding(.leading, 56)
                            }
                            Button { addExisting(account) } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(accentColor.opacity(0.2))
                                            .frame(width: 36, height: 36)
                                        Text(account.username.prefix(1).uppercased())
                                            .font(.subheadline.bold())
                                            .foregroundStyle(accentColor)
                                    }
                                    Text(account.username)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.white)
                                    Spacer()
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(accentColor)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isLoading)
                        }
                    }
                } header: {
                    String(localized: "Add existing account", bundle: AppState.currentBundle)
                }

                if !showLoginForm {
                    Button {
                        withAnimation(.spring(duration: 0.3)) { showLoginForm = true }
                    } label: {
                        HStack(spacing: 12) {
                            VStack { Divider().overlay(Color.white.opacity(0.1)) }
                            Text(String(localized: "Sign in as a different user", bundle: AppState.currentBundle))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                                .fixedSize()
                            VStack { Divider().overlay(Color.white.opacity(0.1)) }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            // Login form
            if !isAddingMode || knownUsers.isEmpty || showLoginForm {
                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Image(systemName: "person")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 20)
                            TextField("", text: $username, prompt: Text(String(localized: "Username", bundle: AppState.currentBundle)).foregroundStyle(.white.opacity(0.25)))
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .submitLabel(.next)
                                .focused($focusedField, equals: .username)
                                .foregroundStyle(.white)
                                .tint(accentColor)
                                .onSubmit { focusedField = .password }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)

                        Divider().padding(.leading, 44)

                        HStack(spacing: 10) {
                            Image(systemName: "lock")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.4))
                                .frame(width: 20)
                            SecureField("", text: $password, prompt: Text(String(localized: "Password", bundle: AppState.currentBundle)).foregroundStyle(.white.opacity(0.25)))
                                .textFieldStyle(.plain)
                                .submitLabel(.go)
                                .focused($focusedField, equals: .password)
                                .foregroundStyle(.white)
                                .tint(accentColor)
                                .onSubmit {
                                    guard !username.isEmpty && !password.isEmpty else { return }
                                    Task { await loginWithPassword() }
                                }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                    }
                    .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(
                                errorMessage != nil ? Color.red.opacity(0.5) : .white.opacity(0.08),
                                lineWidth: 1
                            )
                    )

                    if let error = errorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .font(.caption2)
                            Text(error)
                                .font(.caption)
                        }
                        .foregroundStyle(.red.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    Button {
                        Task { await loginWithPassword() }
                    } label: {
                        HStack(spacing: 8) {
                            if isLoading {
                                ProgressView().tint(.black)
                            } else {
                                Image(systemName: "arrow.right")
                                Text(String(localized: "Sign In", bundle: AppState.currentBundle))
                            }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(username.isEmpty || isLoading ? .black.opacity(0.3) : .black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background { Capsule().fill(username.isEmpty || isLoading ? .white.opacity(0.4) : .white) }
                    }
                    .disabled(username.isEmpty || isLoading)
                }
            }

            // QuickConnect
            if quickConnectEnabled {
                quickConnectSection
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 48)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - QuickConnect

    private var quickConnectSection: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                VStack { Divider().overlay(Color.white.opacity(0.1)) }
                Text(String(localized: "or", bundle: AppState.currentBundle))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.35))
                VStack { Divider().overlay(Color.white.opacity(0.1)) }
            }

            if let code = quickConnectCode {
                VStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(accentColor)
                        Text(String(localized: "Quick Connect", bundle: AppState.currentBundle))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }

                    HStack(spacing: 8) {
                        ForEach(Array(code), id: \.self) { digit in
                            Text(String(digit))
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 48)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(.white.opacity(0.08))
                                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(accentColor.opacity(0.3), lineWidth: 1))
                                )
                        }
                    }

                    Text(String(localized: "Enter this code in your Jellyfin dashboard to sign in.", bundle: AppState.currentBundle))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)

                    if quickConnectPolling {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.65).tint(accentColor)
                            Text(String(localized: "Waiting for approval\u{2026}", bundle: AppState.currentBundle))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(20)
                .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(accentColor.opacity(0.15), lineWidth: 1))
            } else {
                Button {
                    focusedField = nil
                    Task { await initiateQuickConnect() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.fill")
                        Text(String(localized: "Quick Connect", bundle: AppState.currentBundle))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(.regularMaterial, in: Capsule())
                }
                .disabled(isLoading)
            }
        }
    }

    // MARK: - Components

    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content, header: () -> String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(header())
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.4))
                .textCase(.uppercase)
                .padding(.horizontal, 4)

            content()
                .padding(12)
                .background(.ultraThinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                )
        }
    }

    private func serverRow(name: String, url: String, icon: String, iconColor: Color) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.subheadline)
                    .foregroundStyle(iconColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(url)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.2))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Data

    private var isAddingMode: Bool { appState.isAddingAccount }

    private var knownUsers: [SavedAccount] {
        guard let info = serverInfo else { return [] }
        var seen = Set<String>()
        var result: [SavedAccount] = []
        for account in appState.savedAccounts {
            let matchesServer = (account.serverId.map { !$0.isEmpty && $0 == info.id } ?? false)
                             || account.serverURL == normalizedURL
            guard matchesServer, !seen.contains(account.userId) else { continue }
            seen.insert(account.userId)
            result.append(account)
        }
        return result
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
        let scheme = useHTTPS ? "https" : "http"
        let host = serverHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = serverPort.trimmingCharacters(in: .whitespacesAndNewlines)
        let skipPort = useHTTPS ? "443" : "80"
        if port.isEmpty || port == skipPort {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private func parseURL(_ rawURL: String) {
        var url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url = String(url.dropLast()) }

        // Explicit scheme overrides auto-detection
        var explicitScheme: Bool? = nil
        if url.hasPrefix("https://") {
            explicitScheme = true
            url = String(url.dropFirst(8))
        } else if url.hasPrefix("http://") {
            explicitScheme = false
            url = String(url.dropFirst(7))
        }

        if let colonIdx = url.lastIndex(of: ":") {
            let portPart = String(url[url.index(after: colonIdx)...])
            if portPart.allSatisfy(\.isNumber) && !portPart.isEmpty {
                serverHost = String(url[..<colonIdx])
                serverPort = portPart
            } else {
                serverHost = url
            }
        } else {
            serverHost = url
        }

        if let scheme = explicitScheme {
            useHTTPS = scheme
        } else {
            useHTTPS = hostLooksLikeDomain(serverHost)
        }
        // Only set default port if not explicitly parsed
        if url.lastIndex(of: ":") == nil || !(url[url.index(after: url.lastIndex(of: ":")!)...]).allSatisfy(\.isNumber) {
            serverPort = useHTTPS ? "443" : "8096"
        }
    }

    /// Returns true if host looks like a public domain (→ HTTPS).
    /// Returns false for IPs, simple hostnames (MagicDNS), localhost.
    private func hostLooksLikeDomain(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty { return false }

        // IP address: all segments are numbers
        let segments = h.split(separator: ".")
        if segments.count == 4 && segments.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return false
        }

        // No dots = simple hostname (mac-mini, jellyfin, localhost)
        if !h.contains(".") { return false }

        // Has dots + not IP = domain name (stockholm.anilozturk.com)
        return true
    }

    // MARK: - Server Actions

    private func connect() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let info = try await JellyfinAPI.shared.checkServer(url: normalizedURL)
            serverInfo = info
            withAnimation(.easeInOut(duration: 0.4)) { showLogin = true }
            if !isAddingMode || knownUsers.isEmpty { focusedField = .username }
            Task { await checkQuickConnect() }
        } catch let error as JellyfinAPIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Login Actions

    private func loginWithPassword() async {
        errorMessage = nil
        isLoading = true
        defer { isLoading = false }

        do {
            let response = try await JellyfinAPI.shared.login(
                serverURL: normalizedURL,
                username: username,
                password: password
            )
            if appState.isAddingAccount {
                let isDuplicate = appState.addAccount(
                    serverURL: normalizedURL,
                    serverName: serverInfo?.serverName ?? "",
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
                if isDuplicate { showDuplicateAlert = true }
            } else {
                appState.login(
                    serverURL: normalizedURL,
                    serverName: serverInfo?.serverName ?? "",
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

    private func addExisting(_ account: SavedAccount) {
        let token = KeychainService.shared.getToken(forAccountId: account.tokenKey) ?? appState.token
        let isDuplicate = appState.addAccount(
            serverURL: normalizedURL,
            serverName: serverInfo?.serverName ?? "",
            userId: account.userId,
            username: account.username,
            token: token,
            serverId: serverInfo?.id ?? ""
        )
        if isDuplicate { showDuplicateAlert = true }
    }

    // MARK: - QuickConnect Actions

    private func checkQuickConnect() async {
        quickConnectEnabled = (try? await JellyfinAPI.shared.quickConnectEnabled(serverURL: normalizedURL)) ?? false
    }

    private func initiateQuickConnect() async {
        errorMessage = nil
        do {
            let result = try await JellyfinAPI.shared.quickConnectInitiate(serverURL: normalizedURL)
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
                let authenticated = (try? await JellyfinAPI.shared.quickConnectCheck(serverURL: normalizedURL, secret: secret)) ?? false
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
            let response = try await JellyfinAPI.shared.quickConnectAuthenticate(serverURL: normalizedURL, secret: secret)
            if appState.isAddingAccount {
                let isDuplicate = appState.addAccount(
                    serverURL: normalizedURL,
                    serverName: serverInfo?.serverName ?? "",
                    userId: response.user.id,
                    username: response.user.name,
                    token: response.accessToken,
                    serverId: response.serverId
                )
                if isDuplicate { showDuplicateAlert = true }
            } else {
                appState.login(
                    serverURL: normalizedURL,
                    serverName: serverInfo?.serverName ?? "",
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
}