import Foundation
import UIKit
import UserNotifications

/// iOS 27 on-device pairing. We advertise ourselves like a Mac would; the user opens
/// Settings › Privacy & Security › Developer Mode, taps "Pair with Saved Scroll" and types our code.
/// The engine (pairing.rs) does the cryptography and saves the pairing record.
final class Pairing: NSObject, ObservableObject, NetServiceDelegate {
    static let shared = Pairing()

    @Published var state = "idle"      // idle | waiting | code | done | failed
    @Published var code = ""
    @Published var detail = ""

    private var service: NetService?
    private var timer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private var notifiedCode = ""

    var active: Bool { state == "waiting" || state == "code" }

    private func json(_ p: UnsafeMutablePointer<CChar>?) -> [String: Any] {
        guard let p else { return [:] }
        defer { ss_string_free(p) }
        return (try? JSONSerialization.jsonObject(with: Data(String(cString: p).utf8)) as? [String: Any]) ?? [:]
    }

    func start() {
        guard !active else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let r = Engine.shared.pairingURL.path.withCString { json(ss_pair_begin($0)) }
        guard (r["ok"] as? Bool) == true, let port = r["port"] as? Int, let name = r["name"] as? String else {
            state = "failed"; detail = "\(r["error"] ?? "couldn't start")"; return
        }
        let txt = (r["txt"] as? [String: String] ?? [:]).mapValues { Data($0.utf8) }
        let s = NetService(domain: "local.", type: "_remotepairing-pairable-host._tcp.", name: name, port: Int32(port))
        s.setTXTRecord(NetService.data(fromTXTRecord: txt))
        s.delegate = self
        s.publish()
        service = s
        state = "waiting"; code = ""; detail = ""; notifiedCode = ""
        // Stay alive while the user is in Settings: the floating window (started by this tap) plus a background task.
        bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() }
        if !Overlay.shared.active { Overlay.shared.toggle() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let r = json(ss_pair_status())
        state = r["state"] as? String ?? state
        code = r["code"] as? String ?? ""
        let err = r["error"] as? String ?? ""
        if state == "code", !code.isEmpty, code != notifiedCode {
            notifiedCode = code
            notify("Pairing code: \(code)", "Type it in Settings › Privacy & Security › Developer Mode › Pair with Saved Scroll.")
        }
        if state == "done" {
            detail = "Paired with \(r["device"] as? String ?? "this iPhone"). Saved Scroll can now scroll TikTok."
            notify("Paired ✓", "Go back to Saved Scroll, or straight to TikTok.")
            finish()
        } else if state == "failed" {
            detail = err
            finish()
        } else if !err.isEmpty {
            detail = "Last try didn't work (\(err.prefix(80))). Try again in Settings."
        }
    }

    private func finish() {
        timer?.invalidate(); timer = nil
        service?.stop(); service = nil
        endBackground()
        Engine.shared.objectWillChange.send()
    }

    private func endBackground() {
        if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ss-pair", content: c, trigger: nil))
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { self.detail = "Couldn't advertise on the local network (\(errorDict)). Allow Local Network for Saved Scroll in Settings › Privacy & Security." }
    }
}
