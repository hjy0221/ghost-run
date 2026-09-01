import Foundation

struct GameConfiguration {
    static let standard = GameConfiguration()
    var preparationDuration = 10
    var initialGhosts = 6
    var secondWaveGhosts = 10
    var maximumGhosts = 14
    var secondGhostTime = 90
    var thirdGhostTime = 240
    var ghostsPerSpawn = 2
    var successfulSpawnInterval = 2.0
    var ghostSpawnSpacing = 24.0
    var maximumConcurrentPursuitRoutes = 2
    var spawnDistance: ClosedRange<Double> = 100...250
    var minimumSpawnSeparation = 80.0
    var safeLightDistance: ClosedRange<Double> = 130...220
    var safeLightRadius = 18.0
    var safeLightDuration = 12
    var wardDuration = 4
    var startingAmmo = 3
    var maximumAmmo = 3
    var supplyAmmo = 3
    var shotRange = 60.0
    var shotCooldown = 2.0
    var shotTravelDuration = 0.4
    var defeatedGhostRespawnDelay = 20.0
    var defeatedGhostRespawnMovement = 30.0
    var pulseChargeDistance = 200.0
    var pulseDuration = 8
    var warmupDuration = 60
    var pursuitDuration = 60
    var recoveryDuration = 30
    var baseGhostSpeed = 1.35
    var maximumGhostSpeed = 2.35
    var routeRefreshInterval = 8.0
    var playerMovementForReroute = 25.0
    var maximumRouteAge = 24.0
    var routeRetryInterval = 15.0
    var routeFailureDespawnInterval = 60.0
    var globalRoutingInterval = 3.0
    var routingTimeout = 15.0
    var routeStartTolerance = 3.0
    var routeEndpointTolerance = 25.0
    var routeMatchTolerance = 8.0
    var maximumRouteLength = 2_000.0
    var safeDistance = 250.0
    var watchDistance = 150.0
    var dangerDistance = 70.0
    var catchDistance = 15.0
    var catchGraceDuration = 3
    var catchAccuracy = 12.0
    var catchFixMaximumAge = 6.0
    var maximumLocationAccuracy = 25.0
    var maximumMovementSpeed = 8.0
    var maximumFixAge = 10.0
    var locationRecoveryGraceDuration = 3.0
    var motionInterval = 0.25
    var obstacleQueryRadius = 650.0
    var obstacleCacheDuration = 300.0
    var obstacleRequestInterval = 60.0
    var obstacleClearance = 2.0
    var obstacleGridSize = 5.0

    func ghostCount(at elapsedSeconds: Int) -> Int {
        min(maximumGhosts, elapsedSeconds >= thirdGhostTime ? maximumGhosts
            : elapsedSeconds >= secondGhostTime ? secondWaveGhosts : initialGhosts)
    }

    func rhythm(at seconds: Int) -> RunRhythm {
        if seconds < warmupDuration { return .warmup }
        let offset = (seconds - warmupDuration) % max(1, pursuitDuration + recoveryDuration)
        return offset < pursuitDuration ? .pursuit : .recovery
    }
}

enum RunRhythm {
    case warmup, pursuit, recovery
    var title: String {
        switch self {
        case .warmup: "적응 · 편하게 출발"
        case .pursuit: "이동 · 내 속도로"
        case .recovery: "회복 · 숨 고르기"
        }
    }
    var speedMultiplier: Double {
        switch self {
        case .warmup: 0.8
        case .pursuit: 1
        case .recovery: 0.6
        }
    }
}

enum DangerLevel: String {
    case unknown = "ROUTING"
    case safe = "SAFE"
    case watch = "WATCH"
    case danger = "DANGER"
    case critical = "CRITICAL"
    case caught = "CAUGHT"

    static func evaluate(distance: Double?, configuration: GameConfiguration) -> DangerLevel {
        guard let distance else { return .unknown }
        if distance >= configuration.safeDistance { return .safe }
        if distance >= configuration.watchDistance { return .watch }
        if distance >= configuration.dangerDistance { return .danger }
        return .critical // CAUGHT is a timed decision, never just a distance.
    }

    var feedbackInterval: Int? {
        switch self {
        case .unknown, .safe, .caught: return nil
        case .watch: return 20
        case .danger: return 8
        case .critical: return 3
        }
    }
}
