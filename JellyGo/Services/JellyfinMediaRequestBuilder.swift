import Foundation

/// Single place that builds Jellyfin media / image / avatar / subtitle / download URLs
/// and decides how the access token travels with them.
///
/// Jellyfin Server 12 ignores the legacy `api_key` query parameter unless
/// `EnableLegacyAuthorization` is turned on. The supported channels are:
///   * `Authorization: MediaBrowser Token="…"` header — used for every request we
///     send ourselves through a foreground `URLSession` (images to disk, subtitles, avatar).
///   * `ApiKey` query parameter — used only where a header cannot be attached:
///     URLs handed to a player engine (AVPlayer / KSPlayer / VLC, including HLS
///     segment requests), `AsyncImage`, and background `URLSessionDownloadTask`s.
///
/// A request never carries both channels. The token is only ever attached to URLs
/// that point at the configured Jellyfin server (same origin and base path).
nonisolated enum JellyfinMediaRequestBuilder {

    /// Ordered output codecs supported by our playback engines. Jellyfin selects
    /// among them using its encoding settings; HEVC and H.265 are the same codec.
    static let preferredTranscodingVideoCodecs = "av1,hevc,h264"

    /// Query parameter Jellyfin 12 reads without legacy authorization.
    static let tokenQueryName = "ApiKey"
    /// Legacy parameter that must no longer be sent (compared case-insensitively).
    static let legacyTokenQueryName = "api_key"

    // MARK: - Base URL / joining

    /// Parses the stored server address, trimming whitespace and trailing slashes.
    /// Keeps a reverse-proxy base path such as `/jellyfin`.
    static func baseComponents(_ serverURL: String) -> URLComponents? {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var c = URLComponents(string: trimmed), c.scheme != nil, c.host != nil else { return nil }
        var path = c.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        c.percentEncodedPath = path
        c.percentEncodedQuery = nil
        c.fragment = nil
        return c
    }

    /// Joins the server address with a server-relative path. `path` may already carry a
    /// percent-encoded query (e.g. a `TranscodingUrl`); it is preserved verbatim and
    /// `queryItems` are appended after it.
    static func url(serverURL: String, path: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard var c = baseComponents(serverURL) else { return nil }
        var rel = path
        if let hash = rel.firstIndex(of: "#") { rel = String(rel[..<hash]) }
        var existingQuery: String?
        if let q = rel.firstIndex(of: "?") {
            existingQuery = String(rel[rel.index(after: q)...])
            rel = String(rel[..<q])
        }
        while rel.hasPrefix("/") { rel.removeFirst() }
        // Encode anything that is not legal in a path. Existing %xx escapes are kept only
        // when they are all valid; otherwise a stray "%" is encoded too.
        let allowed = rel.removingPercentEncoding != nil ? pathAllowedKeepingEscapes : CharacterSet.urlPathAllowed
        let encodedRel = rel.addingPercentEncoding(withAllowedCharacters: allowed) ?? rel
        c.percentEncodedPath = c.percentEncodedPath + "/" + encodedRel

        var items = parseQuery(existingQuery)
        items.append(contentsOf: queryItems.map { encode($0) })
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        return c.url
    }

    /// Resolves a server-provided URL (`TranscodingUrl`, stream URL …) that may be either
    /// server-relative (`/videos/…`) or absolute (`https://…`).
    static func resolve(serverURL: String, pathOrURL: String) -> URL? {
        let s = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let abs = URLComponents(string: s), abs.scheme != nil, abs.host != nil {
            return abs.url
        }
        return url(serverURL: serverURL, path: s)
    }

    // MARK: - Origin checks

    /// True when `url` has the same scheme/host/port as the server and lies under its base path.
    static func belongsToServer(_ url: URL, serverURL: String) -> Bool {
        guard let base = baseComponents(serverURL),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        guard origin(base) == origin(target) else { return false }
        let basePath = base.percentEncodedPath.lowercased()
        if basePath.isEmpty { return true }
        let path = target.percentEncodedPath.lowercased()
        return path == basePath || path.hasPrefix(basePath + "/")
    }

    private static func origin(_ c: URLComponents) -> String {
        let scheme = (c.scheme ?? "").lowercased()
        let host = (c.host ?? "").lowercased()
        let port = c.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
        return "\(scheme)://\(host):\(port)"
    }

    // MARK: - Query token (ApiKey)

    /// Returns `url` with the legacy `api_key` removed and exactly one `ApiKey`.
    /// - If the URL is not on the configured server, it is returned unchanged (no token leak).
    /// - If an `ApiKey` is already present it is kept (server-issued `TranscodingUrl`),
    ///   unless `replaceExisting` is true (URLs we own, e.g. resumed downloads).
    static func authorizedURL(_ url: URL, serverURL: String, token: String,
                              replaceExisting: Bool = false) -> URL {
        guard belongsToServer(url, serverURL: serverURL),
              var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = c.percentEncodedQueryItems ?? []
        items.removeAll { $0.name.lowercased() == legacyTokenQueryName }

        let tokenIdx = items.indices.filter { items[$0].name.lowercased() == tokenQueryName.lowercased() }
        if let first = tokenIdx.first, !replaceExisting, !(items[first].value ?? "").isEmpty {
            // keep the first ApiKey, drop duplicates
            for i in tokenIdx.dropFirst().reversed() { items.remove(at: i) }
        } else {
            for i in tokenIdx.reversed() { items.remove(at: i) }
            if !token.isEmpty { items.append(encode(URLQueryItem(name: tokenQueryName, value: token))) }
        }
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        return c.url ?? url
    }

    /// Server-relative media URL with the token as `ApiKey` (for players / AsyncImage / background downloads).
    static func mediaURL(serverURL: String, path: String, queryItems: [URLQueryItem] = [], token: String) -> URL? {
        guard let u = url(serverURL: serverURL, path: path, queryItems: queryItems) else { return nil }
        return authorizedURL(u, serverURL: serverURL, token: token)
    }

    /// Removes every token query parameter (`ApiKey`, `api_key`, any case).
    static func strippingTokens(_ url: URL) -> URL {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = c.percentEncodedQueryItems else { return url }
        let kept = items.filter { !isTokenName($0.name) }
        guard kept.count != items.count else { return url }
        c.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return c.url ?? url
    }

    /// Token carried in the URL, if any (`ApiKey` preferred over legacy `api_key`).
    static func tokenValue(in url: URL) -> String? {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return items.first(where: { $0.name.lowercased() == tokenQueryName.lowercased() })?.value
            ?? items.first(where: { $0.name.lowercased() == legacyTokenQueryName })?.value
    }

    static func hasLegacyToken(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name.lowercased() == legacyTokenQueryName } ?? false
    }

    /// For a stored URL whose account context is unknown: moves a legacy `api_key`
    /// value to `ApiKey` (same token), leaving everything else intact.
    static func upgradingLegacyToken(_ url: URL) -> URL {
        guard hasLegacyToken(url), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let legacyValue = c.queryItems?.first { $0.name.lowercased() == legacyTokenQueryName }?.value
        var items = c.percentEncodedQueryItems ?? []
        items.removeAll { $0.name.lowercased() == legacyTokenQueryName }
        let hasApiKey = items.contains { $0.name.lowercased() == tokenQueryName.lowercased() }
        if !hasApiKey, let legacyValue, !legacyValue.isEmpty {
            items.append(encode(URLQueryItem(name: tokenQueryName, value: legacyValue)))
        }
        c.percentEncodedQueryItems = items.isEmpty ? nil : items
        return c.url ?? url
    }

    /// Moves a URL that was built for `oldServerURL` onto `newServerURL`
    /// (e.g. local ↔ remote address of the same server). Returns nil when the URL
    /// does not belong to `oldServerURL`.
    static func rebase(_ url: URL, from oldServerURL: String, to newServerURL: String) -> URL? {
        guard belongsToServer(url, serverURL: oldServerURL),
              let old = baseComponents(oldServerURL),
              var new = baseComponents(newServerURL),
              let target = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let rest = String(target.percentEncodedPath.dropFirst(old.percentEncodedPath.count))
        new.percentEncodedPath = new.percentEncodedPath + (rest.hasPrefix("/") ? rest : "/" + rest)
        new.percentEncodedQuery = target.percentEncodedQuery
        return new.url
    }

    // MARK: - Header (URLSession requests we send ourselves)

    static func authorizationHeaderValue(token: String) -> String {
        "MediaBrowser Token=\"\(token)\""
    }

    /// Request authenticated through the `Authorization` header only; any token in the
    /// query is stripped so the request never carries two channels. The header is added
    /// only when the URL belongs to the server.
    static func authorizedRequest(url: URL, serverURL: String, token: String) -> URLRequest {
        let clean = strippingTokens(url)
        var req = URLRequest(url: clean)
        if !token.isEmpty, belongsToServer(clean, serverURL: serverURL) {
            req.setValue(authorizationHeaderValue(token: token), forHTTPHeaderField: "Authorization")
        }
        return req
    }

    // MARK: - Log masking

    private static let maskPatterns: [NSRegularExpression] = {
        let patterns = [
            // ?ApiKey=…, &api_key=…, also JSON-escaped &ApiKey=…
            #"((?:[?&]|\\u0026)(?:api_key|apikey)=)[^&#\s"'\\]+"#,
            // Token="…" inside an Authorization header value
            #"(Token=\\?")[^"\\]+"#,
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// Masks token values so URLs / headers can be logged safely.
    static func masked(_ string: String) -> String {
        var out = string
        for re in maskPatterns {
            let range = NSRange(out.startIndex..., in: out)
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "$1***")
        }
        return out
    }

    static func masked(_ url: URL?) -> String {
        guard let url else { return "nil" }
        return masked(url.absoluteString)
    }

    // MARK: - Private helpers

    private static func isTokenName(_ name: String) -> Bool {
        let n = name.lowercased()
        return n == tokenQueryName.lowercased() || n == legacyTokenQueryName
    }

    /// Characters allowed in a query name/value we add ourselves (RFC 3986 unreserved).
    private static let queryValueAllowed = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~,")

    private static let pathAllowedKeepingEscapes: CharacterSet = {
        var s = CharacterSet.urlPathAllowed
        s.insert("%")
        return s
    }()

    private static func encode(_ item: URLQueryItem) -> URLQueryItem {
        URLQueryItem(
            name: item.name.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? item.name,
            value: item.value?.addingPercentEncoding(withAllowedCharacters: queryValueAllowed)
        )
    }

    /// Splits an already percent-encoded query into items without re-encoding them.
    /// A malformed query (invalid escapes / illegal characters) is decoded leniently and
    /// re-encoded instead of being passed through, so URLComponents never sees bad input.
    private static func parseQuery(_ query: String?) -> [URLQueryItem] {
        guard let query, !query.isEmpty else { return [] }
        if let c = URLComponents(string: "http://h/?" + query), let items = c.percentEncodedQueryItems {
            return items
        }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : nil
            return encode(URLQueryItem(name: name.removingPercentEncoding ?? name,
                                       value: value.map { $0.removingPercentEncoding ?? $0 }))
        }
    }
}
