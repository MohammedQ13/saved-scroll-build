import Foundation
import JavaScriptCore

/// The Saved Scroll brain inside the app: the same core.js, navigator.js and SavedScroll.js that ran in
/// Scriptable, plus Brain/bridge.js, in JavaScriptCore. All JS work happens on one serial queue.
/// The JS side is simulated in Node by app/ios/Brain/bridge.test.js (same wrapper, fake native layer).
final class Brain {
    static let shared = Brain()
    private let queue = DispatchQueue(label: "savedscroll.brain")
    private var ctx: JSContext?
    private var lastError = ""

    /// Brain files (index.txt, state.json): private to the app.
    var dataDir: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("brain") }
    /// Imported TikTok exports (also visible in Files › On My iPhone › Saved Scroll › Exports).
    var exportsDir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Exports") }

    private func file(_ name: String) -> URL {
        let d = dataDir.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: d.path) { return d }
        let e = exportsDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: e.path) ? e : d
    }

    private static let modules = ["core", "navigator", "navigator-v2", "SavedScroll"]

    private func appendRun(_ line: String) {
        let url = exportsDir.deletingLastPathComponent().appendingPathComponent("ss-runs.jsonl")
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try data.write(to: url, options: .atomic)
            } else {
                let file = try FileHandle(forWritingTo: url)
                defer { try? file.close() }
                try file.seekToEnd()
                try file.write(contentsOf: data)
            }
        } catch {
            ssLog.notice("Could not write run log: \(error.localizedDescription)")
        }
    }

    /// Builds the JS context once (on `queue`).
    private func context() -> JSContext? {
        if let ctx { return ctx }
        guard let c = JSContext() else { return nil }
        c.exceptionHandler = { [weak self] _, ex in self?.lastError = ex?.toString() ?? "JS error" }
        let fm = FileManager.default
        try? fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        let native = JSValue(newObjectIn: c)!
        let read: @convention(block) (String) -> Any? = { [unowned self] name in
            try? String(contentsOf: self.file(name), encoding: .utf8)
        }
        let write: @convention(block) (String, String) -> Void = { [unowned self] name, text in
            try? text.write(to: self.dataDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let newestExport: @convention(block) () -> Any? = { [unowned self] in
            let items = (try? fm.contentsOfDirectory(at: self.exportsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let exports = items.filter { ["json", "txt"].contains($0.pathExtension.lowercased()) }
            let newest = exports.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da < db
            }
            return newest?.lastPathComponent
        }
        let http: @convention(block) (String, String, String, Double) -> JSValue = { [unowned self] method, urlString, headersJson, timeout in
            let current = JSContext.current()!
            return JSValue(newPromiseIn: current) { resolve, reject in
                guard let url = URL(string: urlString) else { reject?.call(withArguments: ["bad url"]); return }
                var req = URLRequest(url: url, timeoutInterval: max(0.5, timeout))
                req.httpMethod = method
                if let d = headersJson.data(using: .utf8), let h = try? JSONSerialization.jsonObject(with: d) as? [String: String] {
                    for (k, v) in h { req.setValue(v, forHTTPHeaderField: k) }
                }
                URLSession.shared.dataTask(with: req) { data, resp, err in
                    self.queue.async {
                        if let err { reject?.call(withArguments: [err.localizedDescription]); return }
                        let r = resp as? HTTPURLResponse
                        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                        let payload: [String: Any] = ["status": r?.statusCode ?? 0, "url": r?.url?.absoluteString ?? urlString, "body": body]
                        resolve?.call(withArguments: [payload])
                    }
                }.resume()
            }!
        }
        let token: @convention(block) () -> String = { Engine.shared.token }
        let now: @convention(block) () -> Double = { Date().timeIntervalSince1970 * 1000 }
        let logRun: @convention(block) (String) -> Void = { [unowned self] in self.appendRun($0) }
        native.setObject(unsafeBitCast(read, to: AnyObject.self), forKeyedSubscript: "read" as NSString)
        native.setObject(unsafeBitCast(write, to: AnyObject.self), forKeyedSubscript: "write" as NSString)
        native.setObject(unsafeBitCast(newestExport, to: AnyObject.self), forKeyedSubscript: "newestExport" as NSString)
        native.setObject(unsafeBitCast(http, to: AnyObject.self), forKeyedSubscript: "http" as NSString)
        native.setObject(unsafeBitCast(token, to: AnyObject.self), forKeyedSubscript: "token" as NSString)
        native.setObject(unsafeBitCast(now, to: AnyObject.self), forKeyedSubscript: "now" as NSString)
        native.setObject(unsafeBitCast(logRun, to: AnyObject.self), forKeyedSubscript: "logRun" as NSString)
        c.setObject(native, forKeyedSubscript: "native" as NSString)
        c.evaluateScript("var __mods = {};")

        // Same wrapper as bridge.test.js: JavaScriptCore has no require/module.
        for name in Brain.modules + ["bridge"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else { lastError = "missing \(name).js"; return nil }
            let code = name == "bridge" ? src
                : "(function(){var module={exports:{}};\n\(src)\n;__mods[\"\(name)\"]=module.exports;})();"
            c.evaluateScript(code, withSourceURL: url)
        }
        ctx = c
        return c
    }

    /// Runs one brain command, e.g. ["cmd": "calendar"], and returns its JSON result.
    func run(_ cmd: [String: Any]) async -> [String: Any] {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any], Never>) in
            queue.async {
                var finished = false
                let finish: ([String: Any]) -> Void = { r in if !finished { finished = true; cont.resume(returning: r) } }
                guard let c = self.context(), let bridge = c.objectForKeyedSubscript("SSBridge"), !bridge.isUndefined,
                      let data = try? JSONSerialization.data(withJSONObject: cmd), let text = String(data: data, encoding: .utf8) else {
                    finish(["ok": false, "text": "The brain didn't load: \(self.lastError)"]); return
                }
                let onOK: @convention(block) (String) -> Void = { s in
                    finish((try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any]) ?? ["ok": false, "text": "bad brain reply"])
                }
                let onErr: @convention(block) (JSValue) -> Void = { e in finish(["ok": false, "text": "Brain error: \(e.toString() ?? "")"]) }
                self.lastError = ""
                let promise = bridge.invokeMethod("run", withArguments: [text])
                guard let promise, !promise.isUndefined else { finish(["ok": false, "text": "Brain error: \(self.lastError)"]); return }
                promise.invokeMethod("then", withArguments: [JSValue(object: unsafeBitCast(onOK, to: AnyObject.self), in: c)!,
                                                              JSValue(object: unsafeBitCast(onErr, to: AnyObject.self), in: c)!])
            }
        }
    }

    /// Copies a TikTok export the user picked into Exports, then imports it.
    func importExport(from url: URL) async -> [String: Any] {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let fm = FileManager.default
        try? fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        let dest = exportsDir.appendingPathComponent(url.lastPathComponent)
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: url, to: dest) } catch { return ["ok": false, "text": "Couldn't copy the file: \(error.localizedDescription)"] }
        return await run(["cmd": "import"])
    }
}
