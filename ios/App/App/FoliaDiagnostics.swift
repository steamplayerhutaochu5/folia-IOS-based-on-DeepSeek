import Foundation

// src/ios/App/App/FoliaDiagnostics.swift
// 诊断文件的 iOS 落地。
//
// JS 侧的「复制诊断数据」会调用原生 getCrashDiagnostics / recordRuntimeDiagnostic；
// 安卓版写 logcat 与私有缓存目录，这里落到 Documents/diagnostics：
//   runtime.jsonl   最近 20 条 WebView 错误
//   heartbeat.json  最近两次播放心跳
//   <export>.txt    settings 里导出的报告正文

final class FoliaDiagnostics {
    static let shared = FoliaDiagnostics()

    private let queue = DispatchQueue(label: "top.izuna.foliamajor.diagnostics")
    private let fileManager = FileManager.default

    private init() {}

    private var directory: URL {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let target = documents.appendingPathComponent("diagnostics", isDirectory: true)
        if !fileManager.fileExists(atPath: target.path) {
            try? fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return target
    }

    private var runtimeFile: URL { directory.appendingPathComponent("runtime.jsonl") }
    private var heartbeatFile: URL { directory.appendingPathComponent("heartbeat.json") }

    func recordRuntime(source: String, thread: String, type: String, message: String, stack: String) {
        // 与 JS 侧 normalizeEntry 的上限一致；原生不做截断时，一段超长堆栈会让
        // JSONSerialization 的字符串分配直接 OOM（abort）。
        let entry: [String: Any] = [
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "source": String(source.prefix(80)),
            "thread": String(thread.prefix(120)),
            "type": String(type.prefix(240)),
            "message": String(message.prefix(2_000)),
            "stack": String(stack.prefix(12_000)),
        ]
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  data.count <= 32 * 1024,
                  let line = String(data: data, encoding: .utf8) else { return }
            let existingData = self.limitedFileData(self.runtimeFile, maxBytes: 512 * 1024)
            let existing = existingData.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var lines = existing.split(separator: "\n", omittingEmptySubsequences: true)
                .map { String($0.prefix(24 * 1024)) }
            lines.append(line)
            if lines.count > 20 {
                lines = Array(lines.suffix(20))
            }
            let joined = lines.joined(separator: "\n")
            try? String(joined.prefix(256 * 1024)).write(to: self.runtimeFile, atomically: true, encoding: .utf8)
        }
    }

    func recordHeartbeat(_ payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  data.count <= 16 * 1024,
                  let text = String(data: data, encoding: .utf8) else { return }
            // 旧实现把整个 heartbeat.json 当成新的 previous 再写回去，文件会随每次心跳
            // 指数级嵌套；播放几分钟后 JSONSerialization 就因内存不足 abort（真机崩溃日志
            // 的故障线程正是 top.izuna.foliamajor.diagnostics）。这里只取上一次的 last 字段。
            var previous = ""
            if let existing = self.limitedFileData(self.heartbeatFile, maxBytes: 256 * 1024),
               let object = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
               let last = object["last"] as? String {
                previous = String(last.prefix(16 * 1024))
            }
            let combined: [String: Any] = [
                "previous": previous,
                "last": String(text.prefix(8 * 1024)),
            ]
            guard let combinedData = try? JSONSerialization.data(withJSONObject: combined),
                  combinedData.count <= 64 * 1024 else { return }
            try? combinedData.write(to: self.heartbeatFile, options: .atomic)
        }
    }

    func read() -> [String: Any] {
        var result: [String: Any] = [
            "history": [],
            "heartbeat": "",
            "previousHeartbeat": "",
            "serviceHeartbeat": "",
            "previousServiceHeartbeat": "",
        ]
        queue.sync {
            if let data = limitedFileData(runtimeFile, maxBytes: 512 * 1024),
               let text = String(data: data, encoding: .utf8) {
                let entries = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> [String: Any]? in
                    guard let lineData = line.data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any]
                }
                result["history"] = entries
            }
            if let data = limitedFileData(heartbeatFile, maxBytes: 256 * 1024),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let last = object["last"] as? String {
                    result["heartbeat"] = String(last.prefix(16 * 1024))
                }
                if let previous = object["previous"] as? String {
                    result["previousHeartbeat"] = String(previous.prefix(16 * 1024))
                }
            }
        }
        return result
    }

    /// 读取小文件；超过上限的文件视为损坏（旧版心跳文件会指数膨胀），直接丢弃。
    private func limitedFileData(_ url: URL, maxBytes: Int) -> Data? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        if size.int64Value > Int64(maxBytes) {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url)
    }

    func clear() {
        queue.sync {
            try? fileManager.removeItem(at: runtimeFile)
            try? fileManager.removeItem(at: heartbeatFile)
        }
    }

    /// 写入「导出诊断数据」的正文，返回文件 URL。
    func writeExport(filename: String, content: String) -> URL? {
        let safeName = sanitized(filename)
        let target = directory.appendingPathComponent(safeName)
        do {
            try content.write(to: target, atomically: true, encoding: .utf8)
            return target
        } catch {
            return nil
        }
    }

    /// 删除缓存目录下的导出 txt，返回删除数量。
    func deleteExports() -> Int {
        guard let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var deleted = 0
        for file in files where file.pathExtension.lowercased() == "txt" {
            if (try? fileManager.removeItem(at: file)) != nil {
                deleted += 1
            }
        }
        return deleted
    }

    private func sanitized(_ rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
        if name.isEmpty || name.contains("..") {
            name = "folia-diagnostics"
        }
        if !name.lowercased().hasSuffix(".txt") {
            name += ".txt"
        }
        return name
    }
}
