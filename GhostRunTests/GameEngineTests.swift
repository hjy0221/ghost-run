#if DEBUG
import Combine
import CoreLocation
import XCTest
@testable import ZombieRun

@MainActor
final class GameEngineTests: XCTestCase {
    func testTenSecondCountdownDoesNotAwardDistance() {
        let run = RunFixture(startImmediately: false)
        for _ in 0..<9 { run.step(meters: 3) }
        XCTAssertEqual(run.engine.phase, .countdown)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        run.step(meters: 3)
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.entities.filter { $0.kind == .ghost }.count, 1)
    }

    func testStationaryJitterDoesNotMovePlayerOrCollectSupplies() {
        let run = RunFixture()
        let origin = run.engine.playerLocation!.coordinate
        run.engine.debugReplaceWorld([run.entity(.safeLight, distance: 3)])
        for _ in 0..<20 {
            run.step(meters: 1, speed: 0)
        }
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.currentSpeed, 0)
        XCTAssertEqual(run.engine.cachesCollected, 0)
        XCTAssertEqual(GeoMath.distance(from: origin, to: run.engine.playerLocation!.coordinate), 0, accuracy: 0.01)
    }

    func testJumpCannotTeleportToSupply() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.safeLight, distance: 300)])
        run.step(meters: 300, speed: 3)
        XCTAssertEqual(run.engine.phase, .paused)
        XCTAssertEqual(run.engine.pauseReason, .implausibleMovement)
        XCTAssertNil(run.engine.playerLocation)
        XCTAssertEqual(run.engine.cachesCollected, 0)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.movementRewards.score, 0)
    }

    func testVehicleSpeedPausesEvenWithoutCoordinateDisplacement() {
        let run = RunFixture()
        run.step(meters: 0, speed: 15)
        XCTAssertEqual(run.engine.phase, .paused)
        XCTAssertEqual(run.engine.pauseReason, .implausibleMovement)
        XCTAssertEqual(run.engine.distanceMeters, 0)
    }

    func testPoorAccuracyAndOutOfOrderSamplesAreIgnored() {
        let run = RunFixture()
        let location = run.engine.playerLocation!
        run.clock.date.addTimeInterval(1)
        run.engine.ingest(run.source.makeLocation(at: location.coordinate, speed: 3, accuracy: 70))
        XCTAssertEqual(run.engine.playerLocation?.timestamp, location.timestamp)
        run.engine.ingest(location)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.phase, .running)
    }

    func testSupplyRequiresAcceptedMovementAndIsCollectedOnce() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.safeLight, distance: 45)])
        for _ in 0..<8 { run.step(meters: 3, tick: false) }
        XCTAssertEqual(run.engine.cachesCollected, 0)
        run.step(meters: 4, tick: false)
        XCTAssertEqual(run.engine.cachesCollected, 1)
        XCTAssertEqual(run.engine.wardCharges, 2)
        run.engine.ingest(run.source.currentLocation!)
        XCTAssertEqual(run.engine.cachesCollected, 1)
    }

    func testDistanceBonusIsNotAwardedByTimeOrDuplicateSamples() {
        let run = RunFixture()
        for _ in 0..<35 { run.step(meters: 3, tick: false) }
        XCTAssertEqual(run.engine.movementRewards.milestones, 1)
        XCTAssertEqual(run.engine.movementRewards.score, 50)
        let previousDistance = run.engine.distanceMeters
        run.engine.ingest(run.source.currentLocation!)
        XCTAssertEqual(run.engine.distanceMeters, previousDistance)
        XCTAssertEqual(run.engine.movementRewards.score, 50)
        XCTAssertGreaterThan(run.engine.movementRewards.score, 0)
    }

    func testStationaryPlayerIsPursued() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 80, bearing: 180, speed: 2)])
        let initial = run.engine.nearestThreatDistance!
        for _ in 0..<10 { run.step(meters: 0) }
        XCTAssertLessThan(run.engine.nearestThreatDistance!, initial - 10)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.movementRewards.score, 0)
    }

    func testStationarySessionCanEndCaught() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 20, speed: 2)])
        for _ in 0..<240 where run.engine.phase == .running { run.step(meters: 0) }
        XCTAssertEqual(run.engine.phase, .summary)
        XCTAssertEqual(run.engine.result?.reason, .caught)
    }

    func testWardStopsPursuitWithoutTeleporting() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 80, bearing: 180, speed: 2)])
        let coordinate = run.engine.entities[0].coordinate
        run.engine.activateWard()
        for _ in 0..<3 { run.step(meters: 0) }
        XCTAssertLessThan(GeoMath.distance(from: coordinate, to: run.engine.entities[0].coordinate), 0.1)
        XCTAssertEqual(run.engine.wardCharges, 0)
        XCTAssertEqual(run.engine.catchSeconds, 0)
    }

    func testCatchRequiresConsecutiveAccurateSeconds() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 10, bearing: 180, speed: 0)])
        run.step(meters: 0)
        XCTAssertEqual(run.engine.phase, .running)
        run.step(meters: 0)
        XCTAssertEqual(run.engine.phase, .running)
        run.step(meters: 0)
        XCTAssertEqual(run.engine.result?.reason, .caught)
    }

    func testUncertainFixDoesNotCatchPlayer() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 10, bearing: 180, speed: 0)])
        for _ in 0..<5 {
            run.clock.date.addTimeInterval(1)
            run.source.currentLocation = run.source.makeLocation(at: run.origin, speed: 0, accuracy: 24)
            run.engine.ingest(run.source.currentLocation!)
            run.engine.tick()
        }
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertEqual(run.engine.catchSeconds, 0)
    }

    func testRouteFailureWaitsInsteadOfDirectChase() async {
        let run = RunFixture()
        let ghost = run.entity(.ghost, distance: 40, bearing: 180, speed: 2)
        run.engine.debugReplaceWorld([ghost])
        run.engine.debugForceReroute()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(run.engine.entities.first?.navigation)
        for _ in 0..<10 { run.step(meters: 0) }
        XCTAssertLessThan(GeoMath.distance(from: ghost.coordinate, to: run.engine.entities[0].coordinate), 0.1)
        XCTAssertEqual(run.engine.dangerLevel, .unknown)
        XCTAssertEqual(run.engine.elapsedSeconds, 0)
    }

    func testPauseResetsCatchGraceAndFreezesTime() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 10, bearing: 180)])
        run.step(meters: 0)
        XCTAssertEqual(run.engine.catchSeconds, 1)
        run.engine.pauseByUser()
        run.step(meters: 0)
        XCTAssertEqual(run.engine.catchSeconds, 0)
        XCTAssertEqual(run.engine.elapsedSeconds, 1)
    }

    func testPausedMovementDoesNotAwardDistanceOrSupplies() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.safeLight, distance: 45)])
        run.engine.pauseByUser()
        run.step(meters: 45, speed: 3)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.cachesCollected, 0)
        XCTAssertEqual(run.engine.elapsedSeconds, 0)
        run.engine.resume()
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertEqual(run.engine.distanceMeters, 0)
    }

    func testStaleLocationProtectsRunWithoutModalPauseOrFreeTime() {
        let run = RunFixture()
        let ghost = run.engine.entities[0].coordinate
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertTrue(run.engine.isRecoveringLocation)
        XCTAssertNil(run.engine.pauseReason)
        XCTAssertEqual(run.engine.elapsedSeconds, 0)
        run.engine.advanceGhosts(by: 1)
        XCTAssertLessThan(GeoMath.distance(from: ghost, to: run.engine.entities[0].coordinate), 0.01)
        XCTAssertTrue(run.source.tracking)
        run.engine.returnToBriefing()
    }

    func testUnknownStationarySpeedDoesNotCauseFalseSignalLoss() {
        let run = RunFixture()
        for _ in 0..<45 { run.step(meters: 0.5, speed: -1) }
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertFalse(run.engine.isRecoveringLocation)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.elapsedSeconds, 45)
        run.engine.returnToBriefing()
    }

    func testSignalReturnsAutomaticallyWithoutCreditingUnobservedDistance() {
        let run = RunFixture()
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        run.step(meters: 100, speed: 3)
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertFalse(run.engine.isRecoveringLocation)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        XCTAssertEqual(run.engine.cachesCollected, 0)
        run.step(meters: 3, tick: false)
        XCTAssertEqual(run.engine.distanceMeters, 3, accuracy: 0.1)
        run.engine.returnToBriefing()
    }

    func testReturningFixDoesNotImmediatelyCatchOrResumeManualPause() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 10)])
        run.step(meters: 0)
        XCTAssertEqual(run.engine.catchSeconds, 1)
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        for _ in 0..<3 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.catchSeconds, 0)
        XCTAssertEqual(run.engine.phase, .running)
        run.engine.pauseByUser()
        run.step(meters: 0)
        XCTAssertEqual(run.engine.phase, .paused)
        XCTAssertEqual(run.engine.pauseReason, .userPaused)
        run.engine.returnToBriefing()
    }

    func testPoorSignalCannotEarnTimeUntilAccurateFixReturns() {
        let run = RunFixture()
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        for _ in 0..<20 {
            run.clock.date.addTimeInterval(1)
            run.engine.ingest(run.source.makeLocation(at: run.origin, speed: 0, accuracy: 80))
            run.engine.tick()
        }
        XCTAssertTrue(run.engine.isRecoveringLocation)
        XCTAssertEqual(run.engine.elapsedSeconds, 0)
        XCTAssertEqual(run.engine.score, 0)
        run.step(meters: 0)
        XCTAssertFalse(run.engine.isRecoveringLocation)
        run.engine.returnToBriefing()
    }

    func testUnknownSpeedStationaryAnchorDoesNotHideSuddenJump() {
        let run = RunFixture()
        for _ in 0..<40 { run.step(meters: 0.1, speed: -1) }
        run.step(meters: 160, speed: -1)
        XCTAssertEqual(run.engine.pauseReason, .implausibleMovement)
        XCTAssertEqual(run.engine.distanceMeters, 0)
        run.engine.returnToBriefing()
    }

    func testEndClearsCoordinatesAndSimulationNeverSavesRecords() {
        let run = RunFixture()
        let completed = run.engine.completedRuns
        run.step(meters: 3)
        run.engine.endSession()
        XCTAssertNotNil(run.engine.result)
        XCTAssertTrue(run.engine.result!.usedSimulation)
        XCTAssertEqual(run.engine.completedRuns, completed)
        XCTAssertTrue(run.engine.routeCoordinates.isEmpty)
        XCTAssertTrue(run.engine.entities.isEmpty)
        XCTAssertNil(run.engine.playerLocation)
        XCTAssertNil(run.source.currentLocation)
        XCTAssertFalse(run.source.tracking)
    }

    func testDebugToolsCannotChangeRealSession() {
        let run = RunFixture(startImmediately: false, simulated: false)
        let count = run.engine.entities.count
        run.engine.debugSpawn(.ghost)
        run.engine.debugMoveGhostAlongRoute()
        run.engine.debugGameOver()
        XCTAssertEqual(run.engine.entities.count, count)
        XCTAssertEqual(run.engine.phase, .countdown)
        run.engine.returnToBriefing()
    }

    func testRunningOnRouteCreatesDistanceWhileStandingLosesDistance() {
        let run = RunFixture()
        let initial = run.engine.nearestThreatDistance!
        for _ in 0..<6 { run.step(meters: 3) }
        XCTAssertGreaterThan(run.engine.nearestThreatDistance!, initial + 7)
        XCTAssertGreaterThan(run.engine.distanceMeters, 17)
    }

    func testCountdownWaitsForWalkingRouteWithoutFreeScore() async {
        let run = RunFixture(startImmediately: false, preloadWorld: false)
        for _ in 0..<12 {
            run.step(meters: 0)
            await settleTasks()
        }
        XCTAssertEqual(run.engine.countdownSeconds, 0)
        XCTAssertEqual(run.engine.phase, .countdown)
        XCTAssertTrue(run.engine.entities.isEmpty)
        XCTAssertEqual(run.engine.score, 0)
        run.engine.returnToBriefing()
    }

    func testSpawnUsesReturnedWalkingPathAndRespectsDistance() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(startImmediately: false, router: router, preloadWorld: false)
        run.step(meters: 0)
        await settleTasks()
        let ghost = run.engine.entities.first { $0.kind == .ghost }!
        XCTAssertGreaterThanOrEqual(ghost.navigation!.cursor.path.length, 99)
        XCTAssertLessThanOrEqual(ghost.navigation!.cursor.path.length, 251)
        XCTAssertLessThan(router.lastPath!.projection(of: ghost.coordinate).separation, 0.1)
        XCTAssertGreaterThan(GeoMath.distance(from: ghost.coordinate, to: router.lastOrigin!), 50)
        for _ in 0..<9 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.phase, .running)
        run.engine.returnToBriefing()
    }

    func testPendingRerouteFreezesGhostAndLateResponseCannotReviveEndedRun() async {
        let router = SuspendedTestRouter()
        let run = RunFixture(router: router)
        let ghost = run.entity(.ghost, distance: 80, bearing: 180)
        run.engine.debugReplaceWorld([ghost, run.entity(.safeLight, distance: 160)])
        run.engine.debugForceReroute()
        await settleTasks()
        XCTAssertEqual(router.pending.count, 1)
        for _ in 0..<3 { run.step(meters: 0) }
        XCTAssertLessThan(GeoMath.distance(from: ghost.coordinate, to: run.engine.entities[0].coordinate), 0.1)
        run.engine.endSession()
        router.completeAll()
        await settleTasks()
        XCTAssertEqual(run.engine.phase, .summary)
        XCTAssertTrue(run.engine.entities.isEmpty)
    }

    func testRerouteCannotTeleportToDisconnectedStart() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(router: router)
        let ghost = run.entity(.ghost, distance: 80, bearing: 180)
        run.engine.debugReplaceWorld([ghost, run.entity(.safeLight, distance: 160)])
        router.startOffset = 50
        run.engine.debugForceReroute()
        await settleTasks()
        XCTAssertNil(run.engine.entities[0].navigation)
        XCTAssertLessThan(GeoMath.distance(from: ghost.coordinate, to: run.engine.entities[0].coordinate), 0.1)
        run.engine.returnToBriefing()
    }

    func testRerouteRequestsReusePathAndRespectCooldown() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(router: router)
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 180, bearing: 180), run.entity(.safeLight, distance: 160)])
        run.engine.debugForceReroute()
        await settleTasks()
        XCTAssertEqual(router.calls, 1)
        for _ in 0..<7 {
            run.step(meters: 4)
            await settleTasks()
        }
        XCTAssertEqual(router.calls, 1)
        run.step(meters: 4)
        await settleTasks()
        XCTAssertEqual(router.calls, 2)
        run.engine.returnToBriefing()
    }

    func testSwarmBuildsDuringCountdownAndStaysWithinWaveLimit() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(startImmediately: false, router: router, preloadWorld: false, swarm: true)
        for _ in 0..<10 {
            run.step(meters: 0)
            await settleTasks()
        }
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertEqual(run.engine.ghostCount, 6)
        let ghosts = run.engine.entities.filter { $0.kind == .ghost }
        for (index, ghost) in ghosts.enumerated() {
            XCTAssertGreaterThanOrEqual(GeoMath.distance(from: ghost.coordinate, to: run.origin), 80)
            XCTAssertNotNil(ghost.navigation)
            for other in ghosts.dropFirst(index + 1) {
                XCTAssertGreaterThan(GeoMath.distance(from: ghost.coordinate, to: other.coordinate), 23)
            }
        }
        for _ in 0..<5 { run.step(meters: 0); await settleTasks() }
        XCTAssertEqual(run.engine.ghostCount, 6)
        run.engine.returnToBriefing()
    }

    func testSwarmRefillsMissingGhostsAndDebugSpawnHonorsMaximum() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(router: router, swarm: true)
        for _ in 0..<15 { run.step(meters: 0); await settleTasks() }
        XCTAssertEqual(run.engine.ghostCount, 6)
        let survivors = Array(run.engine.entities.filter { $0.kind == .ghost }.prefix(2))
        run.engine.debugReplaceWorld(survivors)
        for _ in 0..<20 { run.step(meters: 0); await settleTasks() }
        XCTAssertEqual(run.engine.ghostCount, 6)
        for _ in 0..<40 {
            run.engine.debugSpawn(.ghost)
            await settleTasks()
        }
        XCTAssertEqual(run.engine.ghostCount, run.engine.configuration.maximumGhosts)
        run.engine.returnToBriefing()
    }

    func testWaveConfigurationRampsWithoutIncreasingSpeedLimit() {
        let config = GameConfiguration.standard
        XCTAssertEqual(config.ghostCount(at: 0), 6)
        XCTAssertEqual(config.ghostCount(at: 89), 6)
        XCTAssertEqual(config.ghostCount(at: 90), 10)
        XCTAssertEqual(config.ghostCount(at: 240), 14)
        XCTAssertEqual(config.ghostCount(at: 10_000), 14)
        XCTAssertEqual(config.maximumGhostSpeed, 2.35)
    }

    func testSwarmRoutingLimitsConcurrentRequests() async {
        let router = SuspendedTestRouter()
        let run = RunFixture(router: router, swarm: true)
        let ghosts = (0..<6).map { run.entity(.ghost, distance: 180, bearing: Double($0) * 60) }
        run.engine.debugReplaceWorld(ghosts + [run.entity(.safeLight, distance: 160)])
        run.engine.debugForceReroute()
        await settleTasks()
        XCTAssertEqual(router.pending.count, 2)
        run.engine.endSession()
        router.completeAll()
        await settleTasks()
        XCTAssertTrue(run.engine.entities.isEmpty)
    }

    func testFailedSwarmSpawnKeepsRetryBackoff() async {
        let router = UnavailableTestRouter()
        let run = RunFixture(startImmediately: false, router: router, preloadWorld: false, swarm: true)
        for _ in 0..<10 { run.step(meters: 0); await settleTasks() }
        XCTAssertEqual(router.calls, 1)
        XCTAssertEqual(run.engine.ghostCount, 0)
        XCTAssertEqual(run.engine.phase, .countdown)
        run.engine.returnToBriefing()
    }

    private func settleTasks() async {
        for _ in 0..<30 { await Task.yield() }
    }

    func testShotTravelsBeforeRemovingClosestGhostWithoutKillPoints() {
        let run = RunFixture()
        let near = run.shootableGhost(distance: 30)
        let far = run.shootableGhost(distance: 50, bearing: 90)
        run.engine.debugReplaceWorld([far, near])
        XCTAssertEqual(run.engine.aimedGhost?.id, near.id)
        let score = run.engine.score
        run.engine.fireAtNearestGhost()
        XCTAssertEqual(run.engine.ammo, 2)
        XCTAssertEqual(run.engine.ghostCount, 2)
        XCTAssertEqual(run.engine.shots.first?.targetID, near.id)
        run.clock.date.addTimeInterval(0.2)
        run.engine.advanceGhosts(by: 0.2)
        XCTAssertEqual(run.engine.ghostCount, 2)
        run.clock.date.addTimeInterval(0.3)
        run.engine.advanceGhosts(by: 0.3)
        XCTAssertEqual(run.engine.ghostCount, 1)
        XCTAssertEqual(run.engine.entities[0].id, far.id)
        XCTAssertEqual(run.engine.score, score)
        XCTAssertEqual(run.engine.energy, 0)
        XCTAssertTrue(run.engine.shots.isEmpty)
        run.engine.returnToBriefing()
    }

    func testShootingRequiresRangeKnownClearSpaceAndCooldown() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 20)])
        XCTAssertFalse(run.engine.canFire) // No obstacle map: never assume clear space.
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 90)])
        run.engine.fireAtNearestGhost()
        XCTAssertEqual(run.engine.ammo, 3)
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 25), run.shootableGhost(distance: 50)])
        run.engine.fireAtNearestGhost()
        run.engine.fireAtNearestGhost()
        XCTAssertEqual(run.engine.ammo, 2)
        run.clock.date.addTimeInterval(0.5)
        run.engine.advanceGhosts(by: 0.5)
        XCTAssertFalse(run.engine.canFire)
        run.clock.date.addTimeInterval(2)
        XCTAssertTrue(run.engine.canFire)
        run.engine.returnToBriefing()
    }

    func testThreeRoundsAreFiniteAndStandingDoesNotReload() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 35), run.shootableGhost(distance: 40, bearing: 90),
                                      run.shootableGhost(distance: 50, bearing: 180), run.shootableGhost(distance: 55, bearing: 270)])
        for _ in 0..<3 {
            run.step(meters: 0, tick: false)
            run.engine.fireAtNearestGhost()
            run.clock.date.addTimeInterval(0.5)
            run.engine.advanceGhosts(by: 0.5)
            run.step(meters: 0, tick: false)
            run.step(meters: 0, tick: false)
        }
        XCTAssertEqual(run.engine.ammo, 0)
        XCTAssertEqual(run.engine.ghostCount, 1)
        run.engine.fireAtNearestGhost()
        XCTAssertTrue(run.engine.shots.isEmpty)
        for _ in 0..<10 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.ammo, 0)
        XCTAssertEqual(run.engine.energy, 0)
        run.engine.returnToBriefing()
    }

    func testUncertainFixCancelsFlightInsteadOfFreezingTargetForever() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 35)])
        run.engine.fireAtNearestGhost()
        run.clock.date.addTimeInterval(0.2)
        run.engine.ingest(run.source.makeLocation(at: run.origin, speed: 0, accuracy: 24))
        run.engine.advanceGhosts(by: 0.2)
        XCTAssertEqual(run.engine.ammo, 3)
        XCTAssertTrue(run.engine.shots.isEmpty)
        XCTAssertEqual(run.engine.ghostCount, 1)
        run.engine.returnToBriefing()
    }

    func testShotCannotCrossBuildingEvenWhenGhostIsClose() throws {
        let run = RunFixture()
        let wall = GroundObstacle(points: [.init(x: -7, y: -25), .init(x: -4, y: -25),
                                           .init(x: -4, y: 25), .init(x: -7, y: 25)])!
        let map = ObstacleMap(latitude: run.origin.latitude, longitude: run.origin.longitude, radius: 150,
                              obstacles: [wall], fetchedAt: run.clock.date)
        let start = map.coordinate(.init(x: -14, y: 0))
        let path = try ObstaclePathPlanner().route(from: start, to: run.origin, map: map)
        run.engine.debugReplaceWorld([WorldEntity(kind: .ghost, coordinate: start, radius: 15,
            navigation: GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: run.origin, calculatedAt: run.clock.date))])
        run.engine.fireAtNearestGhost()
        XCTAssertEqual(run.engine.ammo, 3)
        XCTAssertTrue(run.engine.shots.isEmpty)
        run.engine.returnToBriefing()
    }

    func testPendingShotIsCancelledAndRefundedOnPauseOrSignalLoss() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 25)])
        run.engine.fireAtNearestGhost()
        run.engine.pauseByUser()
        XCTAssertEqual(run.engine.ammo, 3)
        XCTAssertTrue(run.engine.shots.isEmpty)
        run.engine.resume()
        run.clock.date.addTimeInterval(3)
        run.engine.fireAtNearestGhost()
        XCTAssertEqual(run.engine.ammo, 2)
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        XCTAssertTrue(run.engine.isRecoveringLocation)
        XCTAssertEqual(run.engine.ammo, 3)
        XCTAssertEqual(run.engine.ghostCount, 1)
        XCTAssertTrue(run.engine.shots.isEmpty)
        run.engine.returnToBriefing()
    }

    func testSupplyRefillsAmmoOnlyAfterRealMovementAndDoesNotGiftCharge() {
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 25)])
        run.engine.fireAtNearestGhost()
        run.clock.date.addTimeInterval(0.5)
        run.engine.advanceGhosts(by: 0.5)
        XCTAssertEqual(run.engine.ammo, 2)
        run.engine.debugReplaceWorld([run.entity(.safeLight, distance: 45)])
        for _ in 0..<5 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.ammo, 2)
        for _ in 0..<10 { run.step(meters: 3, tick: false) }
        XCTAssertEqual(run.engine.ammo, 3)
        XCTAssertEqual(run.engine.cachesCollected, 1)
        XCTAssertEqual(run.engine.energy, run.engine.distanceMeters / 200 * 100, accuracy: 0.01)
        run.engine.returnToBriefing()
    }

    func testPulseChargesOnlyByDistanceAndStopsPursuitWithoutTeleport() {
        let run = RunFixture()
        for _ in 0..<20 { run.step(meters: 0.5, speed: -1) }
        XCTAssertEqual(run.engine.energy, 0)
        XCTAssertFalse(run.engine.canUsePulse)
        for _ in 0..<68 { run.step(meters: 3, tick: false) }
        XCTAssertEqual(run.engine.energy, 100)
        XCTAssertTrue(run.engine.canUsePulse)
        let ghost = run.engine.entities[0].coordinate
        run.engine.activatePulse()
        XCTAssertEqual(run.engine.energy, 0)
        XCTAssertEqual(run.engine.pulseSecondsRemaining, 8)
        for _ in 0..<7 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.energy, 0)
        XCTAssertLessThan(GeoMath.distance(from: ghost, to: run.engine.entities[0].coordinate), 0.01)
        run.engine.returnToBriefing()
    }

    func testWalkingAndRunningEarnSameChargePerMeter() {
        let walk = RunFixture()
        for meter in 1...30 {
            walk.clock.date.addTimeInterval(1)
            let point = GeoMath.coordinate(from: walk.origin, distance: Double(meter), bearingDegrees: 0)
            walk.engine.ingest(walk.source.makeLocation(at: point, speed: 1))
        }
        let jog = RunFixture()
        for _ in 0..<10 { jog.step(meters: 3, tick: false) }
        XCTAssertEqual(walk.engine.energy, jog.engine.energy, accuracy: 0.1)
        XCTAssertGreaterThan(walk.engine.energy, 14)
        walk.engine.returnToBriefing()
        jog.engine.returnToBriefing()
    }

    func testJumpAndSignalGapCannotChargePulse() {
        let run = RunFixture()
        run.clock.date.addTimeInterval(11)
        run.engine.tick()
        run.step(meters: 250, speed: 3)
        XCTAssertEqual(run.engine.energy, 0)
        run.step(meters: 250, speed: 3)
        XCTAssertEqual(run.engine.phase, .paused)
        XCTAssertEqual(run.engine.energy, 0)
        run.engine.returnToBriefing()
    }

    func testRecoveryRhythmSlowsPursuitButDoesNotMakeStandingSafeForever() {
        let config = GameConfiguration.standard
        XCTAssertEqual(config.rhythm(at: 0), .warmup)
        XCTAssertEqual(config.rhythm(at: 60), .pursuit)
        XCTAssertEqual(config.rhythm(at: 120), .recovery)
        XCTAssertEqual(config.rhythm(at: 150), .pursuit)
        let run = RunFixture()
        run.engine.debugReplaceWorld([run.entity(.ghost, distance: 500, bearing: 180, speed: 2)])
        for _ in 0..<110 { run.step(meters: 0) }
        let beforePush = run.engine.nearestThreatDistance!
        for _ in 0..<10 { run.step(meters: 0) }
        let pushMovement = beforePush - run.engine.nearestThreatDistance!
        let beforeRecovery = run.engine.nearestThreatDistance!
        for _ in 0..<10 { run.step(meters: 0) }
        let recoveryMovement = beforeRecovery - run.engine.nearestThreatDistance!
        XCTAssertGreaterThan(recoveryMovement, 0)
        XCTAssertLessThan(recoveryMovement, pushMovement * 0.8)
        XCTAssertEqual(run.engine.energy, 0)
        run.engine.returnToBriefing()
    }

    func testDefeatedGhostDoesNotImmediatelyRespawnWhileStanding() async {
        let router = SyntheticTestRouter()
        let run = RunFixture(router: router)
        run.engine.debugReplaceWorld([run.shootableGhost(distance: 25), run.entity(.safeLight, distance: 160)])
        run.engine.fireAtNearestGhost()
        run.clock.date.addTimeInterval(0.5)
        run.engine.advanceGhosts(by: 0.5)
        for _ in 0..<25 { run.step(meters: 0); await settleTasks() }
        XCTAssertEqual(run.engine.ghostCount, 0)
        for _ in 0..<11 { run.step(meters: 3); await settleTasks() }
        XCTAssertEqual(run.engine.ghostCount, 1)
        run.engine.returnToBriefing()
    }

    func testBuildingBetweenNearbyGhostAndPlayerPreventsWallCatch() throws {
        let run = RunFixture()
        let wall = GroundObstacle(points: [.init(x: -7, y: -25), .init(x: -4, y: -25),
                                           .init(x: -4, y: 25), .init(x: -7, y: 25)])!
        let area = ObstacleMap(latitude: run.origin.latitude, longitude: run.origin.longitude, radius: 150,
                               obstacles: [wall], fetchedAt: run.clock.date)
        let start = area.coordinate(.init(x: -14, y: 0))
        let path = try ObstaclePathPlanner().route(from: start, to: run.origin, map: area)
        run.engine.debugReplaceWorld([WorldEntity(kind: .ghost, coordinate: start, radius: 15, speed: 1,
            navigation: GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: run.origin, calculatedAt: run.clock.date))])
        for _ in 0..<5 { run.step(meters: 0) }
        XCTAssertEqual(run.engine.phase, .running)
        XCTAssertEqual(run.engine.catchSeconds, 0)
        XCTAssertGreaterThan(run.engine.nearestThreatDistance!, 30)
    }

    func testOpenSpacePlayerCanLeaveOldRouteWithoutSuspendingPursuit() throws {
        let run = RunFixture()
        let area = ObstacleMap(latitude: run.origin.latitude, longitude: run.origin.longitude, radius: 150,
                               obstacles: [], fetchedAt: run.clock.date)
        let start = area.coordinate(.init(x: -80, y: 0))
        let path = try ObstaclePathPlanner().route(from: start, to: run.origin, map: area)
        run.engine.debugReplaceWorld([WorldEntity(kind: .ghost, coordinate: start, radius: 15, speed: 1,
            navigation: GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: run.origin, calculatedAt: run.clock.date))])
        for _ in 0..<6 { run.step(meters: 3) }
        XCTAssertFalse(run.engine.isRoutingSuspended)
        XCTAssertEqual(run.engine.elapsedSeconds, 6)
        XCTAssertGreaterThan(run.engine.distanceMeters, 17)
    }

}

private final class TestClock {
    var date = Date(timeIntervalSince1970: 1_788_000_000)
}

private final class FakeLocationSource: GameLocationSource {
    let clock: TestClock
    var currentLocation: CLLocation?
    var isSimulationEnabled: Bool
    var isAuthorized = true
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var tracking = false
    var locations: AnyPublisher<CLLocation, Never> { Empty().eraseToAnyPublisher() }
    var errors: AnyPublisher<String, Never> { Empty().eraseToAnyPublisher() }

    init(clock: TestClock, simulated: Bool) { self.clock = clock; isSimulationEnabled = simulated }
    func startTracking() { tracking = true }
    func stopTracking() { tracking = false; currentLocation = nil }
    func setGameplayTrackingProfile(_ active: Bool) {}
    func refreshStationaryFixIfNeeded() {}
    func advanceSimulation(by seconds: TimeInterval) {}
    func makeLocation(at coordinate: CLLocationCoordinate2D, speed: Double, accuracy: Double = 2) -> CLLocation {
        CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 2,
                   course: 0, speed: speed, timestamp: clock.date)
    }
}

@MainActor
private final class RunFixture {
    let clock = TestClock()
    let source: FakeLocationSource
    let engine: GameEngine
    let router: any WalkingRouteProviding
    let origin = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)

    init(startImmediately: Bool = true, simulated: Bool = true,
         router: (any WalkingRouteProviding)? = nil, preloadWorld: Bool = true, swarm: Bool = false) {
        self.router = router ?? UnavailableTestRouter()
        source = FakeLocationSource(clock: clock, simulated: simulated)
        var configuration = GameConfiguration.standard
        configuration.maximumRouteAge = 3_600
        // Single-ghost fixtures isolate GPS/catch tests from asynchronous spawning.
        if !swarm {
            configuration.initialGhosts = 1
            configuration.secondWaveGhosts = 1
            configuration.maximumGhosts = 1
        }
        engine = GameEngine(locationService: source, now: { [clock] in clock.date }, automaticallyTicks: false,
                            configuration: configuration, routingService: self.router)
        source.currentLocation = source.makeLocation(at: origin, speed: 0)
        engine.beginSession()
        if simulated && preloadWorld {
            let start = GeoMath.coordinate(from: origin, distance: 200, bearingDegrees: 180)
            let end = GeoMath.coordinate(from: origin, distance: 300, bearingDegrees: 0)
            let path = WalkingPath(coordinates: [start, end])!
            engine.debugReplaceWorld([WorldEntity(kind: .ghost, coordinate: start, radius: 15, speed: 1.35,
                navigation: GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: origin, calculatedAt: clock.date))])
        }
        if startImmediately {
            clock.date.addTimeInterval(10)
            source.currentLocation = source.makeLocation(at: origin, speed: 0)
            engine.ingest(source.currentLocation!)
            engine.tick()
        }
    }

    func step(meters: Double, speed: Double? = nil, tick: Bool = true) {
        clock.date.addTimeInterval(1)
        let coordinate = GeoMath.coordinate(from: engine.playerLocation?.coordinate ?? origin,
                                            distance: meters, bearingDegrees: 0)
        source.currentLocation = source.makeLocation(at: coordinate, speed: speed ?? meters)
        engine.ingest(source.currentLocation!)
        if tick { engine.tick() }
    }

    func entity(_ kind: WorldEntityKind, distance: Double, bearing: Double = 0, speed: Double = 0) -> WorldEntity {
        let player = engine.playerLocation!.coordinate
        let point = GeoMath.coordinate(from: player, distance: distance, bearingDegrees: bearing)
        let path = WalkingPath(coordinates: kind == .ghost ? [point, player] : [player, point])!
        return WorldEntity(kind: kind, coordinate: point, radius: 18, speed: speed,
            navigation: kind == .ghost ? GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: player, calculatedAt: clock.date) : nil,
            safePath: kind == .safeLight ? path : nil)
    }

    func shootableGhost(distance: Double, bearing: Double = 0) -> WorldEntity {
        var ghost = entity(.ghost, distance: distance, bearing: bearing, speed: 1.35)
        let player = engine.playerLocation!.coordinate
        let map = ObstacleMap(latitude: player.latitude, longitude: player.longitude, radius: 650,
                              obstacles: [], fetchedAt: clock.date)
        let path = WalkingPath(coordinates: [ghost.coordinate, player], obstacleMap: map)!
        ghost.navigation = GhostNavigation(cursor: WalkingCursor(path: path), playerTarget: player, calculatedAt: clock.date)
        return ghost
    }


}
@MainActor
private final class UnavailableTestRouter: WalkingRouteProviding {
    var calls = 0
    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath {
        calls += 1
        throw WalkingRouteError.unavailable
    }
    func cancelAll() {}
}

// Synthetic geometry exists ONLY in the test target; production has no direct fallback.
@MainActor
private final class SyntheticTestRouter: WalkingRouteProviding {
    var calls = 0
    var startOffset = 0.0
    var lastPath: WalkingPath?
    var lastOrigin: CLLocationCoordinate2D?
    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath {
        calls += 1
        lastOrigin = from
        let start = GeoMath.coordinate(from: from, distance: startOffset, bearingDegrees: 90)
        let path = WalkingPath(coordinates: [start, to])!
        lastPath = path
        return path
    }
    func cancelAll() {}
}

@MainActor
private final class SuspendedTestRouter: WalkingRouteProviding {
    var pending: [(WalkingPath, CheckedContinuation<WalkingPath, Error>)] = []
    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath {
        let path = WalkingPath(coordinates: [from, to])!
        return try await withCheckedThrowingContinuation { pending.append((path, $0)) }
    }
    // Intentionally simulate a provider that returns a response after cancellation.
    func cancelAll() {}
    func completeAll() {
        let requests = pending
        pending.removeAll()
        for (path, continuation) in requests { continuation.resume(returning: path) }
    }
}
#endif
