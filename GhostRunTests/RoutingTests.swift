import CoreLocation
import XCTest
@testable import ZombieRun

final class RoutingTests: XCTestCase {
    let origin = CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
    func point(_ north: Double, _ east: Double) -> CLLocationCoordinate2D {
        GeoMath.coordinate(from: GeoMath.coordinate(from: origin, distance: north, bearingDegrees: 0), distance: east, bearingDegrees: 90)
    }

    func testCursorFollowsCornersInsteadOfCuttingAcrossBlock() {
        let path = WalkingPath(coordinates: [point(0, 0), point(100, 0), point(100, 100), point(0, 100)])!
        var cursor = WalkingCursor(path: path)
        cursor.advance(meters: 150)
        XCTAssertLessThan(GeoMath.distance(from: cursor.coordinate, to: point(100, 50)), 2)
        XCTAssertGreaterThan(cursor.remainingDistance, 140)
        XCTAssertGreaterThan(GeoMath.distance(from: cursor.coordinate, to: point(0, 50)), 90)
    }

    func testCursorStopsAtEndAndNeverFallsBackToPlayer() {
        let end = point(0, 100)
        var cursor = WalkingCursor(path: WalkingPath(coordinates: [origin, end])!)
        cursor.advance(meters: 1_000)
        cursor.advance(meters: 100)
        XCTAssertEqual(cursor.remainingDistance, 0, accuracy: 0.01)
        XCTAssertLessThan(GeoMath.distance(from: cursor.coordinate, to: end), 0.1)
    }

    func testProjectionPreservesWalkingDistanceAroundObstacle() {
        let path = WalkingPath(coordinates: [point(0, 0), point(100, 0), point(100, 10), point(0, 10)])!
        let player = path.projection(of: point(0, 10))
        XCTAssertGreaterThan(player.offset, 200)
        XCTAssertLessThan(player.separation, 0.1)
    }

    func testSafeLightAndGhostSlicesStayOnPath() {
        let path = WalkingPath(coordinates: [point(0, 0), point(100, 0), point(100, 100)])!
        let suffix = path.suffix(from: 50)!
        let prefix = path.prefix(through: 150)!
        XCTAssertEqual(suffix.length, 150, accuracy: 2)
        XCTAssertEqual(prefix.length, 150, accuracy: 2)
        XCTAssertLessThan(GeoMath.distance(from: prefix.coordinates.last!, to: point(100, 50)), 2)
    }

    func testInvalidOrDegenerateGeometryIsRejected() {
        XCTAssertNil(WalkingPath(coordinates: []))
        XCTAssertNil(WalkingPath(coordinates: [origin, origin]))
        XCTAssertNil(WalkingPath(coordinates: [origin, .init(latitude: .nan, longitude: 0)]))
    }

    func testDangerThresholdDoesNotBypassCatchGracePeriod() {
        XCTAssertEqual(DangerLevel.evaluate(distance: nil, configuration: .standard), .unknown)
        XCTAssertEqual(DangerLevel.evaluate(distance: 300, configuration: .standard), .safe)
        XCTAssertEqual(DangerLevel.evaluate(distance: 180, configuration: .standard), .watch)
        XCTAssertEqual(DangerLevel.evaluate(distance: 90, configuration: .standard), .danger)
        XCTAssertEqual(DangerLevel.evaluate(distance: 1, configuration: .standard), .critical)
    }
}
