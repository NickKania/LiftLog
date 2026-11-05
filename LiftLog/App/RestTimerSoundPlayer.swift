import AVFoundation

/// A short media sound, using the current output route and media volume.
@MainActor
final class RestTimerSoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let resourceName = "rest-complete.wav"
    private var player: AVAudioPlayer?
    var isPlaying: Bool { player?.isPlaying == true }

    func play() throws {
        guard let url = Bundle.main.url(forResource: Self.resourceName, withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let nextPlayer = try AVAudioPlayer(contentsOf: url)
        nextPlayer.delegate = self
        nextPlayer.prepareToPlay()

        let session = AVAudioSession.sharedInstance()
        // Playback follows headphones/Bluetooth and is audible in silent mode.
        // Mixing lets the user's music continue during the chime.
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        player = nextPlayer
        guard nextPlayer.play() else {
            finishPlayback(nextPlayer)
            throw CocoaError(.fileReadUnknown)
        }
    }

    private func finishPlayback(_ finishedPlayer: AVAudioPlayer) {
        guard player === finishedPlayer else { return }
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.finishPlayback(player) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in self?.finishPlayback(player) }
    }
}
