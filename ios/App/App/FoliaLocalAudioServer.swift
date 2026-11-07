import Foundation
import Darwin

// src/ios/App/App/FoliaLocalAudioServer.swift
// 本地音频流服务（127.0.0.1 随机端口）。
//
// WKWebView 的 <audio> 播不了 App 私有目录里的文件，也不接受 file:// 跨源；
// 安卓版的 LocalAudioServer 用 OkHttp + Range 解决，这里用同一套协议在 iOS 重放：
//   /audio/imported-<name>   本地导入副本
//   /remote-audio/<token>    带 Cookie/Referer 的远端音频转发（酷我/网易等 CDN 不下发 CORS）
// 必须支持 Range、HEAD 与 OPTIONS，否则 <audio> 会在拖动进度或 CORS 预检时失败。
//
// 远端转发是流式的（URLSessionDataDelegate 逐块写回），不是「整首下载完再回」：
// 后者会让点击播放后长时间没有首字节，听感上就是「按了没反应」。

final class FoliaLocalAudioServer {
    static let shared = FoliaLocalAudioServer()

    private let stateLock = NSLock()
    private var listenerFD: Int32 = -1
    private var boundPort: UInt16 = 0
    private var remoteURLs: [String: String] = [:]
    private var remoteRequestHeaders: [String: [String: String]] = [:]
    private var remoteOrder: [String] = []
    private let acceptQueue = DispatchQueue(label: "top.izuna.foliamajor.audio.accept")
    private let connectionQueue = DispatchQueue(label: "top.izuna.foliamajor.audio.conn", attributes: .concurrent)

    private static let remoteHostSuffixes = ["kuwo.cn", "music.126.net"]
    private static let remoteUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private init() {}

    /// 导入副本目录：Documents/imported-audio。
    func importedAudioDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("imported-audio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// 启动（或复用）服务，返回监听端口。
    func start() throws -> UInt16 {
        stateLock.lock()
        defer { stateLock.unlock() }
        if listenerFD >= 0 && boundPort > 0 {
            return boundPort
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "FoliaLocalAudioServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "socket() failed"]) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "FoliaLocalAudioServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "bind() failed"])
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw NSError(domain: "FoliaLocalAudioServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "listen() failed"])
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        let port = UInt16(bigEndian: boundAddress.sin_port)
        guard port > 0 else {
            close(fd)
            throw NSError(domain: "FoliaLocalAudioServer", code: 4, userInfo: [NSLocalizedDescriptionKey: "getsockname() failed"])
        }

        listenerFD = fd
        boundPort = port
        acceptQueue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        return port
    }

    /// 把一个远端音频地址挂到本地服务上，返回可交给 <audio> 的本地 URL。
    func registerRemoteAudio(_ value: String, headers: [String: String]?, allowAnyHost: Bool) throws -> String {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" || allowAnyHost else {
            throw NSError(domain: "FoliaLocalAudioServer", code: 5, userInfo: [NSLocalizedDescriptionKey: "Unsupported remote audio url"])
        }
        let host = (url.host ?? "").lowercased()
        let allowed = allowAnyHost || Self.remoteHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
        guard allowed else {
            throw NSError(domain: "FoliaLocalAudioServer", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unsupported remote audio host"])
        }
        let port = try start()
        let token = Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        stateLock.lock()
        remoteURLs.removeValue(forKey: token)
        remoteURLs[token] = value
        remoteRequestHeaders.removeValue(forKey: token)
        if let headers, !headers.isEmpty {
            remoteRequestHeaders[token] = headers
        }
        remoteOrder.removeAll(where: { $0 == token })
        remoteOrder.append(token)
        while remoteOrder.count > 128 {
            let oldest = remoteOrder.removeFirst()
            remoteURLs.removeValue(forKey: oldest)
            remoteRequestHeaders.removeValue(forKey: oldest)
        }
        stateLock.unlock()
        return "http://127.0.0.1:\(port)/remote-audio/\(token)"
    }

    // MARK: - HTTP 服务

    private func acceptLoop(fd: Int32) {
        while true {
            var clientAddress = sockaddr()
            var clientLength = socklen_t(MemoryLayout<sockaddr>.size)
            let client = accept(fd, &clientAddress, &clientLength)
            if client < 0 {
                if errno == EINTR { continue }
                break
            }
            connectionQueue.async { [weak self] in
                self?.handle(fd: client)
            }
        }
    }

    private func handle(fd: Int32) {
        guard let request = readRequest(fd: fd) else {
            close(fd)
            return
        }
        let method = request.method.uppercased()
        if method == "OPTIONS" {
            _ = foliaWriteAll(fd: fd, data: Self.corsPreflightResponse())
            close(fd)
            return
        }
        if request.path.hasPrefix("/remote-audio/") {
            let token = String(request.path.dropFirst("/remote-audio/".count))
            if let target = remoteURL(for: token) {
                // 连接的所有权交给 relay，由它在 URLSession 完成/失败时关闭。
                startRemoteRelay(fd: fd, method: method, target: target, token: token, headers: request.headers)
                return
            }
            _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
            close(fd)
            return
        }
        guard request.path.hasPrefix("/audio/") else {
            _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
            close(fd)
            return
        }
        let token = String(request.path.dropFirst("/audio/".count)).removingPercentEncoding ?? String(request.path.dropFirst("/audio/".count))
        if token.hasPrefix("imported-") {
            guard !token.contains("/"), !token.contains("\\"), !token.contains("..") else {
                _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
                close(fd)
                return
            }
            let fileURL = importedAudioDirectory().appendingPathComponent(token)
            respondFile(fd: fd, method: method, fileURL: fileURL, headers: request.headers)
            close(fd)
            return
        }
        _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
        close(fd)
    }

    private func remoteURL(for token: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return remoteURLs[token]
    }

    private func remoteHeaders(for token: String) -> [String: String]? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return remoteRequestHeaders[token]
    }

    private func readRequest(fd: Int32) -> (method: String, path: String, headers: [String: String])? {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var received = Data()
        while received.count < 64 * 1024 {
            let count = buffer.withUnsafeMutableBytes { pointer in
                recv(fd, pointer.baseAddress, pointer.count, 0)
            }
            if count <= 0 { break }
            received.append(buffer, count: count)
            if received.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let headerEnd = received.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = received.subdata(in: 0..<headerEnd.lowerBound)
        guard let text = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        var path = String(parts[1])
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }
        return (String(parts[0]), path, headers)
    }

    private func respondFile(fd: Int32, method: String, fileURL: URL, headers: [String: String]) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
            return
        }
        let total = size.int64Value
        let mime = Self.mimeType(for: fileURL.lastPathComponent)
        let range = Self.parseRange(headers["range"], total: total)
        let start = range?.start ?? 0
        let end = range?.end ?? (total - 1)
        let length = end - start + 1
        let partial = range != nil

        var header = partial
            ? "HTTP/1.1 206 Partial Content\r\n"
            : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(mime)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        header += "Content-Length: \(length)\r\n"
        if partial {
            header += "Content-Range: bytes \(start)-\(end)/\(total)\r\n"
        }
        header += Self.corsHeaders
        header += "Connection: close\r\n\r\n"
        guard foliaWriteAll(fd: fd, data: Data(header.utf8)) else { return }
        guard method == "GET" else { return }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(start))
        var remaining = length
        while remaining > 0 {
            let chunk = try? handle.read(upToCount: Int(min(Int64(64 * 1024), remaining)))
            guard let chunk, !chunk.isEmpty else { break }
            guard foliaWriteAll(fd: fd, data: chunk) else { return }
            remaining -= Int64(chunk.count)
        }
    }

    private func startRemoteRelay(fd: Int32, method: String, target: String, token: String, headers: [String: String]) {
        guard let targetURL = URL(string: target) else {
            _ = foliaWriteAll(fd: fd, data: Self.statusResponse(404, "Not Found"))
            close(fd)
            return
        }
        var request = URLRequest(url: targetURL)
        request.httpMethod = method == "HEAD" ? "HEAD" : "GET"
        request.setValue(Self.remoteUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.referer(for: targetURL), forHTTPHeaderField: "Referer")
        if let extra = remoteHeaders(for: token) {
            extra.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        if let range = headers["range"], range.hasPrefix("bytes=") {
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        let relay = FoliaRemoteAudioRelay(fd: fd, isHead: method == "HEAD")
        relay.start(request)
    }

    private static func parseRange(_ header: String?, total: Int64) -> (start: Int64, end: Int64)? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startText = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let endText = String(parts[1]).trimmingCharacters(in: .whitespaces)
        var start: Int64 = 0
        var end: Int64 = total - 1
        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            start = max(0, total - suffix)
        } else {
            guard let parsed = Int64(startText) else { return nil }
            start = max(0, min(parsed, total - 1))
            if !endText.isEmpty, let parsedEnd = Int64(endText) {
                end = max(start, min(parsedEnd, total - 1))
            }
        }
        return (start, end)
    }

    private static func referer(for url: URL) -> String {
        let host = (url.host ?? "").lowercased()
        if host == "music.126.net" || host.hasSuffix(".music.126.net") {
            return "https://music.163.com/"
        }
        return "https://www.kuwo.cn/"
    }

    private static func mimeType(for fileName: String) -> String {
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

    private static let corsHeaders =
        "Access-Control-Allow-Origin: *\r\n"
        + "Access-Control-Allow-Headers: range, content-range, content-length\r\n"
        + "Access-Control-Expose-Headers: range, content-range, content-length, accept-ranges\r\n"

    private static func corsPreflightResponse() -> Data {
        let response = "HTTP/1.1 204 No Content\r\n"
            + corsHeaders
            + "Access-Control-Allow-Methods: GET, HEAD, OPTIONS\r\n"
            + "Access-Control-Max-Age: 86400\r\n"
            + "Content-Length: 0\r\nConnection: close\r\n\r\n"
        return Data(response.utf8)
    }

    private static func statusResponse(_ status: Int, _ reason: String) -> Data {
        let response = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: 0\r\n"
            + corsHeaders
            + "Connection: close\r\n\r\n"
        return Data(response.utf8)
    }
}

/// 逐块把上游音频写回本地 socket；首个响应头一到就先发出去，避免「点了没反应」。
private final class FoliaRemoteAudioRelay: NSObject, URLSessionDataDelegate {
    private let fd: Int32
    private let isHead: Bool
    private var session: URLSession?
    private var headersSent = false
    private var finished = false
    private let finishLock = NSLock()

    init(fd: Int32, isHead: Bool) {
        self.fd = fd
        self.isHead = isHead
    }

    func start(_ request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 3600
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let queue = OperationQueue()
        queue.name = "top.izuna.foliamajor.audio.relay"
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            _ = foliaWriteAll(fd: fd, data: FoliaLocalAudioServerRelaySupport.statusResponse(502, "Upstream Error"))
            finish()
            return
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "audio/mpeg"
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        let isPartial = http.statusCode == 206 || contentRange != nil
        var header = isPartial ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Accept-Ranges: bytes\r\n"
        if http.expectedContentLength >= 0 {
            header += "Content-Length: \(http.expectedContentLength)\r\n"
        }
        if let contentRange {
            header += "Content-Range: \(contentRange)\r\n"
        }
        header += FoliaLocalAudioServerRelaySupport.corsHeaders
        header += "Connection: close\r\n\r\n"
        guard foliaWriteAll(fd: fd, data: Data(header.utf8)) else {
            completionHandler(.cancel)
            finish()
            return
        }
        headersSent = true
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !isHead, !data.isEmpty else { return }
        if !foliaWriteAll(fd: fd, data: data) {
            session.invalidateAndCancel()
            finish()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !headersSent && error != nil {
            _ = foliaWriteAll(fd: fd, data: FoliaLocalAudioServerRelaySupport.statusResponse(502, "Upstream Error"))
        }
        finish()
    }

    private func finish() {
        finishLock.lock()
        if finished {
            finishLock.unlock()
            return
        }
        finished = true
        finishLock.unlock()
        close(fd)
        session?.invalidateAndCancel()
        session = nil
    }
}

private enum FoliaLocalAudioServerRelaySupport {
    static let corsHeaders =
        "Access-Control-Allow-Origin: *\r\n"
        + "Access-Control-Allow-Headers: range, content-range, content-length\r\n"
        + "Access-Control-Expose-Headers: range, content-range, content-length, accept-ranges\r\n"

    static func statusResponse(_ status: Int, _ reason: String) -> Data {
        let response = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain\r\n"
            + "Content-Length: 0\r\n"
            + corsHeaders
            + "Connection: close\r\n\r\n"
        return Data(response.utf8)
    }
}

/// 写完整块到 socket；对端断开时返回 false。
private func foliaWriteAll(fd: Int32, data: Data) -> Bool {
    var sent = 0
    let total = data.count
    while sent < total {
        let written = data.withUnsafeBytes { pointer -> Int in
            let base = pointer.baseAddress!.advanced(by: sent)
            return send(fd, base, total - sent, 0)
        }
        if written <= 0 { return false }
        sent += written
    }
    return true
}
