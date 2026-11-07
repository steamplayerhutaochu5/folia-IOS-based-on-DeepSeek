import Foundation
import UIKit
import Capacitor
import WebKit
import UniformTypeIdentifiers

// src/ios/App/App/FoliaNativePlugin.swift
// FoliaNative 的 iOS 端实现。
//
// JS 侧的 services/nativeAndroidBridge.ts 用 window.Capacitor.Plugins.FoliaNative 调用原生，
// 因此插件名、方法名、参数与返回结构必须与安卓版 FoliaNativePlugin.java 对齐。
// 最小可用集：Cookie、HTTP 代理、文件导入、本地音频服务、锁屏媒体信息。
// 设备音乐库扫描（MediaStore）在 iOS 没有等价能力，scanLocalAudio 固定返回空数组。

@objc(FoliaNativePlugin)
public class FoliaNativePlugin: CAPPlugin, CAPBridgedPlugin, UIDocumentPickerDelegate {
    public let identifier = "FoliaNativePlugin"
    public let jsName = "FoliaNative"

    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "cookiesGetAll", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cookiesGet", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cookiesSet", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cookiesRemove", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cookiesRemoveBatch", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "httpRequest", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "scanLocalAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickAudioFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "pickAudioFolder", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "localAudioServerPort", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "registerRemoteAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteImportedAudio", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPlaybackDiagnostics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "exitApp", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "moveTaskToBack", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "shareTextFile", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "deleteDiagnosticFiles", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPhoneFitLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setKeepScreenOn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPhoneFitLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setAdaptiveLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getAdaptiveLayout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getDisplayCutout", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "updatePlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearPlaybackState", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getCrashDiagnostics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordPlaybackHeartbeat", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearCrashDiagnostics", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "recordRuntimeDiagnostic", returnType: CAPPluginReturnPromise),
    ]

    private enum PickerKind {
        case files
        case folder
    }

    private let importQueue = DispatchQueue(label: "top.izuna.foliamajor.import", qos: .userInitiated)
    private var pendingPickerCall: CAPPluginCall?
    private var pendingPickerKind: PickerKind = .files
    private var pickerOpen = false

    public override func load() {
        FoliaCookieJar.shared.attach(webViewCookieStore: bridge?.webView?.configuration.websiteDataStore.httpCookieStore)
        FoliaMediaSession.shared.plugin = self
        FoliaMediaSession.shared.configure()
    }

    // MARK: - Cookie

    @objc func cookiesGetAll(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? ""
        let domain = call.getString("domain") ?? ""
        let target = resolvedCookieURL(urlString: urlString, domain: domain)
        let cookies: [[String: Any]]
        if let target {
            cookies = FoliaCookieJar.shared.cookies(for: target).map(describeCookie)
        } else {
            cookies = FoliaCookieJar.shared.allCookies().map(describeCookie)
        }
        call.resolve(["cookies": cookies])
    }

    @objc func cookiesGet(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? "https://localhost/"
        let name = call.getString("name") ?? ""
        guard !name.isEmpty else {
            call.reject("Missing cookie name")
            return
        }
        guard let target = URL(string: urlString) else {
            call.resolve(["cookie": NSNull()])
            return
        }
        if let cookie = FoliaCookieJar.shared.cookies(for: target).first(where: { $0.name == name }) {
            call.resolve(["cookie": describeCookie(cookie)])
        } else {
            call.resolve(["cookie": NSNull()])
        }
    }

    @objc func cookiesSet(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? ""
        let name = call.getString("name") ?? ""
        guard !urlString.isEmpty, !name.isEmpty, let target = URL(string: urlString) else {
            call.reject("Cookie url and name are required")
            return
        }
        let value = call.getString("value") ?? ""
        let domain = (call.getString("domain") ?? "").isEmpty
            ? (target.host ?? "")
            : (call.getString("domain") ?? "")
        let path = (call.getString("path") ?? "").isEmpty ? "/" : (call.getString("path") ?? "/")
        let secure = call.getBool("secure", false)
        let expiration = call.getDouble("expirationDate")
        let cookie = FoliaStoredCookie(
            name: name,
            value: value,
            domain: domain,
            path: path,
            secure: secure,
            expiresAt: expiration
        )
        FoliaCookieJar.shared.set(cookie)
        call.resolve(["ok": true])
    }

    @objc func cookiesRemove(_ call: CAPPluginCall) {
        let urlString = call.getString("url") ?? ""
        let name = call.getString("name") ?? ""
        guard let target = URL(string: urlString), !name.isEmpty else {
            call.reject("Cookie url and name are required")
            return
        }
        FoliaCookieJar.shared.remove(url: target, name: name)
        call.resolve(["ok": true])
    }

    @objc func cookiesRemoveBatch(_ call: CAPPluginCall) {
        let entries = call.getArray("entries") ?? []
        var removed = 0
        for entry in entries {
            guard let object = entry as? [String: Any],
                  let urlString = object["url"] as? String,
                  let target = URL(string: urlString),
                  let name = object["name"] as? String, !name.isEmpty else { continue }
            FoliaCookieJar.shared.remove(url: target, name: name)
            removed += 1
        }
        call.resolve(["ok": true, "removed": removed])
    }

    // MARK: - 网络

    @objc func httpRequest(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url"), let target = URL(string: urlString) else {
            call.reject("Missing request url")
            return
        }
        let method = (call.getString("method") ?? "GET").uppercased()
        let redirect = call.getString("redirect") ?? "follow"
        let timeoutMs = call.getInt("timeoutMs") ?? 0
        let headers = call.getObject("headers") ?? [:]
        let bodyText = call.getString("bodyText") ?? ""
        let bodyBase64 = call.getString("bodyBase64") ?? ""

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeoutMs > 0 ? Double(timeoutMs) / 1000.0 : 45
        var hasExplicitCookie = false
        for (rawName, rawValue) in headers {
            let name = String(describing: rawName)
            if name.lowercased() == "cookie" { hasExplicitCookie = true }
            request.setValue(String(describing: rawValue), forHTTPHeaderField: name)
        }
        if !hasExplicitCookie, let cookieHeader = FoliaCookieJar.shared.cookieHeader(for: target) {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if !bodyBase64.isEmpty, let data = Data(base64Encoded: bodyBase64) {
            request.httpBody = data
        } else if !bodyText.isEmpty {
            request.httpBody = bodyText.data(using: .utf8)
        } else if requiresRequestBody(method) {
            request.httpBody = Data()
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = max(request.timeoutInterval, 45)
        let delegate = FoliaRedirectDelegate(followRedirects: redirect != "manual")
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            DispatchQueue.main.async {
                if let error {
                    call.reject(error.localizedDescription, nil, error)
                    return
                }
                guard let httpResponse = response as? HTTPURLResponse else {
                    call.reject("Invalid response")
                    return
                }
                let headerEntries = FoliaCookieJar.headerEntries(from: httpResponse)
                FoliaCookieJar.shared.store(
                    setCookieHeaders: FoliaCookieJar.setCookieValues(in: headerEntries),
                    for: target
                )
                let result: [String: Any] = [
                    "status": httpResponse.statusCode,
                    "headers": headerEntries,
                    "bodyBase64": (data ?? Data()).base64EncodedString(),
                ]
                call.resolve(result)
            }
        }.resume()
    }

    // MARK: - 本地音乐

    @objc func scanLocalAudio(_ call: CAPPluginCall) {
        // iOS 没有 MediaStore；本地音乐只走 Files 导入。
        call.resolve(["tracks": []])
    }

    @objc func pickAudioFiles(_ call: CAPPluginCall) {
        beginPicker(call, kind: .files)
    }

    @objc func pickAudioFolder(_ call: CAPPluginCall) {
        beginPicker(call, kind: .folder)
    }

    @objc func localAudioServerPort(_ call: CAPPluginCall) {
        do {
            let port = try FoliaLocalAudioServer.shared.start()
            call.resolve(["port": Int(port)])
        } catch {
            call.reject(error.localizedDescription, nil, error)
        }
    }

    @objc func registerRemoteAudio(_ call: CAPPluginCall) {
        guard let urlString = call.getString("url"), !urlString.isEmpty else {
            call.reject("Missing remote audio url")
            return
        }
        let headers = (call.getObject("headers")).map { object in
            object.reduce(into: [String: String]()) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        let allowAnyHost = call.getBool("allowAnyHost", false)
        do {
            let localURL = try FoliaLocalAudioServer.shared.registerRemoteAudio(
                urlString,
                headers: headers,
                allowAnyHost: allowAnyHost
            )
            call.resolve(["url": localURL])
        } catch {
            call.reject(error.localizedDescription, nil, error)
        }
    }

    @objc func deleteImportedAudio(_ call: CAPPluginCall) {
        let refs = (call.getArray("refs") ?? []).compactMap { $0 as? String }
        let directory = FoliaLocalAudioServer.shared.importedAudioDirectory()
        var deleted: [String] = []
        var failed: [String] = []
        for ref in refs {
            guard ref.hasPrefix("imported-"), !ref.contains("/"), !ref.contains("\\"), !ref.contains("..") else {
                failed.append(ref)
                continue
            }
            let target = directory.appendingPathComponent(ref)
            if !FileManager.default.fileExists(atPath: target.path) || (try? FileManager.default.removeItem(at: target)) != nil {
                deleted.append(ref)
            } else {
                failed.append(ref)
            }
        }
        call.resolve(["deleted": deleted, "failed": failed])
    }

    // MARK: - 播放与系统

    @objc func updatePlaybackState(_ call: CAPPluginCall) {
        FoliaMediaSession.shared.update(
            title: call.getString("title") ?? "",
            artist: call.getString("artist") ?? "",
            album: call.getString("album") ?? "",
            coverURL: call.getString("coverUrl") ?? "",
            playing: call.getBool("playing", false),
            positionMs: call.getDouble("position") ?? 0,
            durationMs: call.getDouble("duration") ?? 0
        )
        call.resolve()
    }

    @objc func clearPlaybackState(_ call: CAPPluginCall) {
        FoliaMediaSession.shared.clear()
        call.resolve()
    }

    @objc func getPlaybackDiagnostics(_ call: CAPPluginCall) {
        let result: [String: Any] = [
            "cover": "",
            "status": "none",
            "detail": "",
            "at": 0,
            "applied": false,
            "power": "ios",
        ]
        call.resolve(result)
    }

    @objc func exitApp(_ call: CAPPluginCall) {
        // iOS 不允许程序化退出；保留方法以兼容 JS 的调用约定。
        call.resolve()
    }

    @objc func moveTaskToBack(_ call: CAPPluginCall) {
        call.resolve()
    }

    @objc func shareTextFile(_ call: CAPPluginCall) {
        let rawName = call.getString("filename") ?? "folia-diagnostics.txt"
        let content = call.getString("content") ?? ""
        let title = call.getString("title") ?? "Folia diagnostics"
        guard let fileURL = FoliaDiagnostics.shared.writeExport(filename: rawName, content: content) else {
            call.reject("Could not write diagnostics file")
            return
        }
        DispatchQueue.main.async {
            guard let presenter = self.bridge?.viewController else {
                call.reject("No view controller available")
                return
            }
            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            presenter.present(controller, animated: true) {
                call.resolve()
            }
        }
    }

    @objc func deleteDiagnosticFiles(_ call: CAPPluginCall) {
        call.resolve(["deleted": FoliaDiagnostics.shared.deleteExports()])
    }

    @objc func getPhoneFitLayout(_ call: CAPPluginCall) {
        call.resolve(["enabled": false, "orientation": "portrait"])
    }

    @objc func setKeepScreenOn(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled", false)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = enabled
        }
        call.resolve(["enabled": enabled])
    }

    @objc func setPhoneFitLayout(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled", false)
        let orientation = call.getString("orientation") ?? "portrait"
        call.resolve(["enabled": enabled, "orientation": orientation])
    }

    @objc func setAdaptiveLayout(_ call: CAPPluginCall) {
        call.resolve(["enabled": call.getBool("enabled", false)])
    }

    @objc func getAdaptiveLayout(_ call: CAPPluginCall) {
        call.resolve(["enabled": false])
    }

    @objc func getDisplayCutout(_ call: CAPPluginCall) {
        call.resolve(["available": false])
    }

    @objc func getCrashDiagnostics(_ call: CAPPluginCall) {
        call.resolve(FoliaDiagnostics.shared.read())
    }

    @objc func recordPlaybackHeartbeat(_ call: CAPPluginCall) {
        let payload: [String: Any] = [
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "visualizer": call.getString("visualizer") ?? "unknown",
            "background": call.getString("background") ?? "unknown",
            "playing": call.getBool("playing", false),
            "visibility": call.getString("visibility") ?? "unknown",
            "foreground": UIApplication.shared.applicationState == .active,
            "screenOn": true,
        ]
        FoliaDiagnostics.shared.recordHeartbeat(payload)
        call.resolve()
    }

    @objc func recordRuntimeDiagnostic(_ call: CAPPluginCall) {
        FoliaDiagnostics.shared.recordRuntime(
            source: call.getString("source") ?? "webview",
            thread: call.getString("thread") ?? "webview",
            type: call.getString("type") ?? "error",
            message: call.getString("message") ?? "",
            stack: call.getString("stack") ?? ""
        )
        call.resolve()
    }

    @objc func clearCrashDiagnostics(_ call: CAPPluginCall) {
        FoliaDiagnostics.shared.clear()
        call.resolve()
    }

    // MARK: - 选择器

    private func beginPicker(_ call: CAPPluginCall, kind: PickerKind) {
        guard !pickerOpen else {
            call.reject("Audio picker is already open")
            return
        }
        let types: [UTType]
        switch kind {
        case .files:
            types = [.audio]
        case .folder:
            types = [.folder]
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: kind == .files)
        picker.allowsMultipleSelection = kind == .files
        picker.delegate = self
        pickerOpen = true
        pendingPickerCall = call
        pendingPickerKind = kind
        DispatchQueue.main.async {
            self.bridge?.viewController?.present(picker, animated: true)
        }
    }

    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finishPicker(urls: urls, cancelled: false)
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finishPicker(urls: [], cancelled: true)
    }

    private func finishPicker(urls: [URL], cancelled: Bool) {
        pickerOpen = false
        let call = pendingPickerCall
        let kind = pendingPickerKind
        pendingPickerCall = nil
        guard let call else { return }
        if cancelled || urls.isEmpty {
            call.resolve([
                "tracks": [],
                "cancelled": true,
                "picked": 0,
            ])
            return
        }
        importQueue.async { [weak self] in
            guard let self else { return }
            var files: [URL] = []
            switch kind {
            case .files:
                files = urls
            case .folder:
                for root in urls {
                    files.append(contentsOf: self.audioFiles(in: root))
                }
            }
            let port: UInt16
            do {
                port = try FoliaLocalAudioServer.shared.start()
            } catch {
                DispatchQueue.main.async { call.reject(error.localizedDescription, nil, error) }
                return
            }
            var tracks: [[String: Any]] = []
            var failures: [[String: Any]] = []
            for fileURL in files {
                do {
                    if let track = try self.importAudio(from: fileURL, port: port) {
                        tracks.append(track)
                    }
                } catch {
                    failures.append([
                        "uri": fileURL.absoluteString,
                        "message": error.localizedDescription,
                    ])
                }
            }
            let result: [String: Any] = [
                "tracks": tracks,
                "port": Int(port),
                "picked": files.count,
                "copied": tracks.count,
                "failures": failures,
                "resultCode": 1,
            ]
            DispatchQueue.main.async { call.resolve(result) }
        }
    }

    /// 复制一首音频进私有目录，返回与安卓版一致的 track 结构。
    private func importAudio(from source: URL, port: UInt16) throws -> [String: Any]? {
        let scoped = source.startAccessingSecurityScopedResource()
        defer {
            if scoped { source.stopAccessingSecurityScopedResource() }
        }
        let fileName = source.lastPathComponent
        guard !fileName.isEmpty else { return nil }
        let attributes = (try? FileManager.default.attributesOfItem(atPath: source.path)) ?? [:]
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let directory = FoliaLocalAudioServer.shared.importedAudioDirectory()
        let ref = stableImportedRef(fileName: fileName, size: fileSize)
        let target = directory.appendingPathComponent(ref)
        let targetAttributes = (try? FileManager.default.attributesOfItem(atPath: target.path)) ?? [:]
        let existingSize = (targetAttributes[.size] as? NSNumber)?.int64Value ?? -1
        if !FileManager.default.fileExists(atPath: target.path) || existingSize != fileSize {
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            try FileManager.default.copyItem(at: source, to: target)
        }
        let mime = mimeType(for: ref)
        return [
            "id": ref,
            "fileName": fileName,
            "fileSize": fileSize,
            "mimeType": mime,
            "url": "http://127.0.0.1:\(port)/audio/\(ref)",
        ]
    }

    private func audioFiles(in directory: URL) -> [URL] {
        let scoped = directory.startAccessingSecurityScopedResource()
        defer {
            if scoped { directory.stopAccessingSecurityScopedResource() }
        }
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return result }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            if isAudioFileName(fileURL.lastPathComponent) {
                result.append(fileURL)
            }
        }
        return result
    }

    private func stableImportedRef(fileName: String, size: Int64) -> String {
        var candidate = fileName.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
        if candidate.count > 60 {
            candidate = String(candidate.suffix(60))
        }
        let dot = candidate.lastIndex(of: ".")
        let base: String
        let ext: String
        if let dot {
            base = String(candidate[..<dot])
            ext = String(candidate[dot...])
        } else {
            base = candidate
            ext = ""
        }
        let stamp = String(fnv1aHash("\(fileName):\(size)"), radix: 16)
        return "imported-\(base)-\(stamp)\(ext)"
    }

    private func fnv1aHash(_ text: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }

    private func isAudioFileName(_ fileName: String) -> Bool {
        let lower = fileName.lowercased()
        let extensions = ["mp3", "flac", "wav", "m4a", "aac", "ogg", "opus", "ape", "wma"]
        return extensions.contains { lower.hasSuffix(".\($0)") }
    }

    private func mimeType(for fileName: String) -> String {
        switch (fileName as NSString).pathExtension.lowercased() {
        case "flac": return "audio/flac"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "oga": return "audio/ogg"
        case "opus": return "audio/opus"
        case "aac": return "audio/aac"
        case "ape": return "audio/ape"
        case "wma": return "audio/x-ms-wma"
        default: return "audio/mpeg"
        }
    }

    // MARK: - 工具

    private func resolvedCookieURL(urlString: String, domain: String) -> URL? {
        if !urlString.isEmpty {
            return URL(string: urlString)
        }
        guard !domain.isEmpty else { return URL(string: "https://localhost/") }
        let host = domain
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return URL(string: "https://\(host)/")
    }

    private func describeCookie(_ cookie: FoliaStoredCookie) -> [String: Any] {
        [
            "name": cookie.name,
            "value": cookie.value,
            "domain": cookie.domain,
            "path": cookie.path,
            "secure": cookie.secure,
            "httpOnly": false,
            "expirationDate": cookie.expiresAt ?? 0,
        ]
    }

    private func requiresRequestBody(_ method: String) -> Bool {
        ["POST", "PUT", "PATCH", "PROPPATCH", "REPORT"].contains(method)
    }
}

/// 只负责阻止 manual 模式下的重定向；URLSession 默认会自动跟随。
final class FoliaRedirectDelegate: NSObject, URLSessionTaskDelegate {
    private let followRedirects: Bool

    init(followRedirects: Bool) {
        self.followRedirects = followRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(followRedirects ? request : nil)
    }
}
