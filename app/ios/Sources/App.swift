import AVKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct SavedScrollApp: App {
    @Environment(\.scenePhase) private var phase
    init() { Refresher.shared.register() }       // background tasks must be registered at launch
    var body: some Scene {
        WindowGroup { HomeView().preferredColorScheme(.dark) }
            .onChange(of: phase, initial: true) { _, p in
                if p == .active {
                    ss_engine_app_active()
                    Task { await Session.shared.refresh(); await Session.shared.autoCheckIfDue() }
                }
                if p == .background {
                    ss_engine_app_background()
                    Session.shared.didEnterBackground()
                }
            }
    }
}

/// Hosts the PiP layer. iOS only allows PiP while the layer is on screen with a real size, so the size is
/// set in layoutSubviews and never to zero (SwiftUI updates used to zero it briefly, which made PiP flip
/// between allowed and prohibited every half second: syslog 2026-11-03).
final class LayerHostView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        Overlay.shared.layer.frame = CGRect(x: 0, y: 0, width: 320, height: 100)
        layer.addSublayer(Overlay.shared.layer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width > 0 && bounds.height > 0 && Overlay.shared.layer.frame != bounds {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            Overlay.shared.layer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct LayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> LayerHostView { LayerHostView(frame: .zero) }
    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}

// MARK: - Home
struct HomeView: View {
    @ObservedObject var engine = Engine.shared
    @ObservedObject var overlay = Overlay.shared
    @ObservedObject var session = Session.shared
    @ObservedObject var refresher = Refresher.shared
    @State private var picker: GoToSheet.Mode?
    @State private var importing = false
    @State private var settings = false
    @State private var vpnOK = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    chips
                    windowCard
                    if let armed = session.armed { armedCard(armed) } else { goCard }
                    if !session.message.isEmpty {
                        Text(session.message).font(Theme.mono(12)).foregroundStyle(Theme.dim).padding(.horizontal, 4)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape").foregroundStyle(Theme.dim) }
                }
            }
            .navigationDestination(isPresented: $settings) { SettingsView() }
        }
        .tint(Theme.accent)
        .sheet(item: $picker) { mode in GoToSheet(mode: mode).presentationDetents([.medium, .large]) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            if case .success(let url) = result {
                Task {
                    let r = await Brain.shared.importExport(from: url)
                    await MainActor.run { session.message = Session.short(r["text"] as? String) }
                    await session.refresh()
                }
            }
        }
        .onAppear {
            if !engine.started { engine.start(); Task { await engine.installAutoCheck() } }
            Overlay.shared.setUp()
            DiskImage.shared.ensure()
            Refresher.shared.importFromLaptop()
            Task {
                await Vpn.ensureOn()
                vpnOK = await Vpn.reachable()
                Refresher.shared.onLaunch()
                await session.refresh()
            }
        }
    }

    private var busy: Bool { engine.busy }
    private var done: Int { engine.status["done"] as? Int ?? 0 }
    private var planned: Int { engine.status["planned"] as? Int ?? 0 }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SAVED SCROLL").font(Theme.label(12)).foregroundStyle(Theme.accent).tracking(2)
            HStack(alignment: .firstTextBaseline) {
                Text(busy ? "\(done)/\(planned)" : (session.armed != nil ? "READY TO GO" : "READY"))
                    .font(Theme.mono(34, .bold)).foregroundStyle(Theme.text)
                if busy { Text("↓ scrolling").font(Theme.mono(13)).foregroundStyle(Theme.dim) }
                Spacer()
                if busy {
                    Button { Task { await session.stop() } } label: {
                        Image(systemName: "stop.fill").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.bad)
                            .padding(12).overlay(Circle().stroke(Theme.bad.opacity(0.6), lineWidth: 1.2))
                    }
                }
            }
            if busy { Bar(value: Double(done) / Double(max(planned, 1)), color: Theme.bad) }
        }
    }

    private var chips: some View {
        let err = engine.status["error"] as? String ?? ""
        let days = refresher.daysLeft.map { String(format: "%.1fd", $0) } ?? "—"
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(label: "VPN", value: vpnOK ? "ON" : "OFF", color: vpnOK ? Theme.ok : Theme.bad)
                Chip(label: "ENGINE", value: busy ? "BUSY" : (err.isEmpty ? "OK" : "ERR"), color: busy ? Theme.accent : (err.isEmpty ? Theme.ok : Theme.bad))
                Chip(label: "SIGNED", value: days, color: (refresher.daysLeft ?? 9) > 2 ? Theme.ok : Theme.warn)
                Chip(label: "SAVES", value: session.indexed ? NumberFormatter.localizedString(from: NSNumber(value: session.total), number: .decimal) : "—",
                     color: session.indexed ? Theme.ok : Theme.warn)
            }
        }
    }

    private var windowCard: some View {
        Card(title: "Floating window") {
            HStack(spacing: 14) {
                LayerView()
                    .aspectRatio(overlay.shape.size.width / overlay.shape.size.height, contentMode: .fit)
                    .frame(maxWidth: 150, maxHeight: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                VStack(alignment: .leading, spacing: 8) {
                    Button(overlay.active ? "Hide" : "Show over TikTok") { overlay.toggle() }
                        .font(Theme.mono(13, .bold)).foregroundStyle(Theme.accent)
                    Text("⏯ start/stop · ⏪⏩ fine-tune · ⤢ back here").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                }
            }
            if !overlay.problem.isEmpty { Text(overlay.problem).font(Theme.mono(11)).foregroundStyle(Theme.bad) }
        }
    }

    private var goCard: some View {
        Card(title: "Go to") {
            if !session.indexed {
                RowButton(icon: "square.and.arrow.down", title: "Import TikTok export", detail: "user_data_tiktok.json from Files") { importing = true }
                RowButton(icon: "waveform.path", title: "Test dive", detail: "20 swipes. Leave TikTok on your Saved tab first.") { session.testDive() }
            } else {
                RowButton(icon: "calendar", title: "A year or month", detail: "with save counts") { picker = .month }
                RowButton(icon: "calendar.day.timeline.left", title: "A day", detail: "year › month › day") { picker = .day }
                RowButton(icon: "clock", title: "A time of day", detail: "year › month › day › hour") { picker = .time }
                if let last = session.lastLanding {
                    RowButton(icon: "arrow.uturn.backward", title: "Last landing", detail: "saved \(last)") {
                        Task { await session.plan("last-landing") }
                    }
                }
                RowButton(icon: "link", title: "The copied video", detail: "copy a link in TikTok first (Share › Copy link)") {
                    if let clip = Session.clipboard() { Task { await session.plan(clip) } } else { session.message = "Copy a video link in TikTok first." }
                }
                ForEach(Array(session.pins.prefix(3).enumerated()), id: \.offset) { i, p in
                    RowButton(icon: "mappin", title: i == 0 ? "Last checkpoint" : "Checkpoint", detail: p["label"] as? String ?? "") {
                        Task { await session.plan(i == 0 ? "pin" : "pin:\(i)") }
                    }
                    .contextMenu {
                        Button("Remove checkpoint", systemImage: "trash", role: .destructive) {
                            Task { await session.unpin(i) }
                        }
                    }
                }
                if session.hasPending {
                    RowButton(icon: "scope", title: "Check where I landed", detail: "after copying a link near the top", tint: Theme.accent) { Task { await session.checkLanded() } }
                }
                RowButton(icon: "pin", title: "Pin the copied video", detail: "a checkpoint to come back to") { Task { await session.pinCopied() } }
            }
        }
    }

    private func armedCard(_ label: String) -> some View {
        Card(title: "Ready to go") {
            Text(label).font(Theme.mono(15, .bold)).foregroundStyle(Theme.text)
            Text(session.autoLocate ? "Leave TikTok on your Saved grid. Go finds your current position." :
                "Leave TikTok on your Saved grid, then choose a starting point.")
                .font(Theme.mono(10)).foregroundStyle(Theme.warn)
            if session.autoLocate {
                PrimaryButton(title: "Go", icon: "location.fill") { session.go(.automatic) }
            } else {
                PrimaryButton(title: "Go up first, then dive", icon: "arrow.up.and.down") { session.go(.viaTop) }
            }
            RowButton(icon: "arrow.up.to.line", title: "Saved is at the very top", detail: "it just opened") { session.go(.top) }
            RowButton(icon: "doc.on.clipboard", title: "From the video I copied", detail: "fastest when you're far down") { session.go(.copied) }
        }
    }
}

// MARK: - Go-to picker (year › month › day)
struct GoToSheet: View {
    enum Mode: String, Identifiable { case month, day, time; var id: String { rawValue } }
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [[String: Any]] = []
    @State private var year: Int?
    @State private var month: Int?
    @State private var day: Int?
    @State private var loading = true
    private let monthNames = Calendar(identifier: .gregorian).monthSymbols

    var body: some View {
        NavigationStack {
            List {
                if mode == .month, let year, month == nil {
                    Button("Jump to \(year)") { go(String(year)) }
                        .listRowBackground(Theme.panel)
                        .disabled(loading)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    Button { pick(r) } label: {
                        HStack {
                            Text(title(r)).font(Theme.mono(15, .semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(r["count"] as? Int ?? 0)").font(Theme.mono(13)).foregroundStyle(Theme.dim)
                        }
                    }
                    .listRowBackground(Theme.panel)
                    .disabled(loading)
                }
            }
            .overlay { if loading { ProgressView() } }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(sectionTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if year != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") { goBack() }
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .task { await refreshRows() }
    }

    private var sectionTitle: String {
        guard let year else { return "Year" }
        guard let month else { return String(year) }
        if let day { return "\(day) \(monthNames[month - 1]) \(year)" }
        return "\(monthNames[month - 1]) \(year)"
    }

    private func title(_ r: [String: Any]) -> String {
        if let h = r["hour"] as? Int { return String(format: "%02d:00", h) }
        if let d = r["day"] as? Int { return String(format: "%02d", d) }
        if let m = r["month"] as? Int { return monthNames[m - 1] }
        return "\(r["year"] as? Int ?? 0)"
    }

    private func pick(_ r: [String: Any]) {
        if let h = r["hour"] as? Int, let y = year, let m = month, let d = day {
            go(String(format: "%04d-%02d-%02dT%02d", y, m, d, h)); return
        }
        if let d = r["day"] as? Int, let y = year, let m = month {
            if mode == .time {
                day = d
                reload()
                return
            }
            go(String(format: "%04d-%02d-%02d", y, m, d)); return
        }
        if let m = r["month"] as? Int, let y = year {
            if mode == .month { go(String(format: "%04d-%02d", y, m)); return }
            month = m
            reload()
            return
        }
        if let y = r["year"] as? Int {
            year = y
            reload()
        }
    }

    private func goBack() {
        if day != nil { day = nil }
        else if month != nil { month = nil }
        else { year = nil }
        reload()
    }

    private func reload() {
        loading = true
        rows = []
        Task { await refreshRows() }
    }

    private func refreshRows() async {
        let y = year, m = month, d = day
        let result = await Session.shared.calendar(year: y, month: m, day: d)
        guard !Task.isCancelled, year == y, month == m, day == d else { return }
        rows = result
        loading = false
    }

    private func go(_ target: String) {
        dismiss()
        Task { await Session.shared.plan(target) }
    }
}

// MARK: - Settings
struct SettingsView: View {
    @ObservedObject var engine = Engine.shared
    @ObservedObject var overlay = Overlay.shared
    @ObservedObject var pairing = Pairing.shared
    @ObservedObject var ddi = DiskImage.shared
    @ObservedObject var refresher = Refresher.shared
    @State private var code = ""
    @State private var appleID = ""
    @State private var applePassword = ""
    @State private var importingPairing = false
    @AppStorage("calibrate-swipe-timing") private var calibrateSwipeTiming = false
    @AppStorage("verify-wide-landing") private var verifyWideLanding = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "Floating window lab") {
                    Text("Pick the shape you like. Smaller shapes sit smaller over TikTok (you can also pinch it).")
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                    Picker("Shape", selection: $overlay.shape) {
                        ForEach(PipShape.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle(isOn: $overlay.skipButtons) {
                        VStack(alignment: .leading) {
                            Text("Skip buttons ⏪ ⏩").font(Theme.mono(13, .semibold))
                            Text("5 swipes up / down. Turn on if they don't show.").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        }
                    }
                    Label(KeepAlive.running ? "Runs behind TikTok: on" : "Runs behind TikTok: off", systemImage: KeepAlive.running ? "checkmark.circle" : "xmark.circle")
                        .font(Theme.mono(11)).foregroundStyle(KeepAlive.running ? Theme.ok : Theme.bad)
                }
                Card(title: "Automatic window (Shortcuts)") {
                    Text("Shortcuts › Automation › + › App › TikTok:\n• Is Opened › Run Immediately › Show Saved Scroll window\n• Is Closed › Run Immediately › Hide Saved Scroll window\nBack Tap (optional): Settings › Accessibility › Touch › Back Tap › Double Tap › Saved Scroll menu")
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
                Card(title: "Swipe calibration") {
                    Toggle("Collect timing trials", isOn: $calibrateSwipeTiming)
                    Text("Uses short test legs at 1.0, 1.15, or 1.4 seconds per swipe. Leave this off for regular jumps.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
                Card(title: "Landing verification") {
                    Toggle("Verify across more saves", isOn: $verifyWideLanding)
                    Text("Checks a wider stretch of the grid before confirming. Useful after re-saving a group of older videos.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.dim)
                }
                Card(title: "Stay signed") {
                    Text(refresher.summary).font(Theme.mono(12)).foregroundStyle(Theme.text)
                    if refresher.hasAccount {
                        Text("Renews itself when 3 days are left (\(refresher.email)). Keep LocalDevVPN on.").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                        if refresher.state == "need_code" {
                            Text(refresher.detail).font(Theme.mono(11))
                            TextField("6-digit code", text: $code).keyboardType(.numberPad).font(Theme.mono(16))
                            Button("Send code") { refresher.submit(code: code); code = "" }
                        } else if ["login", "signing", "installing"].contains(refresher.state) {
                            ProgressView(value: Double(refresher.progress), total: 100) { Text("Renewing… (the app closes when it's done)").font(Theme.mono(10)) }
                        } else {
                            Button("Renew now") { refresher.start() }.font(Theme.mono(13, .bold))
                        }
                    } else {
                        TextField("Apple ID email", text: $appleID).textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        SecureField("Password", text: $applePassword).textContentType(.password)
                        Button("Save and renew now") {
                            refresher.saveAccount(email: appleID, password: applePassword); applePassword = ""; refresher.start()
                        }.disabled(appleID.isEmpty || applePassword.isEmpty)
                    }
                    if !refresher.error.isEmpty { Text(refresher.error).font(Theme.mono(10)).foregroundStyle(Theme.bad) }
                }
                Card(title: "This iPhone") {
                    Label(engine.hasPairing ? "Paired" : "Not paired", systemImage: engine.hasPairing ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(Theme.mono(12)).foregroundStyle(engine.hasPairing ? Theme.ok : Theme.warn)
                    if pairing.active {
                        if pairing.state == "code" { Text(pairing.code).font(Theme.mono(40, .bold)) }
                        Text("Settings › Privacy & Security › Developer Mode › Pair with Saved Scroll, then type the code.").font(Theme.mono(10)).foregroundStyle(Theme.dim)
                    } else {
                        Button(engine.hasPairing ? "Pair again" : "Pair this iPhone") { pairing.start() }.font(Theme.mono(13, .bold))
                    }
                    if !pairing.detail.isEmpty { Text(pairing.detail).font(Theme.mono(10)).foregroundStyle(Theme.dim) }
                    Label(ddi.state == "ready" ? "Disk image ready" : ddi.state == "downloading" ? "Downloading disk image…" : "Disk image not downloaded",
                          systemImage: ddi.state == "ready" ? "checkmark.circle" : "arrow.down.circle").font(Theme.mono(11))
                    if ddi.state == "failed" { Button("Retry download") { ddi.ensure() }.font(Theme.mono(11)) }
                    Button("Import a pairing record…") { importingPairing = true }.font(Theme.mono(11))
                }
                Card(title: "Diagnostics") {
                    Text(diagnostics).font(Theme.mono(10)).foregroundStyle(Theme.dim).textSelection(.enabled)
                    Button("Test dive (20 swipes in TikTok)") { Session.shared.testDive() }.font(Theme.mono(12, .bold))
                }
            }
            .padding(16)
        }
        .background(Theme.bg.ignoresSafeArea())
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $importingPairing, allowedContentTypes: [.propertyList, .data, .item]) { result in
            if case .success(let url) = result { engine.importPairing(from: url) }
        }
        .onAppear { if appleID.isEmpty { appleID = refresher.suggestedEmail } }
    }

    private var diagnostics: String {
        let st = engine.status
        let keys = ["connected", "busy", "done", "planned", "error"]
        return keys.map { "\($0): \(st[$0].map { "\($0)" } ?? "-")" }.joined(separator: "\n")
            + "\nwindow: \(overlay.active ? "up" : "down") · shape \(overlay.shape.rawValue) · skip \(overlay.skipButtons ? "on" : "off")"
    }
}
