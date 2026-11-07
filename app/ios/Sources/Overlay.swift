import AVFoundation
import AVKit
import UIKit
import os

/// Logs readable from the laptop: `pymobiledevice3 syslog live | grep "\[savedscroll\]"` (docs/knowledge/14 §8).
/// Device 2026-11-05/06: Logger(subsystem:) lines never showed up in the USB syslog stream, and NSLog's %@
/// arguments arrive as <private>. os_log with %{public}@ on the default log is readable.
/// Also appended to Documents/ss-log.txt (device 2026-11-06: the Wi-Fi log stream drops some lines under load, so
/// the app keeps its own copy; the laptop reads it with `sslab app log` over Wi-Fi). Kept under ~256 KB.
struct SSLog {
    private static let q = DispatchQueue(label: "ss-log")
    private static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ss-log.txt")
    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()
    func notice(_ s: String) {
        os_log("[savedscroll] %{public}@", type: .default, s)
        let line = "\(SSLog.fmt.string(from: Date())) \(s)\n"
        SSLog.q.async {
            let url = SSLog.url
            if let h = try? FileHandle(forWritingTo: url) {
                let size = h.seekToEndOfFile()
                h.write(Data(line.utf8)); try? h.close()
                if size > 256_000, let all = try? Data(contentsOf: url) { try? all.suffix(128_000).write(to: url) }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
let ssLog = SSLog()

/// Shapes the user can pick (PiP lab). iOS sizes PiP by aspect ratio; for wide video its minimum is about
/// half the screen width, so squarer shapes can sit smaller (docs/CORE.md). The choice is remembered.
enum PipShape: String, CaseIterable, Identifiable {
    case pill, card, square, tall
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .pill: return CGSize(width: 540, height: 180)     // 3:1
        case .card: return CGSize(width: 400, height: 300)     // 4:3
        case .square: return CGSize(width: 320, height: 320)   // 1:1
        case .tall: return CGSize(width: 300, height: 400)     // 3:4
        }
    }
    var name: String { ["pill": "Pill 3:1", "card": "Card 4:3", "square": "Square", "tall": "Tall 3:4"][rawValue]! }
}

/// The floating window over TikTok (Picture in Picture): a glanceable status display plus the only
/// controls iOS gives PiP. ⏯ = start (when a target is chosen) / stop. ⏪ ⏩ = 5 swipes up / down (only
/// shown when "skip buttons" is on: they may need a finite time range). While PiP is up, iOS keeps the
/// app (engine + brain) running behind TikTok.
final class Overlay: NSObject, ObservableObject, AVPictureInPictureSampleBufferPlaybackDelegate, AVPictureInPictureControllerDelegate {
    static let shared = Overlay()

    let layer = AVSampleBufferDisplayLayer()
    private var pip: AVPictureInPictureController?
    private var timer: Timer?
    @Published var active = false
    @Published var problem = ""

    // Pill by default: on the phone it covered ~14% of the screen vs 33–43% for the others (2026-11-03).
    @Published var shape: PipShape = PipShape(rawValue: UserDefaults.standard.string(forKey: "pip-shape") ?? "") ?? .pill {
        didSet { UserDefaults.standard.set(shape.rawValue, forKey: "pip-shape"); tick() }
    }
    /// ⏪ ⏩ = 5 swipes up/down. Device 2026-11-03: they show either way, but only work with
    /// requiresLinearPlayback off and a finite time range (verified: ⏩ moved Saved down). On by default.
    @Published var skipButtons: Bool = (UserDefaults.standard.object(forKey: "pip-skip") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(skipButtons, forKey: "pip-skip"); pip?.requiresLinearPlayback = !skipButtons; pip?.invalidatePlaybackState() }
    }
    /// The last dive's end, to show STOPPED / DONE for a while instead of READY.
    private var lastDive: (done: Int, planned: Int, at: Date)?
    private var wasBusy = false

    func setUp() {
        if pip != nil { return }
        KeepAlive.start()                         // keeps us alive behind TikTok even if PiP never starts
        layer.videoGravity = .resizeAspect
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(tb, rate: 1)
            layer.controlTimebase = tb
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        makeController()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    private func makeController() {
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        let c = AVPictureInPictureController(contentSource: source)
        c.delegate = self
        // Pop out on leaving the app only when we're heading to TikTok (popOnLeave). Always-on popped it over the
        // home screen and other apps, and hiding it again took seconds (device 2026-11-06, Test A).
        c.canStartPictureInPictureAutomaticallyFromInline = false
        c.requiresLinearPlayback = !skipButtons
        pip = c
    }

    private var popGen = 0
    /// Lets iOS pop the window out when the app is left in the next few seconds (we're about to open TikTok).
    /// Device 2026-11-06: this auto-start is what reliably brings the window up from the Show automation; a start
    /// call while the app is only "inactive" (being brought forward by Shortcuts) did nothing in 3/3 cycles.
    @MainActor
    func popOnLeave(for seconds: Double = 5) {
        guard let pip else { return }
        popGen += 1
        let gen = popGen
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            if gen == self.popGen { pip.canStartPictureInPictureAutomaticallyFromInline = false }
        }
    }

    /// Start (waiting up to 3 s until iOS says PiP is possible) or stop.
    func toggle() { if pip?.isPictureInPictureActive == true { hideNow() } else { show() } }

    func show() {
        guard let pip else {
            problem = AVPictureInPictureController.isPictureInPictureSupported() ? "Floating window not set up yet." : "This iPhone reports no Picture in Picture support."
            return
        }
        if pip.isPictureInPictureActive { return }
        problem = ""
        Task { @MainActor in
            for _ in 0..<30 where !pip.isPictureInPicturePossible {
                self.tick()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            ssLog.notice("show: possible=\(pip.isPictureInPicturePossible) appState=\(UIApplication.shared.applicationState.rawValue)")
            if pip.isPictureInPicturePossible { pip.startPictureInPicture() }
            else { self.problem = "iOS says the floating window isn't possible right now. Check Settings › General › Picture in Picture is on." }
        }
    }

    /// The real PiP state (the `active` flag can lag behind iOS).
    var isUp: Bool { pip?.isPictureInPictureActive == true }

    /// While the Show automation runs, the app comes forward for a moment, which iOS reports as "TikTok closed":
    /// the Hide automation must not kill the window Show is starting (device 2026-11-06).
    var showingUntil = Date.distantPast

    /// Q-28. Stop, then wait for iOS to finish closing (isPictureInPictureActive only turns false after the
    /// close animation, ~0.5–1 s). Last resort: detach the content and reattach it to the same controller.
    /// (Device 2026-11-06: rebuilding the controller instead left the new one never "possible", so Show broke.)
    @MainActor @discardableResult
    func hide() async -> Bool {
        guard let pip else { ssLog.notice("hide: no PiP controller"); return true }
        ssLog.notice("hide: before up=\(pip.isPictureInPictureActive) flag=\(self.active) appState=\(UIApplication.shared.applicationState.rawValue)")
        if !pip.isPictureInPictureActive { return true }
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        // Device 2026-11-06: from the background stopPictureInPicture() was ignored in 7/7 hides (tests #76–84);
        // detaching the content closed the window in ~0.9 s every time. In front, a normal stop works.
        if UIApplication.shared.applicationState == .active {
            pip.stopPictureInPicture()
            if await waitDown(pip, seconds: 1.0) { ssLog.notice("hide: stopped"); return true }
        }
        ssLog.notice("hide: detaching content")
        pip.contentSource = nil
        let down = await waitDown(pip, seconds: 1.5)
        pip.contentSource = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: layer, playbackDelegate: self)
        ssLog.notice("hide: after detach down=\(down)")
        return down
    }

    @MainActor
    private func waitDown(_ pip: AVPictureInPictureController, seconds: Double) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if !pip.isPictureInPictureActive { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !pip.isPictureInPictureActive
    }

    /// Synchronous convenience for UI buttons.
    func hideNow() { Task { await hide() } }

    fileprivate func tick() {
        Engine.shared.refresh()
        if let sb = frame() {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sb)
        }
        pip?.invalidatePlaybackState()
    }

    // MARK: drawing
    private struct Look { let dot: UIColor; let big: String; let small: String; let progress: Double? }

    private func look() -> Look {
        let st = Engine.shared.status
        let busy = (st["busy"] as? Bool) == true, checking = (st["checking"] as? Bool) == true
        let done = st["done"] as? Int ?? 0, planned = st["planned"] as? Int ?? 0
        let pre = st["pre"] as? Int ?? 0, preDone = st["preDone"] as? Int ?? 0
        let cyan = UIColor(red: 0.0, green: 0.86, blue: 1.0, alpha: 1), pink = UIColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1)
        let pairing = Pairing.shared
        if pairing.state == "code", !pairing.code.isEmpty { return Look(dot: .systemYellow, big: pairing.code, small: "PAIRING CODE", progress: nil) }
        if checking { return Look(dot: pink, big: "CHECK", small: "READING POSITION", progress: nil) }
        if busy {
            wasBusy = true
            if planned == 0 { return Look(dot: pink, big: "CHECKING", small: "FINDING POSITION", progress: nil) }
            if pre > 0 && preDone < pre { return Look(dot: pink, big: "\(preDone)/\(pre)", small: "↑ TO THE TOP", progress: Double(preDone) / Double(max(pre, 1))) }
            return Look(dot: pink, big: "\(done)/\(planned)", small: "↓ SCROLLING", progress: Double(done) / Double(max(planned, 1)))
        }
        if (st["checking"] as? Bool) == true {
            return Look(dot: pink, big: "CHECKING", small: "VERIFYING LANDING", progress: nil)
        }
        if wasBusy { wasBusy = false; lastDive = (done, planned, Date()) }
        if let d = lastDive, Date().timeIntervalSince(d.at) < 20, d.planned > 0, (st["error"] as? String ?? "").isEmpty {
            let finished = d.done >= d.planned
            let green = UIColor(red: 0.27, green: 0.93, blue: 0.56, alpha: 1)
            return Look(dot: finished ? green : .systemOrange, big: "\(d.done)/\(d.planned)", small: finished ? "DONE" : "STOPPED",
                        progress: Double(d.done) / Double(d.planned))
        }
        if let e = st["error"] as? String, !e.isEmpty {
            let vpn = e.lowercased().contains("connect") || e.lowercased().contains("vpn")
            return Look(dot: .systemRed, big: vpn ? "VPN OFF" : "ERROR", small: vpn ? "OPEN LOCALDEVVPN" : String(e.prefix(28)).uppercased(), progress: nil)
        }
        let armed = Session.shared.armed
        if let armed { return Look(dot: cyan, big: "▶ READY", small: String(armed.prefix(26)).uppercased(), progress: nil) }
        return Look(dot: cyan, big: "READY", small: "SAVED SCROLL", progress: nil)
    }

    private func frame() -> CMSampleBuffer? {
        let size = shape.size
        let l = look()
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.035, green: 0.043, blue: 0.059, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            if self.shape == .pill {
                // One line: ● 12/40 ……… SCROLLING, thin bar under it.
                let pad = size.height * 0.16, d = size.height * 0.12
                l.dot.setFill()
                ctx.cgContext.fillEllipse(in: CGRect(x: pad, y: (size.height - d) / 2 - size.height * 0.04, width: d, height: d))
                let big = NSAttributedString(string: l.big, attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: size.height * 0.40, weight: .bold),
                                                                         .foregroundColor: UIColor(white: 1, alpha: 0.95)])
                let bs = big.size()
                big.draw(at: CGPoint(x: pad + d * 1.9, y: (size.height - bs.height) / 2 - size.height * 0.04))
                let small = NSAttributedString(string: l.small, attributes: [.font: UIFont.monospacedSystemFont(ofSize: size.height * 0.13, weight: .semibold),
                                                                             .foregroundColor: UIColor(white: 1, alpha: 0.55), .kern: 1.0])
                let ss = small.size()
                let room = size.width - pad - (pad + d * 1.9 + bs.width + pad * 0.6)
                if ss.width <= room { small.draw(at: CGPoint(x: size.width - pad - ss.width, y: (size.height - ss.height) / 2 - size.height * 0.04)) }
                if let p = l.progress {
                    let w = size.width - pad * 2, y = size.height - pad * 0.9
                    UIColor(white: 1, alpha: 0.12).setFill(); ctx.cgContext.fill(CGRect(x: pad, y: y, width: w, height: 5))
                    l.dot.setFill(); ctx.cgContext.fill(CGRect(x: pad, y: y, width: max(5, w * min(max(p, 0), 1)), height: 5))
                }
                return
            }
            let pad = size.width * 0.08
            // status dot + small caps label
            l.dot.setFill()
            let d = size.height * 0.07
            ctx.cgContext.fillEllipse(in: CGRect(x: pad, y: pad + d * 0.2, width: d, height: d))
            let smallFont = UIFont.monospacedSystemFont(ofSize: size.height * 0.085, weight: .semibold)
            NSAttributedString(string: l.small, attributes: [.font: smallFont, .foregroundColor: UIColor(white: 1, alpha: 0.55), .kern: 1.2])
                .draw(at: CGPoint(x: pad + d * 1.8, y: pad - d * 0.1))
            // the one big thing
            let bigSize = min(size.height * 0.34, size.width * 0.17)
            let bigFont = UIFont.monospacedDigitSystemFont(ofSize: bigSize, weight: .bold)
            let big = NSAttributedString(string: l.big, attributes: [.font: bigFont, .foregroundColor: UIColor(white: 1, alpha: 0.95)])
            let bigY = (size.height - big.size().height) / 2 + size.height * 0.02
            big.draw(at: CGPoint(x: pad, y: bigY))
            // thin progress bar
            if let p = l.progress {
                let barY = size.height - pad - 6
                let w = size.width - pad * 2
                UIColor(white: 1, alpha: 0.12).setFill()
                ctx.cgContext.fill(CGRect(x: pad, y: barY, width: w, height: 6))
                l.dot.setFill()
                ctx.cgContext.fill(CGRect(x: pad, y: barY, width: max(6, w * min(max(p, 0), 1)), height: 6))
            }
        }
        guard let cg = image.cgImage else { return nil }
        var pb: CVPixelBuffer?
        // IOSurface-backed: PiP is drawn by another process, which can only read shareable buffers
        // (without this: CoreMedia PixelBufferSharing err -15596 on every frame, syslog 2026-11-03).
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                     kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as [CFString: Any] as CFDictionary
        CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(origin: .zero, size: size))
        CVPixelBufferUnlockBaseAddress(pb, [])
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fmt)
        guard let fmt else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fmt, sampleTiming: &timing, sampleBufferOut: &sb)
        if let sb, let att = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true) as? [NSMutableDictionary] {
            att.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sb
    }

    // MARK: PiP controls
    /// ⏯: pause = stop the dive; play = start the chosen target from wherever you are (the app goes up to the
    /// top first, so no copied link is needed).
    func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in
            if !playing { await Session.shared.stop() }
            else if Session.shared.armed != nil { await Session.shared.startHere(Session.shared.autoLocate ? .automatic : .viaTop) }
            self.tick()
        }
    }
    func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
        skipButtons ? CMTimeRange(start: .zero, duration: CMTime(seconds: 86_400, preferredTimescale: 1))
                    : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)     // live: no scrubber
    }
    /// Before PiP is up, report "playing" (iOS only auto-starts PiP for playing content). Once it's up,
    /// ⏯ shows the real state: pause while scrolling, play when idle.
    func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool {
        active ? !Engine.shared.busy : false
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    /// ⏩ / ⏪: five swipes down / up, to fine-tune where you land.
    func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime) async {
        await Engine.shared.nudge(skipInterval.seconds >= 0 ? 5 : -5)
    }
    func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        let e = error as NSError
        ssLog.notice("PiP failed to start: \(e.domain) \(e.code) \(e.localizedDescription) appState=\(UIApplication.shared.applicationState.rawValue)")
        DispatchQueue.main.async { self.problem = "Floating window failed: \(error.localizedDescription)" }
    }
    func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        ssLog.notice("PiP did start")
        DispatchQueue.main.async { self.active = true; self.problem = "" }
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) { ssLog.notice("PiP did stop"); DispatchQueue.main.async { self.active = false } }
}
