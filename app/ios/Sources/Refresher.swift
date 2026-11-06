import BackgroundTasks
import Foundation
import Security
import UserNotifications

/// Keeps the app signed forever. Free Apple ID signing lasts 7 days; we re-sign and reinstall ourselves
/// (engine refresh.rs) when 3 or fewer days are left:
///   1. in the background (iOS runs it overnight, usually while charging), and
///   2. when the app opens with 1 day or less left (last resort).
/// Needs: the Apple ID saved once (Keychain), LocalDevVPN on, internet. iOS closes the app when the new copy installs.
final class Refresher: ObservableObject {
    static let shared = Refresher()
    static let taskID = "savedscroll.refresh"
    static let refreshWhenDaysLeft = 3.0

    @Published var state = "idle"        // idle | login | need_code | signing | installing | done | failed
    @Published var progress = 0
    @Published var detail = ""
    @Published var error = ""

    private var timer: Timer?

    // MARK: account (Keychain)
    var email: String { get { keychain("email") ?? "" } }
    var hasAccount: Bool { !(keychain("email") ?? "").isEmpty && !(keychain("password") ?? "").isEmpty }

    func saveAccount(email: String, password: String) {
        setKeychain("email", email.trimmingCharacters(in: .whitespaces))
        setKeychain("password", password)
    }

    // MARK: expiry
    /// When this copy's provisioning profile runs out (nil in the simulator / unsigned builds).
    lazy var expiresAt: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["ExpirationDate"] as? Date
    }()

    var daysLeft: Double? { expiresAt.map { $0.timeIntervalSinceNow / 86_400 } }
    var due: Bool { (daysLeft ?? 99) <= Refresher.refreshWhenDaysLeft }

    var summary: String {
        guard let d = daysLeft, let at = expiresAt else { return "Signing date unknown (not installed by Saved Scroll)" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
        return d < 0 ? "Expired \(f.string(from: at))" : String(format: "Signed until %@ (%.1f days)", f.string(from: at), d)
    }

    // MARK: scheduling
    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Refresher.taskID, using: nil) { task in
            self.handle(task as! BGProcessingTask)
        }
    }

    /// Ask iOS to wake us when a refresh is due (it picks the exact time, usually overnight while charging).
    func schedule() {
        let r = BGProcessingTaskRequest(identifier: Refresher.taskID)
        r.requiresNetworkConnectivity = true
        r.requiresExternalPower = false
        if let at = expiresAt { r.earliestBeginDate = max(Date(), at.addingTimeInterval(-Refresher.refreshWhenDaysLeft * 86_400)) }
        try? BGTaskScheduler.shared.submit(r)
    }

    private func handle(_ task: BGProcessingTask) {
        schedule()                                   // next one, in case this run fails
        guard due, hasAccount else { task.setTaskCompleted(success: true); return }
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        start()
        // Poll until it finishes (on success iOS closes us while installing, which also ends the task).
        Task {
            for _ in 0..<600 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run { self.poll() }
                if ["done", "failed"].contains(state) { break }
            }
            if state == "failed" { warnIfUrgent() }
            task.setTaskCompleted(success: state == "done")
        }
    }

    var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("signing")
    }

    /// The laptop installer (sscore, via `sslab app install`) drops its signing data into Documents/.signing:
    /// the Apple login identity and the certificate. Moving it here means renewals reuse the same certificate
    /// and need no new 2FA code. `account.json` pre-fills the Apple ID email.
    @Published var suggestedEmail = ""
    func importFromLaptop() {
        let fm = FileManager.default
        let drop = Engine.shared.pairingURL.deletingLastPathComponent().appendingPathComponent(".signing")
        guard fm.fileExists(atPath: drop.path) else { return }
        try? fm.createDirectory(at: storageURL, withIntermediateDirectories: true)
        if let items = fm.enumerator(at: drop, includingPropertiesForKeys: nil) {
            for case let src as URL in items where !src.hasDirectoryPath {
                let rel = String(src.path.dropFirst(drop.path.count + 1))
                let dst = storageURL.appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.moveItem(at: src, to: dst)
            }
        }
        try? fm.removeItem(at: drop)
        if let d = try? Data(contentsOf: storageURL.appendingPathComponent("account.json")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] { suggestedEmail = j["email"] ?? "" }
    }

    /// On launch: last-resort refresh if 1 day or less is left and nothing is running.
    func onLaunch() {
        importFromLaptop()
        schedule()
        if let d = daysLeft, d <= 1, hasAccount, (Engine.shared.status["busy"] as? Bool) != true { start() }
    }

    // MARK: run
    func start() {
        guard hasAccount, let password = keychain("password") else { error = "Sign in with your Apple ID first."; return }
        let app = Bundle.main.bundleURL.path
        let cfg: [String: String] = ["email": email, "password": password, "storage_dir": storageURL.path, "app_path": app,
                                     "pairing_path": Engine.shared.pairingURL.path, "bundle_base": "com.savedscroll.engine"]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg), let text = String(data: data, encoding: .utf8) else { return }
        let r = text.withCString { json(ss_refresh_start($0)) }
        if (r["ok"] as? Bool) != true { error = "\(r["error"] ?? "couldn't start")"; return }
        state = "login"; error = ""
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func submit(code: String) { code.withCString { ss_refresh_submit_code($0) } }

    func poll() {
        let r = json(ss_refresh_status())
        state = r["state"] as? String ?? state
        progress = r["progress"] as? Int ?? progress
        detail = r["detail"] as? String ?? ""
        error = r["error"] as? String ?? ""
        if state == "need_code" { notify("Apple ID code needed", "Open Saved Scroll and type the code Apple sent you.") }
        if ["done", "failed"].contains(state) { timer?.invalidate(); timer = nil }
    }

    private func warnIfUrgent() {
        if let d = daysLeft, d <= 2 {
            notify("Saved Scroll couldn't renew its signing", "Turn on LocalDevVPN and open Saved Scroll. \(String(format: "%.0f", max(d, 0))) day(s) left.")
        }
    }

    private var notifiedCode = false
    private func notify(_ title: String, _ body: String) {
        if title.hasPrefix("Apple ID") { if notifiedCode { return }; notifiedCode = true }
        let c = UNMutableNotificationContent(); c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ss-refresh", content: c, trigger: nil))
    }

    private func json(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let p else { return [:] }
        defer { ss_string_free(p) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]) ?? [:]
    }

    // MARK: Keychain (this device only, readable after first unlock so the overnight task can use it)
    private func keychain(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "savedscroll.appleid",
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    private func setKeychain(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "savedscroll.appleid",
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
