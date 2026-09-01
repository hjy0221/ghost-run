import CoreLocation
import Foundation

enum GamePhase: String {
    case briefing
    case countdown
    case running
    case paused
    case summary
}

enum PauseReason: Equatable {
    case gpsSignalLost
    case implausibleMovement
    case appBackgrounded
    case userPaused

    var title: String {
        switch self {
        case .gpsSignalLost:
            return "위치 신호 확인 중"
        case .implausibleMovement:
            return "이동 상태 확인"
        case .appBackgrounded:
            return "러닝 일시 정지"
        case .userPaused:
            return "잠시 멈춤"
        }
    }

    var message: String {
        switch self {
        case .gpsSignalLost:
            return "안전한 곳에서 GPS 신호가 돌아올 때까지 기다려 주세요."
        case .implausibleMovement:
            return "위치가 크게 바뀌거나 너무 빠른 이동이 감지되어 게임을 멈췄습니다. 차량에서는 플레이하지 마세요. 안전한 보행 공간에서 위치가 안정된 뒤 재개하세요."
        case .appBackgrounded:
            return "백그라운드에서는 추격과 점수 계산을 멈춥니다. 앱으로 돌아와 주변을 확인한 뒤 재개하세요."
        case .userPaused:
            return "주변을 확인한 뒤 준비가 되면 다시 시작하세요."
        }
    }
}

enum FinishReason: String {
    case caught
    case exhausted
    case userEnded

    var title: String {
        switch self {
        case .caught:
            return "유령에게 붙잡혔습니다"
        case .exhausted:
            return "에너지가 소진되었습니다"
        case .userEnded:
            return "러닝을 종료했습니다"
        }
    }
}

enum WorldEntityKind: String {
    case ghost
    case safeLight
    var isSupply: Bool { self == .safeLight }
}

struct GhostNavigation {
    var cursor: WalkingCursor
    let playerTarget: CLLocationCoordinate2D
    let calculatedAt: Date
}

// Retain the existing generic world entity and identity; route state replaces
// the old tactical direct-chase offsets.
struct WorldEntity: Identifiable {
    let id: UUID
    var kind: WorldEntityKind
    var coordinate: CLLocationCoordinate2D
    var radius: CLLocationDistance
    var speed: CLLocationSpeed
    var navigation: GhostNavigation?
    var safePath: WalkingPath?

    init(id: UUID = UUID(), kind: WorldEntityKind, coordinate: CLLocationCoordinate2D,
         radius: CLLocationDistance, speed: CLLocationSpeed = 0,
         navigation: GhostNavigation? = nil, safePath: WalkingPath? = nil) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.radius = radius
        self.speed = speed
        self.navigation = navigation
        self.safePath = safePath
    }
}

struct SessionResult {
    var reason: FinishReason
    var survivedSeconds: Int
    var distanceMeters: Double
    var score: Int
    var cachesCollected: Int
    var peakPressure: Double
    var usedSimulation: Bool
    var isNewHighScore: Bool
    var movingSeconds: Int = 0
    var movementBonus: Int = 0
    var escapes: Int = 0
}

// A short-lived visual and pending impact, never persisted with the run record.
struct LightShot: Identifiable {
    let id = UUID()
    let targetID: UUID
    let path: WalkingPath
    let firedAt: Date
    let duration: TimeInterval

    func progress(at date: Date) -> Double {
        max(0, min(1, date.timeIntervalSince(firedAt) / max(0.01, duration)))
    }
}

// Only aggregate progress, no coordinates or player profile. Kept in memory.
struct MovementRewards {
    private(set) var milestones = 0
    private(set) var escapes = 0
    var score: Int { milestones * 50 + escapes * 120 }

    mutating func creditDistance(_ meters: Double) -> Int {
        let reached = Int(max(0, meters) / 100)
        let newMilestones = max(0, reached - milestones)
        milestones += newMilestones
        return newMilestones
    }

    mutating func creditEscape() { escapes += 1 }
}

enum GameEventTone {
    case signal
    case warning
    case supply
    case neutral
}

struct GameEvent: Identifiable {
    let id = UUID()
    let message: String
    let tone: GameEventTone
}
