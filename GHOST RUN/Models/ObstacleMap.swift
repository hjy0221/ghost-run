import CoreLocation
import Foundation

struct GroundPoint: Equatable, Sendable {
    var x: Double
    var y: Double
    func distance(to p: Self) -> Double { hypot(x - p.x, y - p.y) }
}

struct GroundBounds: Sendable {
    let minX: Double, minY: Double, maxX: Double, maxY: Double
    func contains(_ p: GroundPoint, inset: Double = 0) -> Bool {
        p.x >= minX + inset && p.x <= maxX - inset && p.y >= minY + inset && p.y <= maxY - inset
    }
    func overlaps(_ b: Self) -> Bool {
        maxX >= b.minX && b.maxX >= minX && maxY >= b.minY && b.maxY >= minY
    }
    static func around(_ a: GroundPoint, _ b: GroundPoint, padding: Double = 0) -> Self {
        .init(minX: min(a.x, b.x) - padding, minY: min(a.y, b.y) - padding,
              maxX: max(a.x, b.x) + padding, maxY: max(a.y, b.y) + padding)
    }
}

struct GroundObstacle: Sendable {
    let points: [GroundPoint]
    let isArea: Bool
    let bounds: GroundBounds
    init?(points: [GroundPoint], isArea: Bool = true) {
        guard points.count >= (isArea ? 3 : 2), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        self.points = points
        self.isArea = isArea
        bounds = GroundBounds(minX: points.map(\.x).min()!, minY: points.map(\.y).min()!,
                              maxX: points.map(\.x).max()!, maxY: points.map(\.y).max()!)
    }

    func contains(_ p: GroundPoint) -> Bool {
        guard isArea, bounds.contains(p) else { return false }
        var inside = false
        var j = points.count - 1
        for i in points.indices {
            let a = points[i], b = points[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    func blocks(_ a: GroundPoint, _ b: GroundPoint, clearance: Double) -> Bool {
        guard bounds.overlaps(.around(a, b, padding: clearance)) else { return false }
        if contains(a) || contains(b) { return true }
        let edgeCount = isArea ? points.count : points.count - 1
        for i in 0..<edgeCount {
            let c = points[i], d = points[(i + 1) % points.count]
            if Self.intersects(a, b, c, d)
                || Self.pointDistance(a, c, d) <= clearance
                || Self.pointDistance(b, c, d) <= clearance
                || Self.pointDistance(c, a, b) <= clearance
                || Self.pointDistance(d, a, b) <= clearance { return true }
        }
        return false
    }

    private static func pointDistance(_ p: GroundPoint, _ a: GroundPoint, _ b: GroundPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
        return hypot(p.x - a.x - dx * t, p.y - a.y - dy * t)
    }

    private static func intersects(_ a: GroundPoint, _ b: GroundPoint, _ c: GroundPoint, _ d: GroundPoint) -> Bool {
        guard GroundBounds.around(a, b).overlaps(.around(c, d)) else { return false }
        func cross(_ p: GroundPoint, _ q: GroundPoint, _ r: GroundPoint) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        return cross(a, b, c) * cross(a, b, d) <= 0 && cross(c, d, a) * cross(c, d, b) <= 0
    }
}

// Immutable, session-only regional geometry. Missing/partial data never means open space.
struct ObstacleMap: Sendable {
    let latitude: Double
    let longitude: Double
    let radius: Double
    let obstacles: [GroundObstacle]
    let fetchedAt: Date
    let clearance: Double
    private let bins: [Int: [Int]]
    private let binWidth: Int
    private let binSize = 40.0
    var bounds: GroundBounds { .init(minX: -radius, minY: -radius, maxX: radius, maxY: radius) }

    init(latitude: Double, longitude: Double, radius: Double, obstacles: [GroundObstacle],
         fetchedAt: Date = Date(), clearance: Double = 2) {
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.obstacles = obstacles
        self.fetchedAt = fetchedAt
        self.clearance = clearance
        binWidth = Int(ceil(radius * 2 / binSize)) + 1
        var index: [Int: [Int]] = [:]
        for (id, obstacle) in obstacles.enumerated() {
            let b = obstacle.bounds
            let x0 = max(0, Int(floor((b.minX + radius) / binSize)))
            let x1 = min(binWidth - 1, Int(floor((b.maxX + radius) / binSize)))
            let y0 = max(0, Int(floor((b.minY + radius) / binSize)))
            let y1 = min(binWidth - 1, Int(floor((b.maxY + radius) / binSize)))
            if x0 <= x1 && y0 <= y1 {
                for y in y0...y1 { for x in x0...x1 { index[y * binWidth + x, default: []].append(id) } }
            }
        }
        bins = index
    }

    func point(_ coordinate: CLLocationCoordinate2D) -> GroundPoint {
        .init(x: (coordinate.longitude - longitude) * 111_320 * cos(latitude * .pi / 180),
              y: (coordinate.latitude - latitude) * 111_320)
    }
    func coordinate(_ p: GroundPoint) -> CLLocationCoordinate2D {
        .init(latitude: latitude + p.y / 111_320,
              longitude: longitude + p.x / (111_320 * cos(latitude * .pi / 180)))
    }
    func covers(_ coordinate: CLLocationCoordinate2D, margin: Double = 0) -> Bool {
        CLLocationCoordinate2DIsValid(coordinate) && bounds.contains(point(coordinate), inset: max(margin, clearance))
    }
    func isClear(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(from), CLLocationCoordinate2DIsValid(to) else { return false }
        return isClear(point(from), point(to))
    }
    func isClear(_ a: GroundPoint, _ b: GroundPoint) -> Bool {
        guard bounds.contains(a, inset: clearance), bounds.contains(b, inset: clearance) else { return false }
        let box = GroundBounds.around(a, b, padding: clearance)
        let x0 = max(0, Int(floor((box.minX + radius) / binSize)))
        let x1 = min(binWidth - 1, Int(floor((box.maxX + radius) / binSize)))
        let y0 = max(0, Int(floor((box.minY + radius) / binSize)))
        let y1 = min(binWidth - 1, Int(floor((box.maxY + radius) / binSize)))
        var visited = Set<Int>()
        for y in y0...y1 { for x in x0...x1 {
            for id in bins[y * binWidth + x] ?? [] where visited.insert(id).inserted {
                if obstacles[id].blocks(a, b, clearance: clearance) { return false }
            }
        } }
        return true
    }
}
