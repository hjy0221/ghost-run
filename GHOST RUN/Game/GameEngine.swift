import Combine
import CoreLocation
import Foundation

@MainActor
final class GameEngine: ObservableObject {
    @Published private(set) var phase: GamePhase = .briefing
    @Published private(set) var pauseReason: PauseReason?
    @Published private(set) var countdownSeconds: Int
    @Published private(set) var isWaitingForGPS = false
    @Published private(set) var isRecoveringLocation = false
    @Published private(set) var playerLocation: CLLocation?
    @Published private(set) var routeCoordinates: [CLLocationCoordinate2D] = []
    @Published private(set) var entities: [WorldEntity] = []
    @Published private(set) var elapsedSeconds = 0
    @Published private(set) var distanceMeters = 0.0
    @Published private(set) var currentSpeed = 0.0
    @Published private(set) var pressure = 8.0
    // Energy is distance-earned pulse charge, not a health/fitness measurement.
    @Published private(set) var energy = 0.0
    @Published private(set) var ammo = 3
    @Published private(set) var shots: [LightShot] = []
    @Published private(set) var pulseSecondsRemaining = 0
    @Published private(set) var wardCharges = 1
    @Published private(set) var wardSecondsRemaining = 0
    @Published private(set) var safeLightSecondsRemaining = 0
    @Published private(set) var dangerLevel: DangerLevel = .unknown
    @Published private(set) var routingStatus = "주변 건물 지도 확인 중"
    @Published private(set) var isRoutingSuspended = true
    @Published private(set) var catchSeconds = 0

    @Published private(set) var cachesCollected = 0
    @Published private(set) var movingSeconds = 0
    @Published private(set) var movementRewards = MovementRewards()
    @Published private(set) var peakPressure = 8.0
    @Published private(set) var currentEvent: GameEvent?
    @Published private(set) var result: SessionResult?
    @Published private(set) var bestScore = UserDefaults.standard.integer(forKey: "bestScore")
    @Published private(set) var bestDistance = UserDefaults.standard.double(forKey: "bestDistance")
    @Published private(set) var longestSurvival = UserDefaults.standard.integer(forKey: "longestSurvival")
    @Published private(set) var completedRuns = UserDefaults.standard.integer(forKey: "completedRuns")

    let locationService: any GameLocationSource
    private let now: () -> Date
    private let automaticallyTicks: Bool
    private var lastSeenLocationTime: Date?
    private var lastObservedLocation: CLLocation?
    private var catchAllowedAfter = Date.distantPast
    private var lastMovementTime: Date?
    private var sessionUsedSimulation = false
    private var escapeAttempt: (id: UUID, distanceAtStart: Double, startTime: Int)?
    private var nextEscapeTime = 0
    private var nextWarningTime = 0
    private var nextSupplySkipTime = 0
    let configuration: GameConfiguration
    private let routingService: any WalkingRouteProviding
    private var navigationTasks: [UUID: Task<Void, Never>] = [:]
    private var lastRouteAttempts: [UUID: Date] = [:]
    private var routeFailureSince: [UUID: Date] = [:]
    private var contactSeconds: [UUID: Int] = [:]
    private var spawnTask: Task<Void, Never>?
    private var safeLightTask: Task<Void, Never>?
    private var spawnRetryAfter = Date.distantPast
    private var lightRetryAfter = Date.distantPast
    private var spawnBearing = 0.0
    private var lastShotAt = Date.distantPast
    private var respawnDistanceThreshold = 0.0
    private var respawnTimeThreshold = Date.distantPast
    private var worldGeneration = UUID()
    private var motionTicker: AnyCancellable?
#if DEBUG
    @Published var showsDebugRoutes = false
    @Published var showsDebugObstacles = false
    @Published var debugGhostSpeed: Double? = nil
    @Published var debugDangerOverride: DangerLevel? = nil
#endif

    private var ticker: AnyCancellable?
    private var locationSubscription: AnyCancellable?
    private var locationErrorSubscription: AnyCancellable?
    private var lastAcceptedLocation: CLLocation?
    private var phaseBeforePause: GamePhase = .running
    private var eventTicksRemaining = 0
    private var random = SeededGenerator(seed: 0x4E49474854534947)
    var countdownDuration: Int { configuration.preparationDuration }
    private var countdownDeadline: Date?

    init(
        locationService: any GameLocationSource,
        now: @escaping () -> Date = Date.init,
        automaticallyTicks: Bool = true,
        configuration: GameConfiguration = .standard,
        routingService: (any WalkingRouteProviding)? = nil
    ) {
        self.configuration = configuration
        self.routingService = routingService ?? GhostRoutingService(configuration: configuration)
        countdownSeconds = configuration.preparationDuration
        ammo = configuration.startingAmmo
        self.locationService = locationService
        self.now = now
        self.automaticallyTicks = automaticallyTicks
        locationSubscription = locationService.locations
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.ingest(location)
            }
        locationErrorSubscription = locationService.errors
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard self?.phase != .briefing, self?.phase != .summary else { return }
                self?.postEvent("GPS 오류: \(message)", tone: .warning)
            }
    }

    var score: Int {
        Int(distanceMeters * 1.2)
            + elapsedSeconds * 2
            + cachesCollected * 80
            + movementRewards.score
    }

    var metersToNextBonus: Int { max(1, Int(ceil(Double(movementRewards.milestones + 1) * 100 - distanceMeters))) }

    var nearestSupply: WorldEntity? {
        guard let coordinate = playerLocation?.coordinate else { return nil }
        return entities.filter { $0.kind == .safeLight }.min {
            GeoMath.distance(from: coordinate, to: $0.coordinate) < GeoMath.distance(from: coordinate, to: $1.coordinate)
        }
    }

    var canSkipSupply: Bool { phase == .paused && nearestSupply != nil && elapsedSeconds >= nextSupplySkipTime }

    func skipInaccessibleSupply() {
        guard canSkipSupply, let supply = nearestSupply else { return }
        entities.removeAll { $0.id == supply.id }
        lightRetryAfter = now()
        nextSupplySkipTime = elapsedSeconds + 20
        postEvent("보급 지점을 건너뛰었습니다. 재개 후 다른 보행 경로를 확인합니다.", tone: .neutral)
    }

    var nearestThreatDistance: CLLocationDistance? {
        entities.filter { $0.kind == .ghost }.compactMap { routeDistance(to: $0) }.min()
    }

    var ghostCount: Int { entities.filter { $0.kind == .ghost }.count }

    func routeDistance(to ghost: WorldEntity) -> Double? {
        guard let player = playerLocation, let navigation = ghost.navigation,
              now().timeIntervalSince(navigation.calculatedAt) <= configuration.maximumRouteAge else { return nil }
        if let map = navigation.cursor.path.obstacleMap {
            guard now().timeIntervalSince(map.fetchedAt) <= configuration.obstacleCacheDuration,
                  map.isClear(from: ghost.coordinate, to: ghost.coordinate),
                  map.isClear(from: player.coordinate, to: player.coordinate) else { return nil }
            if map.isClear(from: ghost.coordinate, to: player.coordinate) {
                return GeoMath.distance(from: ghost.coordinate, to: player.coordinate)
            }
            let end = navigation.cursor.path.coordinates.last!
            guard map.isClear(from: end, to: player.coordinate) else { return nil }
            return navigation.cursor.remainingDistance + GeoMath.distance(from: end, to: player.coordinate)
        }
        let match = navigation.cursor.path.projection(of: player.coordinate)
        guard match.separation <= configuration.routeMatchTolerance else { return nil }
        return abs(match.offset - navigation.cursor.distanceAlongRoute)
    }

    var safeLightRouteDistance: Double? {
        guard let light = nearestSupply, let path = light.safePath, let player = playerLocation else { return nil }
        let match = path.projection(of: player.coordinate)
        guard match.separation <= configuration.routeMatchTolerance else { return nil }
        return max(0, path.length - match.offset)
    }

    var isProtected: Bool { wardSecondsRemaining > 0 || safeLightSecondsRemaining > 0 || pulseSecondsRemaining > 0 }
    var protectionSeconds: Int { max(wardSecondsRemaining, safeLightSecondsRemaining, pulseSecondsRemaining) }
    var runRhythm: RunRhythm { configuration.rhythm(at: elapsedSeconds) }
    var metersToPulse: Int { max(0, Int(ceil((100 - energy) / 100 * configuration.pulseChargeDistance))) }
    var canUsePulse: Bool { canUseAction && energy >= 100 && !isProtected }
    private var canUseAction: Bool {
        phase == .running && !isRecoveringLocation && hasFreshLocation
            && (playerLocation?.horizontalAccuracy ?? .infinity) <= configuration.catchAccuracy
            && now().timeIntervalSince(playerLocation?.timestamp ?? .distantPast) <= configuration.catchFixMaximumAge
    }

    var aimedGhost: WorldEntity? {
        guard canUseAction else { return nil }
        return entities.filter { $0.kind == .ghost && shotPath(to: $0) != nil }.min {
            GeoMath.distance(from: playerLocation!.coordinate, to: $0.coordinate)
                < GeoMath.distance(from: playerLocation!.coordinate, to: $1.coordinate)
        }
    }

    var canFire: Bool {
        canUseAction && ammo > 0 && shots.isEmpty
            && now().timeIntervalSince(lastShotAt) >= configuration.shotCooldown && aimedGhost != nil
    }

    var fireHint: String {
        if !canUseAction { return "정확한 위치 대기" }
        if ammo == 0 { return "보급 지점으로 이동" }
        if !shots.isEmpty { return "탄환 이동 중" }
        if now().timeIntervalSince(lastShotAt) < configuration.shotCooldown { return "다음 사격 준비 중" }
        return aimedGhost == nil ? "시야 안 \(Int(configuration.shotRange))m" : "가까운 유령 자동 조준"
    }

    private func shotPath(to ghost: WorldEntity) -> WalkingPath? {
        guard let player = playerLocation, let navigation = ghost.navigation,
              routeDistance(to: ghost) != nil, let map = navigation.cursor.path.obstacleMap,
              GeoMath.distance(from: player.coordinate, to: ghost.coordinate) <= configuration.shotRange,
              map.isClear(from: player.coordinate, to: ghost.coordinate) else { return nil }
        return WalkingPath(coordinates: [player.coordinate, ghost.coordinate], obstacleMap: map)
    }

    func fireAtNearestGhost() {
        guard canFire, let target = aimedGhost, let path = shotPath(to: target) else { return }
        ammo -= 1
        lastShotAt = now()
        shots = [LightShot(targetID: target.id, path: path, firedAt: now(), duration: configuration.shotTravelDuration)]
        // A pending path response must not change the locked target's position.
        navigationTasks[target.id]?.cancel()
        navigationTasks[target.id] = nil
        HapticsService.signal()
    }

    func activatePulse() {
        guard canUsePulse else { return }
        energy = 0
        pulseSecondsRemaining = configuration.pulseDuration
        contactSeconds.removeAll()
        catchSeconds = 0
        escapeAttempt = nil
        HapticsService.supply()
        postEvent("파동 · \(configuration.pulseDuration)초 동안 거리를 벌리세요", tone: .signal)
    }

    private func resolveShots() {
        guard canUseAction else {
            if !shots.isEmpty { cancelShots() }
            return
        }
        let impacts = shots.filter { $0.progress(at: now()) >= 1 }
        for shot in impacts {
            guard let ghost = entities.first(where: { $0.id == shot.targetID }), shotPath(to: ghost) != nil else { continue }
            entities.removeAll { $0.id == ghost.id }
            lastRouteAttempts[ghost.id] = nil
            routeFailureSince[ghost.id] = nil
            contactSeconds[ghost.id] = nil
            respawnTimeThreshold = now().addingTimeInterval(configuration.defeatedGhostRespawnDelay)
            respawnDistanceThreshold = distanceMeters + configuration.defeatedGhostRespawnMovement
            // No kill points or energy. Use the opening to keep moving.
            postEvent("유령 소멸 · 보급을 향해 이동하세요", tone: .signal)
        }
        let ids = Set(impacts.map(\.id))
        shots.removeAll { ids.contains($0.id) }
        catchSeconds = contactSeconds.values.max() ?? 0
    }

    private func cancelShots() {
        ammo = min(configuration.maximumAmmo, ammo + shots.count)
        shots.removeAll()
    }

    var locationAccuracyText: String {
        guard let location = playerLocation else { return "신호 대기" }
        if locationService.isSimulationEnabled { return "가상 위치" }
        return "±\(Int(max(0, location.horizontalAccuracy)))m"
    }

    var canStart: Bool {
        locationService.isSimulationEnabled
            || (locationService.isAuthorized && locationService.accuracyAuthorization == .fullAccuracy)
    }

    var canResumeSession: Bool {
        guard phase == .paused else { return false }
        return phaseBeforePause == .countdown || hasFreshLocation
    }

    func beginSession() {
        guard phase == .briefing else { return }
        guard canStart else {
            postEvent("위치 권한을 먼저 허용해 주세요.", tone: .warning)
            return
        }

        resetRuntimeState()
        sessionUsedSimulation = locationService.isSimulationEnabled
        locationService.setGameplayTrackingProfile(false)
        locationService.startTracking()
        if let current = locationService.currentLocation,
           isAcceptableForGameplay(current, maximumAge: configuration.maximumFixAge), current.speed <= configuration.maximumMovementSpeed {
            playerLocation = current
        } else {
            playerLocation = nil
        }
        phase = .countdown
        startTickerIfNeeded()
        postEvent("\(countdownDuration)초 동안 몸을 풀고 주변을 확인하세요.", tone: .signal)
    }

    func pauseByUser() {
        pause(reason: .userPaused)
    }

    func resume() {
        guard phase == .paused else { return }
        if phaseBeforePause == .running, !hasFreshLocation {
            locationService.setGameplayTrackingProfile(false)
            locationService.startTracking()
            postEvent("정확한 GPS 신호를 다시 잡고 있습니다.", tone: .warning)
            return
        }

        locationService.startTracking()
        locationService.setGameplayTrackingProfile(phaseBeforePause == .running)
        lastAcceptedLocation = playerLocation
        lastSeenLocationTime = playerLocation?.timestamp
        lastMovementTime = nil
        currentSpeed = 0
        phase = phaseBeforePause
        if phase == .countdown {
            countdownDeadline = now().addingTimeInterval(TimeInterval(countdownSeconds))
        }
        pauseReason = nil
        startTickerIfNeeded()
        postEvent("러닝을 다시 시작합니다.", tone: .signal)
    }

    func appDidBecomeInactive() {
        guard phase == .running || phase == .countdown else { return }
        pause(reason: .appBackgrounded)
    }

    func appDidEnterBackground() {
        if phase == .running || phase == .countdown {
            pause(reason: .appBackgrounded)
        }
        locationService.stopTracking()
    }

    func appDidBecomeActive() {
        guard phase == .paused else { return }
        locationService.setGameplayTrackingProfile(false)
        locationService.startTracking()
    }

    func activateWard() {
        guard phase == .running, hasFreshLocation, !isRecoveringLocation, wardCharges > 0, !isProtected else { return }
        wardCharges -= 1
        wardSecondsRemaining = configuration.wardDuration
        contactSeconds.removeAll()
        catchSeconds = 0
        escapeAttempt = nil
        nextEscapeTime = elapsedSeconds + configuration.wardDuration + 5
        HapticsService.signal()
        postEvent("WARD · \(configuration.wardDuration)초 동안 추격이 멈춥니다.", tone: .signal)
    }

    func endSession(reason: FinishReason = .userEnded) {
        guard phase != .briefing, phase != .summary else { return }
        cancelRouting()
        ticker?.cancel()
        ticker = nil
        locationService.stopTracking()

        let usedSimulation = sessionUsedSimulation
        let isNewHighScore = !usedSimulation && score > bestScore
        result = SessionResult(
            reason: reason,
            survivedSeconds: elapsedSeconds,
            distanceMeters: distanceMeters,
            score: score,
            cachesCollected: cachesCollected,
            peakPressure: peakPressure,
            usedSimulation: usedSimulation,
            isNewHighScore: isNewHighScore,
            movingSeconds: movingSeconds,
            movementBonus: movementRewards.score,
            escapes: movementRewards.escapes
        )
        if !usedSimulation {
            savePersonalBest()
        }
        phase = .summary
        clearWorld()
        if reason == .caught || reason == .exhausted {
            HapticsService.failure()
        }
    }

    func returnToBriefing() {
        cancelRouting()
        ticker?.cancel()
        ticker = nil
        locationService.stopTracking()
        result = nil
        currentEvent = nil
        phase = .briefing
        clearWorld()
    }

    private func startTickerIfNeeded() {
        guard automaticallyTicks, ticker == nil else { return }
        motionTicker = Timer.publish(every: configuration.motionInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.advanceGhosts(by: self.configuration.motionInterval)
            }
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.tick()
            }
    }

    private func cancelRouting() {
        cancelShots()
        HapticsService.stopSound()
        worldGeneration = UUID()
        navigationTasks.values.forEach { $0.cancel() }
        navigationTasks.removeAll()
        spawnTask?.cancel()
        spawnTask = nil
        safeLightTask?.cancel()
        safeLightTask = nil
        routingService.cancelAll()
        motionTicker?.cancel()
        motionTicker = nil
        contactSeconds.removeAll()
        catchSeconds = 0
    }

    func tick() {
        if phase == .countdown || phase == .running {
            locationService.advanceSimulation(by: 1)
            if locationService.isSimulationEnabled, let location = locationService.currentLocation {
                // Consume this simulation step before pursuit; the publisher's
                // queued duplicate is rejected by its timestamp.
                ingest(location)
            }
        }
        ageCurrentEvent()

        switch phase {
        case .countdown:
            if hasFreshLocation { maintainWorld() }
            let oldCount = countdownSeconds
            let remaining = countdownDeadline?.timeIntervalSince(now()) ?? TimeInterval(countdownSeconds)
            countdownSeconds = max(0, Int(ceil(remaining)))
            if countdownSeconds != oldCount, (1...3).contains(countdownSeconds) { HapticsService.signal() }
            if countdownSeconds == 0 {
                startRunningIfLocationReady()
            }
        case .running:
            locationService.refreshStationaryFixIfNeeded()
            guard hasFreshLocation else {
                beginLocationRecovery()
                return
            }
            guard !isRecoveringLocation else { return }
            resolveShots()
            maintainWorld()
            isRoutingSuspended = nearestThreatDistance == nil
            if isRoutingSuspended {
                dangerLevel = .unknown
                HapticsService.stopSound()
                if routingStatus == "건물 회피 추격" || routingStatus == "추격 경로 준비 완료" {
                    routingStatus = "건물을 피할 경로 확인 중 · 추격/시간 정지"
                }
                contactSeconds.removeAll()
                catchSeconds = 0
                return // No free time/score while the route service is unavailable.
            }
            if !automaticallyTicks { advanceGhosts(by: 1) }
            advanceRunningState()
        case .briefing, .paused, .summary:
            break
        }
    }

    private var hasFreshLocation: Bool {
        guard let playerLocation else { return false }
        return (locationService.isSimulationEnabled || (locationService.isAuthorized
            && locationService.accuracyAuthorization == .fullAccuracy))
            && isAcceptableForGameplay(playerLocation, maximumAge: configuration.maximumFixAge)
            && playerLocation.speed <= configuration.maximumMovementSpeed
    }

    private func startRunningIfLocationReady() {
        guard hasFreshLocation, let playerLocation else {
            isWaitingForGPS = true
            return
        }

        isWaitingForGPS = false
        guard nearestThreatDistance != nil else {
            isRoutingSuspended = true
            maintainWorld()
            return
        }
        isRoutingSuspended = false
        phase = .running
        countdownDeadline = nil
        locationService.setGameplayTrackingProfile(true)
        lastAcceptedLocation = playerLocation
        lastSeenLocationTime = playerLocation.timestamp
        lastObservedLocation = playerLocation
        routeCoordinates = [playerLocation.coordinate]
        postEvent("RUN · 유령이 다가옵니다. 거리를 벌리세요.", tone: .warning)
        HapticsService.warning()
    }

    func ingest(_ location: CLLocation) {
        guard phase == .countdown || phase == .running || phase == .paused else { return }
        guard isAcceptableForGameplay(location, maximumAge: configuration.maximumFixAge) else { return }
        if let lastSeenLocationTime, location.timestamp <= lastSeenLocationTime { return }
        let previousFixTime = lastSeenLocationTime
        let previousObserved = lastObservedLocation
        lastSeenLocationTime = location.timestamp
        guard location.speed <= configuration.maximumMovementSpeed else {
            pause(reason: .implausibleMovement)
            playerLocation = nil
            return
        }
        if phase != .running {
            playerLocation = location
            lastObservedLocation = location
            if phase == .countdown, countdownSeconds == 0 {
                startRunningIfLocationReady()
            }
            return
        }

        // Freshness belongs to received fixes, not the displacement anchor.
        // An unknown speed (-1) at rest can leave that anchor unchanged for minutes.
        let gap = previousFixTime.map { location.timestamp.timeIntervalSince($0) } ?? .infinity
        if isRecoveringLocation || gap > configuration.maximumFixAge {
            cancelShots()
            lastAcceptedLocation = location
            lastObservedLocation = location
            playerLocation = location
            currentSpeed = 0
            lastMovementTime = nil
            isRecoveringLocation = false
            catchAllowedAfter = now().addingTimeInterval(configuration.locationRecoveryGraceDuration)
            contactSeconds.removeAll()
            catchSeconds = 0
            escapeAttempt = nil
            // Do not draw/credit an unobserved journey across a signal gap.
            routeCoordinates = [location.coordinate]
            postEvent("위치 연결 회복 · 자동으로 이어갑니다", tone: .signal)
            return
        }

        if let previousObserved {
            let sampleDelta = location.timestamp.timeIntervalSince(previousObserved.timestamp)
            let sampleDistance = location.distance(from: previousObserved)
            if sampleDelta > 0, sampleDistance / sampleDelta > configuration.maximumMovementSpeed {
                pause(reason: .implausibleMovement)
                playerLocation = nil
                return
            }
        }
        lastObservedLocation = location

        guard let previous = lastAcceptedLocation else {
            lastAcceptedLocation = location
            playerLocation = location
            return
        }

        let timeDelta = location.timestamp.timeIntervalSince(previous.timestamp)
        guard timeDelta > 0 else { return }

        let segment = location.distance(from: previous)
        let impliedSpeed = segment / timeDelta
        guard impliedSpeed <= configuration.maximumMovementSpeed else {
            // Validate before publishing a coordinate to the map, pursuit or
            // pickups, not merely before increasing the distance counter.
            pause(reason: .implausibleMovement)
            playerLocation = nil
            return
        }

        let noiseFloor = max(2.5, min(10, max(previous.horizontalAccuracy, location.horizontalAccuracy) * 0.4))
        guard segment >= noiseFloor, location.speed < 0 || location.speed >= 0.5 else {
            currentSpeed *= 0.55
            if currentSpeed < 0.15 { currentSpeed = 0 }
            // Refresh freshness without moving the avatar through GPS jitter.
            playerLocation = CLLocation(
                coordinate: previous.coordinate, altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy,
                course: location.course, speed: currentSpeed, timestamp: location.timestamp
            )
            if location.speed >= 0 && location.speed < 0.5 { lastAcceptedLocation = playerLocation }
            return
        }

        let measuredSpeed = location.speed >= 0 && location.speed <= configuration.maximumMovementSpeed
            ? location.speed
            : impliedSpeed
        currentSpeed = currentSpeed == 0
            ? measuredSpeed
            : currentSpeed * 0.72 + measuredSpeed * 0.28
        distanceMeters += segment
        let wasCharged = energy >= 100
        energy = min(100, energy + segment / configuration.pulseChargeDistance * 100)
        if !wasCharged && energy >= 100 {
            HapticsService.supply()
            postEvent("파동 충전 완료 · 위기 때 사용하세요", tone: .signal)
        }
        let milestones = movementRewards.creditDistance(distanceMeters)
        if milestones > 0 {
            postEvent("\(movementRewards.milestones * 100)m 이동 달성 · +\(milestones * 50)점", tone: .signal)
            HapticsService.supply()
        }
        lastAcceptedLocation = location
        playerLocation = location
        lastMovementTime = location.timestamp

        if routeCoordinates.isEmpty
            || GeoMath.distance(from: routeCoordinates.last!, to: location.coordinate) >= 5 {
            routeCoordinates.append(location.coordinate)
            if routeCoordinates.count > 900 {
                routeCoordinates.removeFirst(routeCoordinates.count - 900)
            }
        }

        collectSafeLight(at: location.coordinate)
    }

    private func isAcceptableForGameplay(_ location: CLLocation, maximumAge: TimeInterval) -> Bool {
        CLLocationCoordinate2DIsValid(location.coordinate)
            && location.horizontalAccuracy.isFinite
            && location.horizontalAccuracy >= 0
            && location.horizontalAccuracy <= configuration.maximumLocationAccuracy
            && location.speed.isFinite
            && location.course.isFinite
            && location.timestamp.timeIntervalSince(now()) <= 2
            && now().timeIntervalSince(location.timestamp) <= maximumAge
    }

    private func beginLocationRecovery() {
        guard !isRecoveringLocation else { return }
        isRecoveringLocation = true
        cancelShots()
        currentSpeed = 0
        lastMovementTime = nil
        contactSeconds.removeAll()
        catchSeconds = 0
        escapeAttempt = nil
        HapticsService.stopSound()
        // Keep timers, location tracking and cached building data alive. There is
        // no scoring, pursuit, pickup or catch until a fresh fix resets the baseline.
    }

    private func advanceRunningState() {
        if lastMovementTime.map({ now().timeIntervalSince($0) > 6 }) ?? true {
            currentSpeed *= 0.35
            if currentSpeed < 0.15 { currentSpeed = 0 }
        }
        let previousRhythm = runRhythm
        elapsedSeconds += 1
        if runRhythm != previousRhythm {
            HapticsService.signal()
            postEvent(runRhythm == .recovery ? "회복 구간 · 추격이 느려집니다" : "다시 내 속도로 이동하세요", tone: .neutral)
        }
        if currentSpeed >= 0.8, let lastMovementTime, now().timeIntervalSince(lastMovementTime) <= 6 { movingSeconds += 1 }
        let nearest = nearestThreatDistance
        let previousDanger = dangerLevel
        dangerLevel = isProtected ? .safe : DangerLevel.evaluate(distance: nearest, configuration: configuration)
#if DEBUG
        if locationService.isSimulationEnabled, let debugDangerOverride { dangerLevel = debugDangerOverride }
#endif
        if dangerLevel != previousDanger {
            nextWarningTime = elapsedSeconds
            if dangerLevel == .safe || dangerLevel == .unknown { HapticsService.stopSound() }
        }
        let targetPressure: Double = switch dangerLevel {
        case .unknown, .safe: 0
        case .watch: 25
        case .danger: 55
        case .critical: 90
        case .caught: 100
        }
        pressure += (targetPressure - pressure) / 3
        peakPressure = max(peakPressure, pressure)
        if let interval = dangerLevel.feedbackInterval, elapsedSeconds >= nextWarningTime {
            nextWarningTime = elapsedSeconds + interval
            HapticsService.danger(dangerLevel)
        }
        if dangerLevel == .safe || dangerLevel == .unknown { nextWarningTime = elapsedSeconds }
        updateCatchState()
        guard phase == .running else { return }
        updateEscapeReward()
        if wardSecondsRemaining > 0 { wardSecondsRemaining -= 1 }
        if safeLightSecondsRemaining > 0 { safeLightSecondsRemaining -= 1 }
        if pulseSecondsRemaining > 0 { pulseSecondsRemaining -= 1 }
    }

    func advanceGhosts(by seconds: Double) {
        if phase == .running { resolveShots() }
        guard phase == .running, !isRecoveringLocation, !isRoutingSuspended, !isProtected, hasFreshLocation else { return }
        for index in entities.indices where entities[index].kind == .ghost {
            let entity = entities[index]
            guard !shots.contains(where: { $0.targetID == entity.id }) else { continue }
            guard navigationTasks[entity.id] == nil, var navigation = entity.navigation,
                  now().timeIntervalSince(navigation.calculatedAt) <= configuration.maximumRouteAge else { continue }
            if navigation.cursor.path.obstacleMap != nil, routeDistance(to: entity) == nil { continue }
            let ramp = min(0.45, Double(elapsedSeconds) / 600)
            let farBoost = (routeDistance(to: entity) ?? 0) > configuration.safeDistance ? 0.15 : 0
            let closeRelief = (routeDistance(to: entity) ?? .infinity) < configuration.dangerDistance && currentSpeed > 2 ? 0.2 : 0
            var speed = min(configuration.maximumGhostSpeed, max(0.6, (entity.speed + ramp + farBoost - closeRelief) * runRhythm.speedMultiplier))
#if DEBUG
            if locationService.isSimulationEnabled, let debugGhostSpeed { speed = debugGhostSpeed }
#endif
            navigation.cursor.advance(meters: speed * max(0, min(seconds, 1)))
            entities[index].navigation = navigation
            entities[index].coordinate = navigation.cursor.coordinate
        }
    }

    private func updateCatchState() {
        guard !isProtected, now() >= catchAllowedAfter, let location = playerLocation,
              location.horizontalAccuracy <= configuration.catchAccuracy,
              now().timeIntervalSince(location.timestamp) <= configuration.catchFixMaximumAge else {
            contactSeconds.removeAll()
            catchSeconds = 0
            return
        }
        for ghost in entities where ghost.kind == .ghost {
            let distance = routeDistance(to: ghost)
            if navigationTasks[ghost.id] == nil,
               let distance, distance < configuration.catchDistance {
                contactSeconds[ghost.id, default: 0] += 1
            } else { contactSeconds[ghost.id] = 0 }
        }
        catchSeconds = contactSeconds.values.max() ?? 0
        if catchSeconds >= configuration.catchGraceDuration {
            dangerLevel = .caught
            pressure = 100
            endSession(reason: .caught)
        }
    }

    private func updateEscapeReward() {
        guard !isProtected, elapsedSeconds >= nextEscapeTime, let nearest = nearestThreatDistance else { return }
        if let attempt = escapeAttempt {
            guard elapsedSeconds - attempt.startTime <= 90,
                  let ghost = entities.first(where: { $0.id == attempt.id }),
                  let distance = routeDistance(to: ghost) else {
                escapeAttempt = nil
                return
            }
            if nearest >= configuration.watchDistance, distanceMeters - attempt.distanceAtStart >= 40,
               distance >= configuration.watchDistance {
                movementRewards.creditEscape()
                escapeAttempt = nil
                nextEscapeTime = elapsedSeconds + 30
                postEvent("추격 탈출 · 이동 보너스 +120점", tone: .signal)
                HapticsService.supply()
            }
        } else if nearest < configuration.dangerDistance,
                  let ghost = entities.filter({ $0.kind == .ghost }).min(by: {
                      (routeDistance(to: $0) ?? .infinity) < (routeDistance(to: $1) ?? .infinity)
                  }) { escapeAttempt = (ghost.id, distanceMeters, elapsedSeconds) }
    }

    private func collectSafeLight(at coordinate: CLLocationCoordinate2D) {
        guard phase == .running, let location = playerLocation,
              location.horizontalAccuracy <= configuration.catchAccuracy else { return }
        let arrived = entities.filter { entity in
            guard entity.kind == .safeLight, let path = entity.safePath else { return false }
            let match = path.projection(of: coordinate)
            return match.separation <= configuration.routeMatchTolerance
                && path.length - match.offset <= configuration.safeLightRadius
                && GeoMath.distance(from: coordinate, to: entity.coordinate) <= configuration.safeLightRadius
        }
        guard !arrived.isEmpty else { return }
        cachesCollected += arrived.count
        safeLightSecondsRemaining = configuration.safeLightDuration
        wardCharges = min(2, wardCharges + 1)
        ammo = min(configuration.maximumAmmo, ammo + configuration.supplyAmmo)
        contactSeconds.removeAll()
        catchSeconds = 0
        escapeAttempt = nil
        nextEscapeTime = elapsedSeconds + configuration.safeLightDuration + 5
        let ids = Set(arrived.map(\.id))
        entities.removeAll { ids.contains($0.id) }
        lightRetryAfter = now().addingTimeInterval(10)
        postEvent("보급 도착 · 탄약 충전 + \(configuration.safeLightDuration)초 보호", tone: .supply)
        HapticsService.supply()
    }

    private func maintainWorld() {
        guard hasFreshLocation, let player = playerLocation,
              phase == .countdown || phase == .running else { return }
        // Oldest attempts first, so a larger wave cannot starve later ghosts.
        let ghosts = entities.filter { $0.kind == .ghost }.sorted {
            (lastRouteAttempts[$0.id] ?? .distantPast) < (lastRouteAttempts[$1.id] ?? .distantPast)
        }
        for ghost in ghosts {
            if shots.contains(where: { $0.targetID == ghost.id }) { continue }
            if let failed = routeFailureSince[ghost.id], now().timeIntervalSince(failed) >= configuration.routeFailureDespawnInterval {
                navigationTasks[ghost.id]?.cancel()
                navigationTasks[ghost.id] = nil
                entities.removeAll { $0.id == ghost.id }
                contactSeconds[ghost.id] = nil
                lastRouteAttempts[ghost.id] = nil
                routeFailureSince[ghost.id] = nil
                continue
            }
            let navigation = ghost.navigation
            let targetMoved = navigation.map { GeoMath.distance(from: $0.playerTarget, to: player.coordinate) >= configuration.playerMovementForReroute } ?? true
            let pathExpired = navigation.map { now().timeIntervalSince($0.calculatedAt) >= configuration.maximumRouteAge } ?? true
            let offPath = navigation.map {
                $0.cursor.path.obstacleMap != nil ? routeDistance(to: ghost) == nil
                    : $0.cursor.path.projection(of: player.coordinate).separation > configuration.routeMatchTolerance
            } ?? true
            let routeEnded = navigation.map { $0.cursor.remainingDistance < 1 && (routeDistance(to: ghost) ?? .infinity) > configuration.catchDistance } ?? true
            if targetMoved || pathExpired || offPath || routeEnded { requestRoute(for: ghost, target: player.coordinate) }
        }
        let desired = configuration.ghostCount(at: elapsedSeconds)
        if entities.filter({ $0.kind == .ghost }).count < desired { requestSpawn(kind: .ghost) }
        if entities.contains(where: { $0.kind == .ghost }), !entities.contains(where: { $0.kind == .safeLight }) {
            requestSpawn(kind: .safeLight)
        }
        isRoutingSuspended = nearestThreatDistance == nil
        if !isRoutingSuspended { routingStatus = "건물 회피 추격" }
    }

    private func requestRoute(for ghost: WorldEntity, target: CLLocationCoordinate2D) {
        guard navigationTasks[ghost.id] == nil,
              navigationTasks.count < configuration.maximumConcurrentPursuitRoutes else { return }
        let interval = routeFailureSince[ghost.id] == nil ? configuration.routeRefreshInterval : configuration.routeRetryInterval
        guard lastRouteAttempts[ghost.id].map({ now().timeIntervalSince($0) >= interval }) ?? true else { return }
        lastRouteAttempts[ghost.id] = now()
        let generation = worldGeneration
        navigationTasks[ghost.id] = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == worldGeneration else { return }
            do {
                let path = try await routingService.pursuitRoute(from: ghost.coordinate, to: target)
                try Task.checkCancellation()
                guard generation == worldGeneration, phase == .running || phase == .countdown,
                      let index = entities.firstIndex(where: { $0.id == ghost.id }) else { return }
                guard GeoMath.distance(from: path.coordinates.first!, to: entities[index].coordinate) <= configuration.routeStartTolerance,
                      GeoMath.distance(from: path.coordinates.last!, to: target) <= configuration.routeEndpointTolerance else {
                    throw WalkingRouteError.invalidGeometry
                }
                entities[index].navigation = GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: target, calculatedAt: now())
                entities[index].coordinate = path.coordinates.first!
                routeFailureSince[ghost.id] = nil
            } catch {
                guard generation == worldGeneration, !Task.isCancelled else { return }
                if let index = entities.firstIndex(where: { $0.id == ghost.id }) { entities[index].navigation = nil }
                routeFailureSince[ghost.id] = routeFailureSince[ghost.id] ?? now()
                contactSeconds[ghost.id] = 0
                routingStatus = "건물 지도/우회 경로 확인 대기 · 자동 재시도"
            }
            if generation == worldGeneration { navigationTasks[ghost.id] = nil }
        }
    }

    private func requestSpawn(kind: WorldEntityKind, bypassWaveLimit: Bool = false) {
        guard let player = playerLocation else { return }
        if kind == .ghost {
            guard spawnTask == nil, now() >= spawnRetryAfter else { return }
            guard bypassWaveLimit || (runRhythm != .recovery && now() >= respawnTimeThreshold
                && distanceMeters >= respawnDistanceThreshold) else { return }
            spawnRetryAfter = now().addingTimeInterval(configuration.routeRetryInterval)
        } else {
            guard safeLightTask == nil, now() >= lightRetryAfter else { return }
            lightRetryAfter = now().addingTimeInterval(configuration.routeRetryInterval)
        }
        // Random probes become spawn points only after obstacle/path validation.
        // Rotate each group around the player, with jitter. Only validated paths
        // become entities; this does not assume that random coordinates are clear.
        let bearing: Double
        if kind == .ghost {
            spawnBearing = (spawnBearing + 137.5).truncatingRemainder(dividingBy: 360)
            bearing = spawnBearing + Double.random(in: -18...18, using: &random)
        } else { bearing = Double.random(in: 0..<360, using: &random) }
        let probe = GeoMath.coordinate(from: player.coordinate, distance: configuration.spawnDistance.upperBound + 100,
                                       bearingDegrees: bearing)
        let selectedDistance = Double.random(in: kind == .ghost ? configuration.spawnDistance : configuration.safeLightDistance, using: &random)
        let generation = worldGeneration
        let task = Task { [weak self] in
            guard let self, !Task.isCancelled, generation == worldGeneration else { return }
            do {
                let origin = kind == .ghost ? probe : player.coordinate
                let destination = kind == .ghost ? player.coordinate : probe
                let path: WalkingPath
                if kind == .ghost { path = try await routingService.spawnRoute(from: origin, to: destination) }
                else { path = try await routingService.walkingRoute(from: origin, to: destination) }
                try Task.checkCancellation()
                guard generation == worldGeneration, phase == .countdown || phase == .running,
                      let current = playerLocation,
                      GeoMath.distance(from: current.coordinate, to: player.coordinate) <= configuration.playerMovementForReroute else {
                    if generation == worldGeneration { finishSpawn(kind) }
                    return
                }
                if kind == .ghost {
                    guard bypassWaveLimit || (runRhythm != .recovery && now() >= respawnTimeThreshold
                        && distanceMeters >= respawnDistanceThreshold) else {
                        finishSpawn(kind)
                        return
                    }
                    guard path.length >= configuration.spawnDistance.lowerBound,
                          GeoMath.distance(from: path.coordinates.last!, to: player.coordinate) <= configuration.routeEndpointTolerance else {
                        throw WalkingRouteError.invalidGeometry
                    }
                    let limit = bypassWaveLimit ? configuration.maximumGhosts : configuration.ghostCount(at: elapsedSeconds)
                    let countBefore = ghostCount
                    let spacing = configuration.ghostSpawnSpacing + 4
                    let baseDistance = max(configuration.spawnDistance.lowerBound,
                        min(selectedDistance, configuration.spawnDistance.upperBound - spacing))
                    for member in 0..<configuration.ghostsPerSpawn where ghostCount < limit {
                        let distance = baseDistance + Double(member) * spacing
                        guard distance <= configuration.spawnDistance.upperBound, path.length >= distance,
                              let tail = path.suffix(from: path.length - distance),
                              let coordinate = tail.coordinates.first,
                              GeoMath.distance(from: coordinate, to: current.coordinate) >= configuration.minimumSpawnSeparation,
                              entities.filter({ $0.kind == .ghost }).allSatisfy({
                                  GeoMath.distance(from: $0.coordinate, to: coordinate) >= self.configuration.ghostSpawnSpacing
                              }) else { continue }
                        entities.append(WorldEntity(kind: .ghost, coordinate: coordinate, radius: configuration.catchDistance,
                            speed: configuration.baseGhostSpeed + Double.random(in: -0.1...0.1, using: &random),
                            navigation: GhostNavigation(cursor: WalkingCursor(path: tail), playerTarget: player.coordinate, calculatedAt: now())))
                    }
                    guard ghostCount > countBefore else { throw WalkingRouteError.invalidGeometry }
                    // Success is a short refill cadence, not the network-error cooldown.
                    spawnRetryAfter = now().addingTimeInterval(configuration.successfulSpawnInterval)
                } else {
                    guard path.length >= configuration.safeLightDistance.lowerBound,
                          GeoMath.distance(from: path.coordinates.first!, to: player.coordinate) <= configuration.routeEndpointTolerance,
                          let prefix = path.prefix(through: min(path.length, selectedDistance)),
                          GeoMath.distance(from: prefix.coordinates.last!, to: current.coordinate) >= configuration.minimumSpawnSeparation else { throw WalkingRouteError.invalidGeometry }
                    entities.append(WorldEntity(kind: .safeLight, coordinate: prefix.coordinates.last!,
                                                radius: configuration.safeLightRadius, safePath: prefix))
                }
                routingStatus = "추격 경로 준비 완료"
            } catch {
                guard generation == worldGeneration, !Task.isCancelled else { return }
                if case ObstacleRouteError.serverNotConfigured = error {
                    routingStatus = "건물 지도 서버가 설정되지 않았습니다"
                } else {
                    routingStatus = "지도/우회 경로 대기 · 건물 밖에서 위치와 연결을 확인하세요"
                }
            }
            if generation == worldGeneration { finishSpawn(kind) }
        }
        if kind == .ghost { spawnTask = task } else { safeLightTask = task }
    }

    private func finishSpawn(_ kind: WorldEntityKind) {
        if kind == .ghost { spawnTask = nil } else { safeLightTask = nil }
    }

    private func pause(reason: PauseReason) {
        guard phase == .running || phase == .countdown else { return }
        cancelRouting()

        phaseBeforePause = phase
        if phase == .countdown {
            let remaining = countdownDeadline?.timeIntervalSince(now()) ?? TimeInterval(countdownSeconds)
            countdownSeconds = max(0, Int(ceil(remaining)))
            countdownDeadline = nil
        }
        phase = .paused
        isRecoveringLocation = false
        pauseReason = reason
        locationService.setGameplayTrackingProfile(false)
        lastAcceptedLocation = playerLocation
        lastObservedLocation = playerLocation
        currentSpeed = 0
        escapeAttempt = nil
        ticker?.cancel()
        ticker = nil
    }

    private func resetRuntimeState() {
        cancelRouting()
        random = SeededGenerator(seed: UInt64(max(0, now().timeIntervalSince1970 * 1_000)))
        spawnBearing = Double.random(in: 0..<360, using: &random)
        countdownSeconds = countdownDuration
        countdownDeadline = now().addingTimeInterval(TimeInterval(countdownDuration))
        isWaitingForGPS = false
        isRecoveringLocation = false
        catchAllowedAfter = .distantPast
        pauseReason = nil
        routeCoordinates = []
        entities = []
        elapsedSeconds = 0
        distanceMeters = 0
        currentSpeed = 0
        pressure = 8
        energy = 0
        ammo = configuration.startingAmmo
        shots.removeAll()
        pulseSecondsRemaining = 0
        lastShotAt = .distantPast
        respawnTimeThreshold = .distantPast
        respawnDistanceThreshold = 0
        wardCharges = 1
        wardSecondsRemaining = 0
        safeLightSecondsRemaining = 0
        dangerLevel = .unknown
        routingStatus = "주변 건물 지도 확인 중"
        isRoutingSuspended = true

        cachesCollected = 0
        movingSeconds = 0
        movementRewards = MovementRewards()
        escapeAttempt = nil
        nextEscapeTime = 0
        nextWarningTime = 0
        nextSupplySkipTime = 0
        spawnRetryAfter = .distantPast
        lightRetryAfter = .distantPast
        lastRouteAttempts.removeAll()
        routeFailureSince.removeAll()
        peakPressure = 8
        result = nil
        lastAcceptedLocation = nil
        lastSeenLocationTime = nil
        lastObservedLocation = nil
        lastMovementTime = nil
    }

    private func clearWorld() {
        isRecoveringLocation = false
        routeCoordinates.removeAll()
        entities.removeAll()
        playerLocation = nil
        lastAcceptedLocation = nil
        lastSeenLocationTime = nil
        lastObservedLocation = nil
        lastMovementTime = nil
        escapeAttempt = nil
    }

#if DEBUG
    func debugChargePulse() {
        guard locationService.isSimulationEnabled, phase == .running else { return }
        energy = 100
    }

    func debugSpawn(_ kind: WorldEntityKind) {
        guard locationService.isSimulationEnabled, phase == .running else { return }
        if kind == .ghost, entities.filter({ $0.kind == .ghost }).count >= configuration.maximumGhosts { return }
        if kind == .safeLight, entities.contains(where: { $0.kind == .safeLight }) { return }
        if kind == .ghost { spawnRetryAfter = .distantPast } else { lightRetryAfter = .distantPast }
        requestSpawn(kind: kind, bypassWaveLimit: true)
    }

    func debugForceReroute() {
        guard locationService.isSimulationEnabled, phase == .running, let target = playerLocation?.coordinate else { return }
        lastRouteAttempts.removeAll()
        for ghost in entities where ghost.kind == .ghost { requestRoute(for: ghost, target: target) }
    }

    func debugMoveGhostAlongRoute() {
        guard locationService.isSimulationEnabled, phase == .running,
              let index = entities.firstIndex(where: { $0.kind == .ghost }),
              var navigation = entities[index].navigation else { return }
        navigation.cursor.advance(meters: 30)
        entities[index].navigation = navigation
        entities[index].coordinate = navigation.cursor.coordinate
        contactSeconds.removeAll()
    }

    func debugGameOver() {
        guard locationService.isSimulationEnabled, phase == .running else { return }
        endSession(reason: .caught)
    }

    func debugReplaceWorld(_ world: [WorldEntity]) {
        guard locationService.isSimulationEnabled, phase == .running || phase == .countdown else { return }
        cancelRouting()
        entities = world
        isRoutingSuspended = nearestThreatDistance == nil
        if automaticallyTicks { motionTicker = nil; ticker?.cancel(); ticker = nil; startTickerIfNeeded() }
    }
#endif



    private func postEvent(_ message: String, tone: GameEventTone) {
        currentEvent = GameEvent(message: message, tone: tone)
        eventTicksRemaining = 4
    }

    private func ageCurrentEvent() {
        guard currentEvent != nil else { return }
        eventTicksRemaining -= 1
        if eventTicksRemaining <= 0 {
            currentEvent = nil
        }
    }

    private func savePersonalBest() {
        completedRuns += 1
        bestScore = max(bestScore, score)
        bestDistance = max(bestDistance, distanceMeters)
        longestSurvival = max(longestSurvival, elapsedSeconds)

        let defaults = UserDefaults.standard
        defaults.set(completedRuns, forKey: "completedRuns")
        defaults.set(bestScore, forKey: "bestScore")
        defaults.set(bestDistance, forKey: "bestDistance")
        defaults.set(longestSurvival, forKey: "longestSurvival")
    }
}
