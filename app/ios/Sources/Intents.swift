import AppIntents
import UIKit

// Actions iOS can run without our app in front: Shortcuts automations ("When TikTok is opened/closed")
// and Back Tap (double-tap the back of the phone → "Saved Scroll menu"). Research: docs/CORE.md.

/// "When TikTok is opened" → show the floating window. PiP can only start while our app is in front or
/// being left, so this briefly brings the app forward (iOS 26 `.foreground(.dynamic)`), starts the window
/// and returns to TikTok. Loop breaker: if we just reopened TikTok ourselves, do nothing.
@available(iOS 26.0, *)
struct ShowWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Saved Scroll window"
    static let description = IntentDescription("Shows the floating Saved Scroll window over TikTok.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    func perform() async throws -> some IntentResult {
        // Q-29: use the real PiP state (the `active` flag can lag), and log the decision.
        let (up, recent) = await MainActor.run { (Overlay.shared.isUp, Date().timeIntervalSince(Session.lastTikTokOpen) < 4) }
        ssLog.notice("ShowWindowIntent: up=\(up) recentOpen=\(recent) canForeground=\(systemContext.currentMode.canContinueInForeground)")
        if up || recent { return .result() }
        if systemContext.currentMode == .background {
            // Device 2026-11-05: from a background automation canContinueInForeground was false, and PiP refuses to
            // start from the background ("sceneActivationState == 2"). So the automation runs this with
            // "Open When Run" ON, guarded by WindowNeededIntent (no loop), and we arrive here already in front.
            guard systemContext.currentMode.canContinueInForeground else { return .result() }
            do { try await continueInForeground(alwaysConfirm: false) } catch { return .result() }
        }
        await MainActor.run {
            Overlay.shared.showingUntil = Date().addingTimeInterval(8)
            Overlay.shared.setUp()
        }
        // Device 2026-11-06 (Test A, 3/3): starting PiP while Shortcuts is still bringing us forward (appState 1)
        // never worked; the window came from iOS's pop-out when we went back to TikTok. So: wait (≤1.5 s) for the
        // app to be really active and start it here if iOS allows; otherwise go straight back and let it pop out.
        var state = -1
        for _ in 0..<15 {
            state = await MainActor.run(body: { UIApplication.shared.applicationState.rawValue })
            if state == 0 { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if state == 0 {
            await MainActor.run { Overlay.shared.show() }
            for _ in 0..<8 {                                // ≤0.8 s
                if await MainActor.run(body: { Overlay.shared.isUp }) { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let up2 = await MainActor.run(body: { Overlay.shared.isUp })
        ssLog.notice("ShowWindowIntent: appState=\(state) window up=\(up2), back to TikTok (pops out if not up)")
        await MainActor.run {
            Session.shared.openTikTok()                         // also lets the window pop out on the way
            Overlay.shared.showingUntil = Date().addingTimeInterval(3)
        }
        return .result()
    }
}

/// For the "When TikTok is opened" automation: true only when the window is missing and we didn't just reopen
/// TikTok ourselves. The automation runs Show (which brings the app forward for a moment) only if this is true,
/// so going back to TikTok afterwards doesn't loop.
struct WindowNeededIntent: AppIntent {
    static let title: LocalizedStringResource = "Saved Scroll window needed"
    static let description = IntentDescription("True when the floating window isn't showing yet. Use it in an If before Show Saved Scroll window.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        let (up, recent) = await MainActor.run { () -> (Bool, Bool) in
            Session.lastTikTokSeen = Date()
            return (Overlay.shared.isUp, Date().timeIntervalSince(Session.lastTikTokOpen) < 4)
        }
        ssLog.notice("WindowNeededIntent: up=\(up) recentOpen=\(recent) → \(!(up || recent))")
        return .result(value: !(up || recent))
    }
}

/// "When TikTok is closed" → hide the floating window (and stop a running dive).
struct HideWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide Saved Scroll window"
    static let description = IntentDescription("Hides the floating Saved Scroll window.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        // "TikTok closed" because Show brought our app forward for a moment (or the user opened our app): keep it.
        let (ours, front, checking) = await MainActor.run {
            Engine.shared.refresh()
            return (Date() < Overlay.shared.showingUntil, UIApplication.shared.applicationState != .background,
                    (Engine.shared.status["checking"] as? Bool) == true)
        }
        if ours || front { ssLog.notice("HideWindowIntent: skipped (showing=\(ours) appInFront=\(front))"); return .result() }
        // TikTok can report closed before the status-bar return has made our
        // scene active. Only defer during checks, when there are no scroll swipes.
        if checking {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if await MainActor.run(body: { UIApplication.shared.applicationState != .background }) {
                ssLog.notice("HideWindowIntent: skipped during check return")
                return .result()
            }
        }
        // Leaving TikTok mid-dive: stop first, or the swipes would land on whatever is in front now.
        let busy = await MainActor.run { Engine.shared.busy }
        if busy { await Session.shared.stop() }
        let down = await Overlay.shared.hide()
        ssLog.notice("HideWindowIntent: busy=\(busy) down=\(down)")
        return .result()
    }
}

/// Stop scrolling right now.
struct StopScrollIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Saved Scroll"
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await Session.shared.stop()
        return .result(dialog: "Stopped.")
    }
}

/// Back Tap → the full menu over TikTok, without opening the app. Drives the brain's menu (the same
/// `ui` steps the old Shortcut used): lists become pickers, text questions become input prompts.
struct MenuIntent: AppIntent {
    static let title: LocalizedStringResource = "Saved Scroll menu"
    static let description = IntentDescription("Go to a month, a day, the copied video or a checkpoint, right over TikTok.")
    static let openAppWhenRun = false

    @Parameter(title: "Choice", default: "") var choice: String
    @Parameter(title: "Answer", default: "") var answer: String
    @Parameter(title: "Copied link", default: "") var clip: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let copied = clip.isEmpty ? (Session.clipboard() ?? "") : clip
        var reply = ""
        for step in 1...8 {
            let r = await Brain.shared.run(["cmd": "ui", "step": step, "reply": reply, "clip": copied, "wifi": "wifi"])
            let ask = r["ask"] as? String ?? "none"
            let prompt = r["prompt"] as? String ?? "Saved Scroll"
            if ask == "list", let items = r["items"] as? [String], !items.isEmpty {
                reply = try await $choice.requestDisambiguation(among: items, dialog: IntentDialog(stringLiteral: prompt))
            } else if ask == "text" {
                reply = try await $answer.requestValue(IntentDialog(stringLiteral: prompt))
            } else {
                let start = (r["nativeStart"] as? Bool) == true
                let advance = (r["nativeAdvance"] as? Bool) == true
                if start || advance { await Session.shared.startAfterMenu(advance: advance) }
                await Session.shared.refresh()
                let text = Session.short(r["notify"] as? String)
                return .result(dialog: IntentDialog(stringLiteral: text.isEmpty ? "Done." : text))
            }
        }
        return .result(dialog: "Menu closed.")
    }
}

/// Names in the Shortcuts app (they also appear under Saved Scroll there, ready for automations/Back Tap).
struct SavedScrollShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MenuIntent(), phrases: ["\(.applicationName) menu"], shortTitle: "Menu", systemImageName: "list.bullet")
        AppShortcut(intent: StopScrollIntent(), phrases: ["Stop \(.applicationName)"], shortTitle: "Stop", systemImageName: "stop.fill")
        AppShortcut(intent: HideWindowIntent(), phrases: ["Hide \(.applicationName) window"], shortTitle: "Hide window", systemImageName: "pip.exit")
    }
}
