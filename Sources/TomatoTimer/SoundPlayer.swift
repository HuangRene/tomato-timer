import AppKit

enum SoundPlayer {
    /// Keeps sounds alive until they finish playing.
    private static var playing: [NSSound] = []

    /// Three chimes: "Glass" when work ends, "Hero" when the break ends.
    static func playAlert(for phase: Phase) {
        let name = phase == .work ? "Glass" : "Hero"
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.7) {
                guard let sound = NSSound(named: name)?.copy() as? NSSound else { return }
                playing.append(sound)
                sound.play()
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    playing.removeAll { $0 === sound }
                }
            }
        }
    }
}
