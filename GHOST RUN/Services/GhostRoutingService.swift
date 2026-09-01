import CoreLocation
import MapKit

@MainActor
protocol WalkingRouteProviding: AnyObject {
    func walkingRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath
    func pursuitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath
    func spawnRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath
    func cancelAll()
}

// Preserve existing injected test providers and the separate walking-goal contract.
extension WalkingRouteProviding {
    func pursuitRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath {
        try await walkingRoute(from: from, to: to)
    }
    func spawnRoute(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) async throws -> WalkingPath {
        try await pursuitRoute(from: from, to: to)
    }
}

enum WalkingRouteError: Error { case unavailable, invalidGeometry }

@MainActor
final class GhostRoutingService: WalkingRouteProviding {
    private let configuration: GameConfiguration
    private var active: MKDirections?
    private var nextRequestDate = Date.distantPast
    private var generation = 0
    private let obstacles: any ObstacleMapProviding

    init(configuration: GameConfiguration = .standard, obstacles: (any ObstacleMapProviding)? = nil) {
        self.configuration = configuration
        self.obstacles = obstacles ?? ObstacleDataService(configuration: configuration)
    }

    func pursuitRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> WalkingPath {
        let token = generation
        let map = try await obstacles.map(around: destination)
        let path = try await plan(from: origin, to: destination, map: map)
        guard token == generation else { throw CancellationError() }
        return path
    }

    func spawnRoute(from probe: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> WalkingPath {
        let token = generation
        let map = try await obstacles.map(around: destination)
        let distance = GeoMath.distance(from: probe, to: destination)
        let bearing = GeoMath.bearing(from: destination, to: probe)
        // Alternative origins are allowed ONLY for new spawns, never for an existing ghost.
        for offset in [0.0, 45, -45, 90, -90, 135, -135, 180] {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            let candidate = GeoMath.coordinate(from: destination, distance: distance, bearingDegrees: bearing + offset)
            guard map.isClear(from: candidate, to: candidate) else { continue }
            do { return try await plan(from: candidate, to: destination, map: map) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
        }
        throw ObstacleRouteError.noPath
    }

    private func plan(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D, map: ObstacleMap) async throws -> WalkingPath {
        let grid = configuration.obstacleGridSize
        let task = Task.detached(priority: .userInitiated) {
            try ObstaclePathPlanner(cellSize: grid).route(from: from, to: to, map: map)
        }
        let path = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard path.length <= configuration.maximumRouteLength else { throw ObstacleRouteError.noPath }
        return path
    }

    func walkingRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> WalkingPath {
        let requestGeneration = generation
        // Serialize all Ghost AND goal requests, including queued Debug requests.
        while active != nil || Date() < nextRequestDate {
            try Task.checkCancellation()
            guard generation == requestGeneration else { throw CancellationError() }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try Task.checkCancellation()
        guard generation == requestGeneration else { throw CancellationError() }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        // Walking is for human-accessible Safe Light goals, not ghost pursuit.
        request.transportType = .walking
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        active = directions
        nextRequestDate = Date().addingTimeInterval(configuration.globalRoutingInterval)
        let timeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(configuration.routingTimeout * 1_000_000_000))
            if !Task.isCancelled { directions.cancel() }
        }
        defer {
            timeout.cancel()
            if active === directions { active = nil }
        }
        do {
            let response = try await withTaskCancellationHandler {
                try await directions.calculate()
            } onCancel: {
                Task { @MainActor in directions.cancel() }
            }
            try Task.checkCancellation()
            guard generation == requestGeneration,
                  let route = response.routes.filter({ $0.transportType == .walking }).min(by: { $0.distance < $1.distance }) else {
                throw WalkingRouteError.unavailable
            }
            var points = [CLLocationCoordinate2D](repeating: .init(), count: route.polyline.pointCount)
            route.polyline.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
            guard let path = WalkingPath(coordinates: points), path.length <= configuration.maximumRouteLength else {
                throw WalkingRouteError.invalidGeometry
            }
            return path
        } catch {
            if !Task.isCancelled, generation == requestGeneration {
                nextRequestDate = Date().addingTimeInterval(configuration.routeRetryInterval)
            }
            throw error // Never synthesize a direct route on failure.
        }
    }

    func cancelAll() {
        generation += 1
        obstacles.cancelAll()
        active?.cancel()
        active = nil
    }
}
