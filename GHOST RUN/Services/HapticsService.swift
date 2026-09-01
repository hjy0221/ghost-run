import UIKit
import AVFoundation

enum HapticsService {
    private static let speech = AVSpeechSynthesizer()

    static func danger(_ level: DangerLevel) {
        if isEnabled {
            switch level {
            case .watch: UIImpactFeedbackGenerator(style: .light).impactOccurred()
            case .danger: UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            case .critical: UINotificationFeedbackGenerator().notificationOccurred(.warning)
            case .safe, .unknown, .caught: break
            }
        }
        if level == .critical, UserDefaults.standard.bool(forKey: "soundEnabled"), !speech.isSpeaking {
            let utterance = AVSpeechUtterance(string: "유령 접근. 주변 안전을 확인하세요.")
            utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
            speech.speak(utterance)
        }
    }

    static func stopSound() { speech.stopSpeaking(at: .immediate) }
    private static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    static func signal() {
        guard isEnabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func supply() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func failure() {
        guard isEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}
