import AVFoundation

/// Keeps the app (and the engine's HTTP server) running behind TikTok, independent of the floating window:
/// a silent, looping, mixable audio player (the "audio" background mode). It never interrupts TikTok's sound.
enum KeepAlive {
    private static var engine: AVAudioEngine?
    static var running: Bool { engine?.isRunning == true }

    static func start() {
        if running { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)
        let e = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = e.mainMixerNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { return }
        buffer.frameLength = buffer.frameCapacity              // one second of silence (zeros)
        e.attach(player)
        e.connect(player, to: e.mainMixerNode, format: format)
        e.mainMixerNode.outputVolume = 0
        do { try e.start() } catch { return }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        engine = e
        // Restart after interruptions (calls, Siri) end.
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { n in
            let type = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            if type == .ended { engine?.stop(); engine = nil; start() }
        }
    }
}
