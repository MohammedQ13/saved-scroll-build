import Foundation
import Network
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
    @Published var autoLocate = false
    @Published var lastLanding: String?
    private(set) var verifiedAt = Date.distantPast
    private(set) var targetObserved = false

    private var handoff = 0
    private let network = NWPathMonitor()

    private init() { network.start(queue: .main) }

    @MainActor
    private func context() -> [String: Any] {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        let process = ProcessInfo.processInfo
        let path = network.currentPath
        let date = Calendar.current.dateComponents([.hour, .minute, .weekday, .month], from: Date())
        var sample: [String: Any] = [
            "lowPower": process.isLowPowerModeEnabled, "thermal": process.thermalState.rawValue,
            "network": path.status != .satisfied ? "unknown" : path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cell" : "other",
            "constrained": path.isConstrained, "expensive": path.isExpensive,
            "hour": Double(date.hour ?? 0) + Double(date.minute ?? 0) / 60, "weekday": date.weekday ?? 0, "month": date.month ?? 0
        ]
        if device.batteryLevel >= 0 { sample["battery"] = device.batteryLevel }
        if device.batteryState != .unknown { sample["charging"] = device.batteryState == .charging || device.batteryState == .full }
        return sample
    }
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
        autoLocate = (info["autoCheck"] as? Bool) == true
        lastLanding = info["lastLanding"] as? String
        pins = info["pins"] as? [[String: Any]] ?? []
        if indexed {
            let st = await Brain.shared.run(["cmd": "status"])
            total = st["total"] as? Int ?? 0
            learned = st["learned"] as? Int ?? 0
        }
    }

    // MARK: brain calls used by the screens
    func calendar(year: Int? = nil, month: Int? = nil, day: Int? = nil) async -> [[String: Any]] {
        var c: [String: Any] = ["cmd": "calendar"]
        if let year { c["year"] = year }
        if let month { c["month"] = month }
        if let day { c["day"] = day }
        let r = await Brain.shared.run(c)
        return (r["hours"] ?? r["days"] ?? r["months"] ?? r["years"]) as? [[String: Any]] ?? []
    }

    /// Choose a target: "2025-05", "2025-05-14", a video link, "pin" / "pin:2".
    @MainActor
    func plan(_ target: String) async {
        verifiedAt = .distantPast
        working = true; defer { working = false }
        let r = await Brain.shared.run(["cmd": "plan", "target": target])
        message = Session.short(r["text"] as? String)
        await refresh()
    }

    /// Where-are-you choice → reopen TikTok → start there.
    enum StartFrom { case automatic, top, viaTop, copied }
    @MainActor
    private func startCommand(_ from: StartFrom) -> [String: Any] {
        var c: [String: Any] = ["cmd": "start", "context": context(),
            "strict": UserDefaults.standard.bool(forKey: "verify-wide-landing")]
        switch from {
        case .automatic: c["auto"] = true
        case .top: c["top"] = true
        case .viaTop: c["viaTop"] = true
        case .copied: c["fromClip"] = true; c["clip"] = Session.clipboard() ?? ""
        }
        return c
    }

    @MainActor
    func go(_ from: StartFrom) { openTikTok(then: startCommand(from)) }

    @MainActor
    func testDive() { openTikTok(then: ["cmd": "test-dive"]) }

    /// Start right away (TikTok is already in front): from the floating window's ⏯ or the Back Tap menu.
    @MainActor
    func startHere(_ from: StartFrom) async {
        guard UIApplication.shared.applicationState == .background else { return }
        checkedPaste = UIPasteboard.general.changeCount
        await runHandoff(startCommand(from), ticket: handoff)
    }

    /// Back Tap's menus may still be dismissing when the intent returns.
    @MainActor
    func startAfterMenu(advance: Bool) {
        handoff += 1
        let ticket = handoff
        let command: [String: Any] = advance ? ["cmd": "advance"] : startCommand(.automatic)
        checkedPaste = UIPasteboard.general.changeCount
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            await runHandoff(command, ticket: ticket)
        }
    }

    @MainActor
    private func runHandoff(_ cmd: [String: Any], ticket: Int) async {
        guard ticket == handoff, UIApplication.shared.applicationState == .background else { return }
        var r = await Brain.shared.run(cmd)
        if (r["resume"] as? Bool) == true, ticket == handoff, UIApplication.shared.applicationState == .background {
            r = await Brain.shared.run(["cmd": "advance"])
            if (r["remote"] as? Bool) == true { Task { await self.watchCheck(ticket: ticket) } }
        } else if cmd["cmd"] as? String == "advance", (r["remote"] as? Bool) == true {
            Task { await self.watchCheck(ticket: ticket) }
        }
        message = Session.short(r["text"] as? String)
        if (r["ok"] as? Bool) == false { Session.notify("Saved Scroll", r["text"] as? String ?? "Couldn't start.") }
        await refresh()
    }

    @MainActor
    private func watchCheck(ticket: Int) async {
        while ticket == handoff && UIApplication.shared.applicationState == .background {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard ticket == handoff, UIApplication.shared.applicationState == .background else { return }
            Engine.shared.refresh()
            if Engine.shared.busy || (Engine.shared.status["checking"] as? Bool) == true { continue }
            let failed = (Engine.shared.status["checkFailed"] as? Bool) == true
            let error = Engine.shared.status["error"] as? String ?? ""
            if failed || !error.isEmpty {
                ssLog.notice("engine check stopped: \(error.isEmpty ? "no return to app" : error)")
                let r = await Brain.shared.run(["cmd": "check-failed"])
                message = error.isEmpty ? Session.short(r["text"] as? String) : error
                Session.notify("Saved Scroll", message)
                await refresh()
            }
            return
        }
    }

    @MainActor
    func stop() async {
        handoff += 1
        verifiedAt = .distantPast
        Engine.shared.stopDive()
        _ = await Brain.shared.run(["cmd": "remote-stop"])
        await refresh()
    }

    /// After a leg: the user copied the link of a video near the top in TikTok.
    /// Returns true when another leg started (the app then goes back to TikTok).
    @MainActor @discardableResult
    func checkLanded(missingLink: Bool = false) async -> Bool {
        let clip = missingLink ? "" : Session.clipboard()
        guard let clip else { message = "Copy a video link in TikTok first (Share › Copy link)."; return false }
        checkedPaste = UIPasteboard.general.changeCount
        let r = await Brain.shared.run(["cmd": "arrived", "link": clip, "context": context(),
            "calibrate": UserDefaults.standard.bool(forKey: "calibrate-swipe-timing")])
        message = Session.short(r["text"] as? String)
        ssLog.notice("check: \(message.replacingOccurrences(of: "\n", with: " | "))")
        let resume = (r["resume"] as? Bool) == true
        let more = resume || (r["remote"] as? Bool) == true
        lastCheckWantsRecheck = (r["recheck"] as? Bool) == true
        if (r["done"] as? Bool) == true && r["error"] is NSNumber {
            verifiedAt = Date()
            targetObserved = (r["targetObserved"] as? Bool) == true
        }
        if more { openTikTok(then: resume ? ["cmd": "advance"] : nil) }
        if (r["ok"] as? Bool) == false && !lastCheckWantsRecheck { Session.notify("Saved Scroll", message) }
        await refresh()
        return more
    }

    /// The brain asked for a second reading one row lower (an odd reading).
    private(set) var lastCheckWantsRecheck = false

    /// The clipboard state we last checked with (or handed over to TikTok with), so an old copied link never
    /// counts as a new landing. nil until the app first becomes active: nothing is checked on launch.
    private var checkedPaste: Int?
    private var checkingPaste = false

    /// D-41: the engine's check macro copied a top video's link and brought us forward through the floating
    /// window. If a jump is under way and the clipboard changed since the last check, check now and go back
    /// to TikTok (the next leg, or "you're there"). Also covers the user copying a link and opening the app.
    @MainActor
    func autoCheckIfDue() async {
        guard !checkingPaste else { return }
        checkingPaste = true
        defer { checkingPaste = false }
        Engine.shared.refresh()
        // The macro's last tap brought us here (it may have finished a moment ago: test #90, OP-57).
        let endMs = (Engine.shared.status["checkEndMs"] as? NSNumber)?.doubleValue ?? 0
        let viaMacro = (Engine.shared.status["checking"] as? Bool) == true || Date().timeIntervalSince1970 * 1000 - endMs < 6000
        let now = UIPasteboard.general.changeCount
        guard let last = checkedPaste else { checkedPaste = now; ssLog.notice("auto-check: first activation viaMacro=\(viaMacro)"); if viaMacro { openTikTok() }; return }
        let info = await Brain.shared.run(["cmd": "menu-info"])
        guard (info["pending"] as? Bool) == true else { if viaMacro { ssLog.notice("auto-check: no jump pending, back to TikTok"); openTikTok() }; return }
        guard Engine.shared.autoCheckOn else { return }
        let missingLink = now == last || Session.clipboard() == nil
        if missingLink && !viaMacro { return }
        for _ in 0..<20 {                                            // ≤4 s for the engine to finish the macro
            Engine.shared.refresh()
            if !Engine.shared.busy && (Engine.shared.status["checking"] as? Bool) != true { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        ssLog.notice("auto-check: checking, fresh link=\(!missingLink)")
        let more = await checkLanded(missingLink: missingLink)
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

    @MainActor
    func unpin(_ i: Int) async {
        let r = await Brain.shared.run(["cmd": "unpin", "i": i])
        message = Session.short(r["text"] as? String)
        await refresh()
    }

    // MARK: TikTok handoff
    @MainActor
    func openTikTok(then command: [String: Any]? = nil) {
        handoff += 1
        let ticket = handoff
        Session.lastTikTokOpen = Date()
        checkedPaste = UIPasteboard.general.changeCount   // only links copied from here on count as a landing
        Overlay.shared.popOnLeave()                 // the window pops out as we leave for TikTok
        guard let url = URL(string: "snssdk1233://") else { return }
        UIApplication.shared.open(url) { opened in
            guard let command else { return }
            Task { @MainActor in
                guard ticket == self.handoff else { return }
                guard opened else { self.message = "Couldn't open TikTok."; return }
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                await self.runHandoff(command, ticket: ticket)
            }
        }
    }

    /// Called when the app goes to the background (TikTok coming to the front).
    @MainActor
    func didEnterBackground() {
        // Left the app for somewhere other than TikTok (home screen, another app): don't leave the window
        // floating there. iOS pops it out automatically when the app is left; the TikTok automation shows it again.
        if Date().timeIntervalSince(Session.lastTikTokOpen) > 3, Pairing.shared.state != "waiting",
           Pairing.shared.state != "code", !Engine.shared.busy {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // Skip if the "TikTok opened" automation just ran (we switched straight to TikTok).
                let tiktokNow = Date().timeIntervalSince(Session.lastTikTokSeen) < 6
                if UIApplication.shared.applicationState == .background, !tiktokNow { await Overlay.shared.hide() }
            }
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
