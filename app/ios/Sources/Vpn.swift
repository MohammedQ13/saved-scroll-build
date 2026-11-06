import Foundation
import Network
import UIKit

/// LocalDevVPN makes 10.7.0.1 reach this iPhone's own developer services. If it's off when the app opens,
/// we turn it on through its URL (`localdevvpn://enable?scheme=savedscroll`): LocalDevVPN starts and
/// bounces straight back here, about a second, no taps.
enum Vpn {
    /// Quick check: can we open TCP to the phone's RemoteXPC port through the VPN?
    static func reachable(timeout: TimeInterval = 1.0) async -> Bool {
        await withCheckedContinuation { cont in
            let conn = NWConnection(host: "10.7.0.1", port: 49152, using: .tcp)
            var done = false
            let finish: (Bool) -> Void = { ok in
                if done { return }
                done = true
                conn.cancel()
                cont.resume(returning: ok)
            }
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            conn.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Turn LocalDevVPN on if needed (foreground only: it switches apps for a moment).
    @MainActor
    static func ensureOn() async {
        guard Engine.shared.hasPairing else { return }
        if await reachable() { return }
        if let url = URL(string: "localdevvpn://enable?scheme=savedscroll") {
            await UIApplication.shared.open(url)
        }
    }
}
