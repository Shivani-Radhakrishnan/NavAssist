import BlindNavCore
import UIKit

/// Vibration patterns, so directions can be felt as well as heard:
/// left = 2 taps, right = 3 taps, on track = 1 soft tap, obstacle = heavy thud.
final class Haptics {
    var enabled = true

    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    func play(_ cue: HapticCue) {
        guard enabled else { return }
        switch cue {
        case .turnLeft: taps(2, medium)
        case .turnRight: taps(3, medium)
        case .onTrack: light.impactOccurred(intensity: 0.6)
        case .waypoint: medium.impactOccurred()
        case .arrived: notify.notificationOccurred(.success)
        case .offRoute: notify.notificationOccurred(.warning)
        case .obstacle: heavy.impactOccurred()
        case .stop: taps(4, heavy, gap: 0.08)
        }
    }

    private func taps(_ n: Int, _ g: UIImpactFeedbackGenerator, gap: Double = 0.15) {
        for i in 0..<n {
            DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(i)) { g.impactOccurred() }
        }
    }
}
