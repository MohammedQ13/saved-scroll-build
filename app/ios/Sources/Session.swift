import Foundation
import UIKit
import UserNotifications

/// What the user is doing right now, and the "Go" flow:
///   pick a target in the app → plan (brain) → Go → the app reopens TikTok → once TikTok is in front, the
///   dive starts (the brain hands it to the engine). Dives never start while Saved Scroll itself is in front.
final class Session: ObservableObject {
    static let shared = Session()

    @Published var indexed = false
    @Published var total = 0
    @Published var learned = 0
    @Published var armed: String?                 // target chosen, waiting for "where are you" + Go
    @Published var message = ""                   // last brain message (short)
    @Published var pins: [[String: Any]] = []
    @Published var hasPending = false             // a multi-leg jump waiting for "Check where I landed"
    @Published var working = false

    /// The start command to run once TikTok is in front.
    private var queuedStart: [String: Any]?
    /// Set right before we open TikTok, so the "When TikTok is opened" automation doesn't bounce back here.
    static var lastTikTokOpen = Date.distantPast
    /// Set when the "When TikTok is opened" automation asks whether the window is needed.
    static var lastTikTokSeen = Date.distantPast

    @MainActor
    func refresh() async {
        let info = await Brain.shared.run(["cmd": "menu-info"])
        indexed = (info["indexed"] as? Bool) == true
        armed = (info["armed"] as? String)?.components(separatedBy: "\n").first
        hasPending = (info["pending"] as? Bool) == true
        pins = info["pins"] as? [[String: Any]] ?? []
        if indexed {
            let st = await Brain.shared.run(["cmd": "status"])
            total = st["total"] as? Int ?? 0
            learned = st["learned"] as? Int ?? 0
        }
    }

    // MARK: brain calls used by the screens
    func calendar(year: Int? = nil, month: Int? = nil) async -> [[String: Any]] {
        var c: [String: Any] = ["cmd": "calendar"]
        if let year { c["year"] = year }
        if let month { c["month"] = month }
        let r = await Brain.shared.run(c)
        return (r["days"] ?? r["months"] ?? r["years"]) as? [[String: Any]] ?? []
    }

    /// Choose a target: "2025-05", "2025-05-14", a video link, "pin" / "pin:2".
    @MainActor
    func plan(_ target: String) async {
        working = true; defer { working = false }
        let r = await Brain.shared.run(["cmd": "plan", "target": target, "net": "wifi-good", "clip": Session.clipboard() ?? ""])
        message = Session.short(r["text"] as? String)
        await refresh()
    }

    /// Where-are-you choice → reopen TikTok → start there.
    enum StartFrom { case top, viaTop, copied }
    @MainActor
    func go(_ from: StartFrom) {
        var c: [String: Any] = ["cmd": "start", "net": "wifi-good"]
        switch from {
        case .top: c["top"] = true
        case .viaTop: c["viaTop"] = true
        case .copied: c["fromClip"] = true; c["clip"] = Session.clipboard() ?? ""
        }
        queuedStart = c
        openTikTok()
    }

    @MainActor
    func testDive() { queuedStart = ["cmd": "test-dive"]; openTikTok() }

    /// Start right away (TikTok is already in front): from the floating window's ⏯ or the Back Tap menu.
    @MainActor
    func startHere(_ from: StartFrom) async {
        var c: [String: Any] = ["cmd": "start", "net": "wifi-good"]
        switch from {
        case .top: c["top"] = true
        case .viaTop: c["viaTop"] = true
        case .copied: c["fromClip"] = true; c["clip"] = Session.clipboard() ?? ""
        }
        let r = await Brain.shared.run(c)
        message = Session.short(r["text"] as? String)
        if (r["ok"] as? Bool) == false { Session.notify("Saved Scroll", r["text"] as? String ?? "Couldn't start.") }
        await refresh()
    }

    @MainActor
    func stop() async {
        Engine.shared.stopDive()
        _ = await Brain.shared.run(["cmd": "remote-stop"])
    }

    /// After a leg: the user copied the link of a video near the top in TikTok.
    /// Returns true when another leg started (the app then goes back to TikTok).
    @MainActor @discardableResult
    func checkLanded() async -> Bool {
        guard let clip = Session.clipboard() else { message = "Copy a video link in TikTok first (Share › Copy link)."; return false }
        checkedPaste = UIPasteboard.general.changeCount
        let r = await Brain.shared.run(["cmd": "arrived", "link": clip])
        message = Session.short(r["text"] as? String)
        ssLog.notice("check: \(message.replacingOccurrences(of: "\n", with: " | "))")
        let more = (r["remote"] as? Bool) == true
        lastCheckWantsRecheck = (r["recheck"] as? Bool) == true
        if more { openTikTok() }      // another leg started: watch it in TikTok
        await refresh()
        return more
    }

    /// The brain asked for a second reading one row lower (an odd reading).
    private(set) var lastCheckWantsRecheck = false

    /// The clipboard state we last checked with (or handed over to TikTok with), so an old copied link never
    /// counts as a new landing. nil until the app first becomes active: nothing is checked on launch.
    private var checkedPaste: Int?

    /// D-41: the engine's check macro copied a top video's link and brought us forward through the floating
    /// window. If a jump is under way and the clipboard changed since the last check, check now and go back
    /// to TikTok (the next leg, or "you're there"). Also covers the user copying a link and opening the app.
    @MainActor
    func autoCheckIfDue() async {
        Engine.shared.refresh()
        // The macro's last tap brought us here (it may have finished a moment ago: test #90, OP-57).
        let endMs = (Engine.shared.status["checkEndMs"] as? NSNumber)?.doubleValue ?? 0
        let viaMacro = (Engine.shared.status["checking"] as? Bool) == true || Date().timeIntervalSince1970 * 1000 - endMs < 6000
        let now = UIPasteboard.general.changeCount
        guard let last = checkedPaste else { checkedPaste = now; ssLog.notice("auto-check: first activation viaMacro=\(viaMacro)"); if viaMacro { openTikTok() }; return }
        guard Engine.shared.autoCheckOn, now != last else { if viaMacro { ssLog.notice("auto-check: nothing new copied, back to TikTok"); openTikTok() }; return }
        let info = await Brain.shared.run(["cmd": "menu-info"])
        guard (info["pending"] as? Bool) == true else { if viaMacro { ssLog.notice("auto-check: no jump pending, back to TikTok"); openTikTok() }; return }
        for _ in 0..<20 {                                            // ≤4 s for the engine to finish the macro
            Engine.shared.refresh()
            if !Engine.shared.busy && (Engine.shared.status["checking"] as? Bool) != true { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        ssLog.notice("auto-check: clipboard changed, checking")
        let more = await checkLanded()
        if !more { openTikTok() }                                    // done (or a problem): back to the spot
        if lastCheckWantsRecheck && !more {
            // Hands-free second reading: back in TikTok, the engine copies the link one row lower and brings us
            // forward again (this function runs again then).
            ssLog.notice("auto-check: odd reading, checking one row lower")
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await Engine.shared.api("/macro", ["s": Engine.checkMacroFor(row: 1)])
        }
    }

    @MainActor
    func pinCopied(note: String = "") async {
        guard let clip = Session.clipboard() else { message = "Copy a video link in TikTok first."; return }
        let r = await Brain.shared.run(["cmd": "pin", "link": clip, "note": note])
        message = Session.short(r["text"] as? String)
        await refresh()
    }

    // MARK: TikTok handoff
    @MainActor
    func openTikTok() {
        Session.lastTikTokOpen = Date()
        checkedPaste = UIPasteboard.general.changeCount   // only links copied from here on count as a landing
        Overlay.shared.popOnLeave()                 // the window pops out as we leave for TikTok
        if let url = URL(string: "snssdk1233://") { UIApplication.shared.open(url) }
    }

    /// Called when the app goes to the background (TikTok coming to the front).
    @MainActor
    func didEnterBackground() {
        // Left the app for somewhere other than TikTok (home screen, another app): don't leave the window
        // floating there. iOS pops it out automatically when the app is left; the TikTok automation shows it again.
        if queuedStart == nil, Date().timeIntervalSince(Session.lastTikTokOpen) > 3, Pairing.shared.state != "waiting",
           Pairing.shared.state != "code", !Engine.shared.busy {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Skip if the "TikTok opened" automation just ran (we switched straight to TikTok).
                let tiktokNow = Date().timeIntervalSince(Session.lastTikTokSeen) < 6
                if UIApplication.shared.applicationState == .background, !tiktokNow { await Overlay.shared.hide() }
            }
        }
        guard let c = queuedStart else { return }
        queuedStart = nil
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)     // let TikTok finish appearing
            let r = await Brain.shared.run(c)
            await MainActor.run { self.message = Session.short(r["text"] as? String) }
            if (r["ok"] as? Bool) == false { Session.notify("Saved Scroll", r["text"] as? String ?? "Couldn't start.") }
            await self.refresh()
        }
    }

    // MARK: helpers
    static func clipboard() -> String? {
        let s = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }

    static func short(_ s: String?) -> String {
        (s ?? "").replacingOccurrences(of: "button › ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "ss-session", content: c, trigger: nil))
    }
}
