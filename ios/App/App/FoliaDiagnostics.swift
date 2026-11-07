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
        let entry: [String: Any] = [
            "at": Int(Date().timeIntervalSince1970 * 1000),
            "source": source,
            "thread": thread,
            "type": type,
            "message": message,
            "stack": stack,
        ]
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: entry),
                  let line = String(data: data, encoding: .utf8) else { return }
            let existing = (try? String(contentsOf: self.runtimeFile, encoding: .utf8)) ?? ""
            var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines.append(line)
            if lines.count > 20 {
                lines = Array(lines.suffix(20))
            }
            try? lines.joined(separator: "\n").write(to: self.runtimeFile, atomically: true, encoding: .utf8)
        }
    }

    func recordHeartbeat(_ payload: [String: Any]) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let text = String(data: data, encoding: .utf8) else { return }
            let previous = (try? String(contentsOf: self.heartbeatFile, encoding: .utf8)) ?? ""
            let combined = ["previous": previous, "last": text]
            if let combinedData = try? JSONSerialization.data(withJSONObject: combined) {
                try? combinedData.write(to: self.heartbeatFile, options: .atomic)
            }
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
            if let text = try? String(contentsOf: runtimeFile, encoding: .utf8) {
                let entries = text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> [String: Any]? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                }
                result["history"] = entries
            }
            if let data = try? Data(contentsOf: heartbeatFile),
               let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                if let last = object["last"] as? String {
                    result["heartbeat"] = last
                }
                if let previous = object["previous"] as? String {
                    result["previousHeartbeat"] = previous
                }
            }
        }
        return result
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
