import Foundation

/// Swift face of the Rust engine. The engine serves the SS Remote API on 127.0.0.1:8787 for the
/// Saved Scroll brain (Scriptable), and does the touching.
final class Engine: ObservableObject {
    static let shared = Engine()
    static let port: UInt16 = 8787

    @Published var started = false
    @Published var status: [String: Any] = [:]
    @Published var message = ""

    var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("pairing.plist")
    }
    var hasPairing: Bool { FileManager.default.fileExists(atPath: pairingURL.path) }

    /// The engine's API key. It survives restarts, so the brain stays connected after reinstalls and renewals.
    var token: String {
        let key = "engine-token"
        if let t = UserDefaults.standard.string(forKey: key), !t.isEmpty { return t }
        let t = (0..<24).map { _ in String("abcdefghijkmnpqrstuvwxyz23456789".randomElement()!) }.joined()
        UserDefaults.standard.set(t, forKey: key)
        return t
    }

    var busy: Bool { (status["busy"] as? Bool) == true }

    /// Hands-free landing check (D-41). After each leg the engine: opens a top-row video, Share, Copy link,
    /// swipes back from the left edge to the grid, taps the floating window (controls) and its "back to app"
    /// button. The app then reads the copied link (background apps can't: L-25) and starts the next leg
    /// (Session.autoCheckIfDue). Positions measured on the user's phone 2026-11-06 (1206x2622 screen; OP-54,
    /// OP-56). Breaks if the floating window was dragged away from the top centre.
    static let checkMacro: String = {
        func p(_ x: Double, _ y: Double) -> String { "\(Int(x * 65535 / 1206)) \(Int(y * 65535 / 2622))" }
        return ["W 1500",                                  // let the grid stop gliding (back-up legs: OP-57)
                "T \(p(200, 950))", "W 1800",              // top-row video
                "T \(p(1113, 2057))", "W 1200",            // Share
                "T \(p(327, 2168))", "W 900",              // Copy link
                "D \(p(2, 1311)) \(p(844, 1311)) 300", "W 1200",   // back to the grid (left-edge swipe)
                "T \(p(600, 380))", "W 800",               // floating window: show its controls
                "T \(p(1105, 250))"].joined(separator: ";") // "back to app"
    }()

    /// On by default; Settings can turn it off (then checks are manual: Copy link › Check where I landed).
    var autoCheckOn: Bool {
        get { (UserDefaults.standard.object(forKey: "auto-check") as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "auto-check"); Task { await installAutoCheck() } }
    }

    /// Hands the check macro to the engine (it runs it after each dive while auto-check is on).
    func installAutoCheck() async {
        for _ in 0..<5 {
            let r = await api("/macro", ["s": Engine.checkMacro, "save": "check"])
            if (r["ok"] as? Bool) == true { break }
            try? await Task.sleep(nanoseconds: 500_000_000)       // the engine's server may still be starting
        }
        let r = await api("/autocheck", ["on": autoCheckOn ? "1" : "0"])
        ssLog.notice("auto-check installed: on=\(autoCheckOn) engine=\(r["autoCheck"] ?? "?") macro=\(r["hasCheckMacro"] ?? "?")")
    }

    /// Direct engine calls for the floating window's quick actions (no brain involved).
    @discardableResult
    func api(_ path: String, _ params: [String: String] = [:]) async -> [String: Any] {
        var c = URLComponents(string: "http://127.0.0.1:\(Engine.port)\(path)")!
        if !params.isEmpty { c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: c.url!, timeoutInterval: 3)
        req.setValue(token, forHTTPHeaderField: "X-Token")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ["ok": false] }
        return j
    }

    /// A few swipes down (positive) or up (negative): fine-tuning from the floating window's skip buttons.
    func nudge(_ swipes: Int) async {
        await api("/dive", ["n": String(abs(swipes)), "iv": "700", "dy": swipes > 0 ? "400" : "-400", "dur": "180", "pn": "0", "check": "0"])
    }

    private func call(_ f: () -> UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let p = f() else { return [:] }
        defer { ss_string_free(p) }
        let data = Data(String(cString: p).utf8)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Starts the engine (once). It reads the pairing record when it first touches the phone, so pairing
    /// later (in the app) works without a restart. Demo mode (simulated touches): launch with -demo.
    func start() {
        let demo = ProcessInfo.processInfo.arguments.contains("-demo")
        let path = demo ? "" : pairingURL.path
        let token = self.token
        let r = path.withCString { p in token.withCString { t in call { ss_engine_start(p, Engine.port, t) } } }
        started = (r["ok"] as? Bool) == true
        message = !started ? "Couldn't start: \(r["error"] ?? "unknown")"
                : demo ? "Demo mode: touches are simulated."
                : hasPairing ? "Ready."
                : "One-time setup: pair this iPhone (Settings)."
    }

    /// Only publish when something changed, so the screen doesn't redraw twice a second for nothing.
    func refresh() {
        let s = call { ss_engine_status() }
        if !NSDictionary(dictionary: s).isEqual(to: status) { status = s }
    }
    func stopDive() { ss_engine_stop_dive() }

    func importPairing(from url: URL) {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        do {
            if FileManager.default.fileExists(atPath: pairingURL.path) { try FileManager.default.removeItem(at: pairingURL) }
            try FileManager.default.copyItem(at: url, to: pairingURL)
            message = "Pairing record saved."
            objectWillChange.send()
        } catch {
            message = "Couldn't import: \(error.localizedDescription)"
        }
    }

    // Overlay text
    var headline: String {
        let busy = (status["busy"] as? Bool) == true, checking = (status["checking"] as? Bool) == true
        let done = status["done"] as? Int ?? 0, planned = status["planned"] as? Int ?? 0
        let pairing = Pairing.shared
        if pairing.state == "code" && !pairing.code.isEmpty { return "Code \(pairing.code)" }
        if pairing.state == "waiting" { return "Pair in Settings…" }
        if checking { return "Checking where it landed…" }
        if busy {
            let pre = status["pre"] as? Int ?? 0, preDone = status["preDone"] as? Int ?? 0
            if pre > 0 && preDone < pre { return "Up to the top: \(preDone)/\(pre)" }
            return "Scrolling \(done)/\(planned)"
        }
        if let e = status["error"] as? String, !e.isEmpty { return "⚠︎ \(e.prefix(60))" }
        return (status["connected"] as? Bool) == true ? "Ready" : "Idle"
    }
}
