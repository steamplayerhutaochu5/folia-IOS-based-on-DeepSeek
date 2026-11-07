import Foundation
import WebKit

// src/ios/App/App/FoliaCookieJar.swift
// 进程内的第三方 Cookie 仓库。
//
// 安卓版把所有网络请求交给 OkHttp，Cookie 由系统 WebView 的 CookieManager 统一持有；
// iOS 的 WKHTTPCookieStore 只能供 WebView 自己用，URLSession 不会自动共享它。
// 所以这里用一份可持久化的 JSON 做单一事实来源：原生请求从它取 Cookie、写回 Set-Cookie，
// 同时增量镜像到 WKHTTPCookieStore，页面里偶尔读 document.cookie 的代码也不会分叉。

/// 仓库里的一条 Cookie（与扩展的 chrome.cookies Cookie 形状保持接近）。
struct FoliaStoredCookie: Codable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var secure: Bool
    var expiresAt: Double?

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: expiresAt) < Date()
    }

    var identity: String {
        "\(domain.lowercased())|\(path)|\(name)"
    }
}

final class FoliaCookieJar {
    static let shared = FoliaCookieJar()

    private let lock = NSLock()
    private var cookies: [String: FoliaStoredCookie] = [:]
    private let storeURL: URL
    private weak var webViewCookieStore: WKHTTPCookieStore?

    private init() {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = base.appendingPathComponent("folia-cookies.json")
        load()
    }

    /// 让仓库能镜像到页面所在的 WKWebView。
    func attach(webViewCookieStore store: WKHTTPCookieStore?) {
        lock.lock()
        webViewCookieStore = store
        lock.unlock()
    }

    func allCookies() -> [FoliaStoredCookie] {
        lock.lock()
        defer { lock.unlock() }
        return cookies.values.filter { !$0.isExpired }
    }

    /// 按 URL 的 host/path/secure 过滤出该请求应该携带的 Cookie。
    func cookies(for url: URL) -> [FoliaStoredCookie] {
        let host = (url.host ?? "").lowercased()
        let path = url.path.isEmpty ? "/" : url.path
        let secureRequest = url.scheme?.lowercased() == "https"
        lock.lock()
        defer { lock.unlock() }
        return cookies.values.filter { cookie in
            guard !cookie.isExpired else { return false }
            if cookie.secure && !secureRequest { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty else { return false }
            guard host == domain || host.hasSuffix("." + domain) else { return false }
            return path.hasPrefix(cookie.path)
        }.sorted { $0.path.count > $1.path.count }
    }

    /// 拼成请求头里的 `Cookie: a=1; b=2`。
    func cookieHeader(for url: URL) -> String? {
        let matched = cookies(for: url)
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    func set(_ cookie: FoliaStoredCookie) {
        lock.lock()
        cookies[cookie.identity] = cookie
        let snapshot = Array(cookies.values)
        lock.unlock()
        persist(snapshot)
        mirrorToWebView(cookie)
    }

    func remove(url: URL, name: String) {
        let host = (url.host ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        lock.lock()
        let identities = cookies.keys.filter { key in
            let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return false }
            let domain = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matchesDomain = host == domain || host.hasSuffix("." + domain)
            return matchesDomain && parts[2] == name
        }
        identities.forEach { cookies.removeValue(forKey: $0) }
        let snapshot = Array(cookies.values)
        lock.unlock()
        persist(snapshot)
        for identity in identities {
            let parts = identity.split(separator: "|", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            let expired = HTTPCookie(properties: [
                .name: parts[2],
                .value: "",
                .domain: parts[0],
                .path: parts[1],
                .secure: false,
                .expires: Date(timeIntervalSince1970: 0),
            ])
            if let expired, let store = currentWebViewStore() {
                store.delete(expired, completionHandler: nil)
            }
        }
    }

    func removeAlsoDeletingAll() {
        lock.lock()
        cookies.removeAll()
        lock.unlock()
        persist([])
    }

    /// 把响应里的 Set-Cookie 头写进仓库。
    func store(setCookieHeaders: [String], for url: URL) {
        guard !setCookieHeaders.isEmpty else { return }
        for raw in setCookieHeaders {
            let headerFields = ["Set-Cookie": raw]
            let parsed = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            for cookie in parsed {
                let domain = cookie.domain.isEmpty ? (url.host ?? "") : cookie.domain
                let path = cookie.path.isEmpty ? "/" : cookie.path
                let record = FoliaStoredCookie(
                    name: cookie.name,
                    value: cookie.value,
                    domain: domain,
                    path: path,
                    secure: cookie.isSecure,
                    expiresAt: cookie.expiresDate?.timeIntervalSince1970
                )
                lock.lock()
                cookies[record.identity] = record
                let snapshot = Array(cookies.values)
                lock.unlock()
                persist(snapshot)
                mirrorToWebView(record)
            }
        }
    }

    /// 把响应头按 name 取出（可能重复），供 JS 侧读 Set-Cookie。
    static func headerEntries(from response: HTTPURLResponse) -> [[String: String]] {
        var entries: [[String: String]] = []
        for (rawName, rawValue) in response.allHeaderFields {
            let name = String(describing: rawName)
            if let list = rawValue as? [String] {
                list.forEach { entries.append(["name": name, "value": $0]) }
            } else {
                entries.append(["name": name, "value": String(describing: rawValue)])
            }
        }
        return entries
    }

    static func setCookieValues(in entries: [[String: String]]) -> [String] {
        entries
            .filter { ($0["name"] ?? "").lowercased() == "set-cookie" }
            .compactMap { $0["value"] }
    }

    private func currentWebViewStore() -> WKHTTPCookieStore? {
        lock.lock()
        defer { lock.unlock() }
        return webViewCookieStore
    }

    private func mirrorToWebView(_ cookie: FoliaStoredCookie) {
        guard let store = currentWebViewStore() else { return }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: cookie.name,
            .value: cookie.value,
            .domain: cookie.domain,
            .path: cookie.path,
            .secure: cookie.secure,
        ]
        if let expiresAt = cookie.expiresAt {
            properties[.expires] = Date(timeIntervalSince1970: expiresAt)
        }
        guard let httpCookie = HTTPCookie(properties: properties) else { return }
        store.setCookie(httpCookie, completionHandler: nil)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode([FoliaStoredCookie].self, from: data) else { return }
        lock.lock()
        cookies = Dictionary(uniqueKeysWithValues: decoded.map { ($0.identity, $0) })
        lock.unlock()
    }

    private func persist(_ snapshot: [FoliaStoredCookie]) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
