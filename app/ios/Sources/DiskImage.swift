import Foundation

/// Downloads Apple's developer disk image (Personalized variant, ~16 MB) once, into Documents/ddi.
/// The engine mounts it after each reboot (phone.rs `ensure_ddi`); developer services need it.
/// Source: github.com/doronz88/DeveloperDiskImage (the files Xcode ships, split for non-Mac tools).
final class DiskImage: ObservableObject {
    static let shared = DiskImage()
    static let base = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/main/PersonalizedImages/Xcode_iOS_DDI_Personalized/")!
    static let files = ["BuildManifest.plist", "Image.dmg.trustcache", "Image.dmg"]

    @Published var state = "unknown"     // ready | downloading | failed

    var dir: URL { Engine.shared.pairingURL.deletingLastPathComponent().appendingPathComponent("ddi") }
    var ready: Bool { DiskImage.files.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) } }

    func ensure() {
        if ready { state = "ready"; return }
        guard state != "downloading" else { return }
        state = "downloading"
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in DiskImage.files where !FileManager.default.fileExists(atPath: dir.appendingPathComponent(f).path) {
                    let (tmp, resp) = try await URLSession.shared.download(from: DiskImage.base.appendingPathComponent(f))
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent(f))   // whole file or nothing
                }
                await MainActor.run { self.state = "ready" }
            } catch {
                await MainActor.run { self.state = "failed" }
            }
        }
    }
}
