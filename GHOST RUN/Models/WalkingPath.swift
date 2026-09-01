import CoreLocation
import MapKit

// Reuse the existing polyline cursor for both walking goals and obstacle-checked
// pursuit. Straight segments are allowed only when validated by ObstacleMap.
struct WalkingPath {
    let coordinates: [CLLocationCoordinate2D]
    let cumulativeDistances: [Double]
    let obstacleMap: ObstacleMap?
    var length: Double { cumulativeDistances.last ?? 0 }

    init?(coordinates: [CLLocationCoordinate2D], obstacleMap: ObstacleMap? = nil) {
        guard coordinates.count >= 2, coordinates.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
        var cleaned = [coordinates[0]]
        for point in coordinates.dropFirst() {
            if GeoMath.distance(from: cleaned.last!, to: point) > 0.05 { cleaned.append(point) }
        }
        guard cleaned.count >= 2 else { return nil }
        self.coordinates = cleaned
        self.obstacleMap = obstacleMap
        var distances = [0.0]
        for index in 1..<cleaned.count {
            distances.append(distances.last! + GeoMath.distance(from: cleaned[index - 1], to: cleaned[index]))
        }
        cumulativeDistances = distances
    }

    func coordinate(at distance: Double) -> CLLocationCoordinate2D {
        let offset = max(0, min(length, distance))
        for index in 1..<coordinates.count where offset <= cumulativeDistances[index] {
            let fraction = (offset - cumulativeDistances[index - 1]) / (cumulativeDistances[index] - cumulativeDistances[index - 1])
            let start = MKMapPoint(coordinates[index - 1])
            let end = MKMapPoint(coordinates[index])
            return MKMapPoint(x: start.x + (end.x - start.x) * fraction,
                              y: start.y + (end.y - start.y) * fraction).coordinate
        }
        return coordinates.last!
    }

    func projection(of coordinate: CLLocationCoordinate2D) -> (offset: Double, separation: Double) {
        let point = MKMapPoint(coordinate)
        var best = (offset: 0.0, separation: Double.infinity)
        for index in 1..<coordinates.count {
            let start = MKMapPoint(coordinates[index - 1]), end = MKMapPoint(coordinates[index])
            let dx = end.x - start.x, dy = end.y - start.y
            let fraction = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / (dx * dx + dy * dy)))
            let projected = MKMapPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            let separation = point.distance(to: projected)
            if separation < best.separation {
                best = (cumulativeDistances[index - 1] + (cumulativeDistances[index] - cumulativeDistances[index - 1]) * fraction, separation)
            }
        }
        return best
    }

    func suffix(from offset: Double) -> WalkingPath? {
        let points = zip(coordinates, cumulativeDistances).filter { $0.1 > offset + 0.05 }.map(\.0)
        return WalkingPath(coordinates: [coordinate(at: offset)] + points, obstacleMap: obstacleMap)
    }

    func prefix(through offset: Double) -> WalkingPath? {
        let points = zip(coordinates, cumulativeDistances).filter { $0.1 < offset - 0.05 }.map(\.0)
        return WalkingPath(coordinates: points + [coordinate(at: offset)], obstacleMap: obstacleMap)
    }
}

struct WalkingCursor {
    let path: WalkingPath
    private(set) var distanceAlongRoute = 0.0
    var remainingDistance: Double { max(0, path.length - distanceAlongRoute) }
    var coordinate: CLLocationCoordinate2D { path.coordinate(at: distanceAlongRoute) }

    mutating func advance(meters: Double) {
        guard meters.isFinite, meters > 0 else { return }
        distanceAlongRoute = min(path.length, distanceAlongRoute + meters)
    }
}
