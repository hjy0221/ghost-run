import CoreLocation
import XCTest
@testable import ZombieRun

final class ObstacleTests: XCTestCase {
    func map(_ obstacles: [GroundObstacle] = [], radius: Double = 150) -> ObstacleMap {
        ObstacleMap(latitude: 37.57, longitude: 126.98, radius: radius, obstacles: obstacles)
    }
    func rectangle(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> GroundObstacle {
        GroundObstacle(points: [.init(x: x0, y: y0), .init(x: x1, y: y0), .init(x: x1, y: y1), .init(x: x0, y: y1)])!
    }
    func route(_ map: ObstacleMap, _ start: GroundPoint, _ end: GroundPoint) throws -> WalkingPath {
        try ObstaclePathPlanner().route(from: map.coordinate(start), to: map.coordinate(end), map: map)
    }
    func assertClear(_ path: WalkingPath, map: ObstacleMap, file: StaticString = #filePath, line: UInt = #line) {
        for index in 1..<path.coordinates.count {
            XCTAssertTrue(map.isClear(from: path.coordinates[index - 1], to: path.coordinates[index]), file: file, line: line)
        }
        var cursor = WalkingCursor(path: path)
        while cursor.remainingDistance > 0 {
            cursor.advance(meters: 0.5)
            XCTAssertTrue(map.isClear(from: cursor.coordinate, to: cursor.coordinate), file: file, line: line)
        }
    }
    func testOpenSpaceUsesDirectPursuitWithoutWalkingRoad() throws {
        let area = map()
        let path = try route(area, .init(x: -80, y: -50), .init(x: 80, y: 50))
        XCTAssertEqual(path.coordinates.count, 2)
        XCTAssertNotNil(path.obstacleMap)
        assertClear(path, map: area)
    }
    func testBuildingForcesDetourAndEveryMovementStepStaysOutside() throws {
        let area = map([rectangle(-20, -35, 20, 35)])
        let path = try route(area, .init(x: -80, y: 0), .init(x: 80, y: 0))
        XCTAssertGreaterThan(path.coordinates.count, 2)
        XCTAssertGreaterThan(path.length, 170)
        assertClear(path, map: area)
    }
    func testClearancePreventsClippingBuildingCorner() {
        let area = map([rectangle(-10, -10, 10, 10)])
        XCTAssertFalse(area.isClear(.init(x: -50, y: 11), .init(x: 50, y: 11)))
        XCTAssertTrue(area.isClear(.init(x: -50, y: 14), .init(x: 50, y: 14)))
    }
    func testNoTeleportOutOfBuildingOrUnknownCoverage() {
        let area = map([rectangle(-10, -10, 10, 10)])
        XCTAssertThrowsError(try route(area, .init(x: 0, y: 0), .init(x: 80, y: 0)))
        XCTAssertThrowsError(try route(area, .init(x: 80, y: 0), .init(x: 180, y: 0)))
    }
    func testImpassableBarrierDoesNotFallBackToDirectChase() {
        let area = map([rectangle(-5, -200, 5, 200)])
        XCTAssertThrowsError(try route(area, .init(x: -80, y: 0), .init(x: 80, y: 0)))
    }
    func testThinWallCannotBeSkippedByGridDiagonal() throws {
        let wall = GroundObstacle(points: [.init(x: 0, y: -45), .init(x: 0, y: 45)], isArea: false)!
        let area = map([wall])
        let path = try route(area, .init(x: -60, y: 0), .init(x: 60, y: 0))
        assertClear(path, map: area)
        XCTAssertGreaterThan(path.length, 140)
    }
    func testConcaveFootprintAndTwoBuildings() throws {
        let concave = GroundObstacle(points: [.init(x: -20, y: -20), .init(x: 20, y: -20), .init(x: 20, y: 0),
                                              .init(x: 0, y: 0), .init(x: 0, y: 30), .init(x: -20, y: 30)])!
        let area = map([concave, rectangle(35, 20, 65, 70)])
        let path = try route(area, .init(x: -90, y: 0), .init(x: 90, y: 40))
        assertClear(path, map: area)
    }
    func testSpawnSlicesKeepCollisionMetadata() throws {
        let area = map([rectangle(-20, -35, 20, 35)])
        let path = try route(area, .init(x: -100, y: 0), .init(x: 100, y: 0))
        let tail = path.suffix(from: 40)!
        XCTAssertNotNil(tail.obstacleMap)
        assertClear(tail, map: area)
    }

    private func json(_ elements: [[String: Any]], remark: String? = nil) throws -> Data {
        var object: [String: Any] = ["elements": elements]
        if let remark { object["remark"] = remark }
        return try JSONSerialization.data(withJSONObject: object)
    }
    private var ring: [[String: Double]] {
        [["lat": 37.5698, "lon": 126.9798], ["lat": 37.5698, "lon": 126.9802],
         ["lat": 37.5702, "lon": 126.9802], ["lat": 37.5702, "lon": 126.9798],
         ["lat": 37.5698, "lon": 126.9798]]
    }
    private var building: [String: Any] { ["type": "way", "id": 1, "tags": ["building": "yes"], "geometry": ring] }
    private func decode(_ data: Data) throws -> ObstacleMap {
        try OverpassObstacleDecoder.decode(data, latitude: 37.57, longitude: 126.98, radius: 650)
    }
    func testDecoderReadsBuildingAndWater() throws {
        let water: [String: Any] = ["type": "way", "tags": ["natural": "water"], "geometry": ring]
        let result = try decode(json([building, water]))
        XCTAssertEqual(result.obstacles.count, 2)
        XCTAssertFalse(result.isClear(.init(x: 0, y: 0), .init(x: 0, y: 0)))
    }
    func testDecoderJoinsFragmentedOuterWays() throws {
        let relation: [String: Any] = ["type": "relation", "tags": ["building": "yes", "type": "multipolygon"], "members": [
            ["type": "way", "role": "outer", "geometry": Array(ring.prefix(3))],
            ["type": "way", "role": "outer", "geometry": Array(ring.suffix(3)).reversed().map { $0 }]]]
        let result = try decode(json([relation]))
        XCTAssertEqual(result.obstacles.count, 1)
        XCTAssertFalse(result.isClear(.init(x: 0, y: 0), .init(x: 0, y: 0)))
    }
    func testDecoderResolvesNestedBuildingOutline() throws {
        let child: [String: Any] = ["id": 2, "type": "relation", "tags": ["building": "yes", "type": "multipolygon"], "members": [
            ["type": "way", "role": "outer", "geometry": ring], ["type": "node", "role": "outer", "ref": 9]]]
        let parent: [String: Any] = ["id": 3, "type": "relation", "tags": ["building": "yes", "type": "building"], "members": [
            ["type": "relation", "role": "outline", "ref": 2]]]
        let result = try decode(json([child, parent]))
        XCTAssertEqual(result.obstacles.count, 2)
    }
    func testDecoderNeverTreatsPartialOrEmptyResponseAsOpenSpace() throws {
        XCTAssertThrowsError(try decode(json([building], remark: "runtime error: timeout")))
        XCTAssertThrowsError(try decode(json([])))
        XCTAssertThrowsError(try decode(json([["type": "way", "tags": ["building": "yes"]]])))
    }
    func testUnclosedBuildingAndBrokenRelationAreRejected() throws {
        var broken = building
        broken["geometry"] = Array(ring.prefix(3))
        XCTAssertThrowsError(try decode(json([broken])))
        let relation: [String: Any] = ["type": "relation", "tags": ["building": "yes"], "members": [
            ["type": "way", "role": "outer", "geometry": Array(ring.prefix(3))]]]
        XCTAssertThrowsError(try decode(json([relation])))
    }
    func testCourtyardHoleIsConservativelyBlocked() throws {
        let relation: [String: Any] = ["type": "relation", "tags": ["building": "yes"], "members": [
            ["type": "way", "role": "outer", "geometry": ring], ["type": "way", "role": "inner", "geometry": ring]]]
        XCTAssertFalse(try decode(json([relation])).isClear(.init(x: 0, y: 0), .init(x: 0, y: 0)))
    }
    @MainActor func testPursuitUsesLocalObstaclePlannerAndFailsWithoutMap() async throws {
        let provider = FixedObstacleProvider(snapshot: map())
        let router = GhostRoutingService(obstacles: provider)
        let area = provider.snapshot
        let path = try await router.pursuitRoute(from: area.coordinate(.init(x: -80, y: 0)), to: area.coordinate(.init(x: 80, y: 0)))
        XCTAssertEqual(path.coordinates.count, 2)
        XCTAssertNotNil(path.obstacleMap)
        provider.unavailable = true
        do {
            _ = try await router.pursuitRoute(from: area.coordinate(.init(x: -80, y: 0)), to: area.coordinate(.init(x: 80, y: 0)))
            XCTFail("Missing data must not fall back to straight pursuit or walking")
        } catch {}
    }
    @MainActor func testOnlySpawnMayChooseAnotherOriginWhenProbeIsInsideBuilding() async throws {
        let area = map([rectangle(-20, -20, 20, 20)])
        let router = GhostRoutingService(obstacles: FixedObstacleProvider(snapshot: area))
        let blocked = area.coordinate(.init(x: 0, y: 0)), player = area.coordinate(.init(x: -80, y: 0))
        do { _ = try await router.pursuitRoute(from: blocked, to: player); XCTFail("Existing ghost must not teleport") } catch {}
        let path = try await router.spawnRoute(from: blocked, to: player)
        XCTAssertGreaterThan(GeoMath.distance(from: blocked, to: path.coordinates.first!), 10)
        assertClear(path, map: area)
    }

    @MainActor func testRegionFetchIsCachedAndDoesNotSendExactFix() async throws {
        MapHTTPStub.configure(data: try json([building]), status: 200)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [MapHTTPStub.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let service = ObstacleDataService(endpoint: URL(string: "https://map-test.invalid/query")!, session: session)
        let player = CLLocationCoordinate2D(latitude: 37.57012345, longitude: 126.98098765)
        async let first = service.map(around: player)
        async let second = service.map(around: player)
        _ = try await (first, second)
        _ = try await service.map(around: player)
        XCTAssertEqual(MapHTTPStub.requestCount, 1)
        let body = MapHTTPStub.lastBody.removingPercentEncoding ?? ""
        XCTAssertTrue(body.contains("[out:json]"))
        XCTAssertFalse(body.contains("37.57012345"))
        XCTAssertFalse(body.contains("126.98098765"))
        service.cancelAll()
        do { _ = try await service.map(around: player); XCTFail("Cancelled session must not retain the map cache") } catch {}
        XCTAssertEqual(MapHTTPStub.requestCount, 1) // network cooldown survives cancellation
    }
    @MainActor func testHTTPFailureBacksOffWithoutAnEmptyMap() async throws {
        MapHTTPStub.configure(data: try json([]), status: 429)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [MapHTTPStub.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let service = ObstacleDataService(endpoint: URL(string: "https://map-test.invalid/query")!, session: session)
        for _ in 0..<2 {
            do { _ = try await service.map(around: .init(latitude: 37.57, longitude: 126.98)); XCTFail("429 must not create open space") } catch {}
        }
        XCTAssertEqual(MapHTTPStub.requestCount, 1)
    }
}

@MainActor private final class FixedObstacleProvider: ObstacleMapProviding {
    let snapshot: ObstacleMap
    var unavailable = false
    init(snapshot: ObstacleMap) { self.snapshot = snapshot }
    func map(around coordinate: CLLocationCoordinate2D) async throws -> ObstacleMap {
        if unavailable { throw ObstacleRouteError.unavailable }
        return snapshot
    }
    func cancelAll() {}
}

private final class MapHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var payload = Data()
    private static var status = 200
    private static var requests = 0
    private static var body = ""
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static var lastBody: String { lock.lock(); defer { lock.unlock() }; return body }
    static func configure(data: Data, status code: Int) {
        lock.lock(); defer { lock.unlock() }
        payload = data; status = code; requests = 0; body = ""
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "map-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var requestData = request.httpBody ?? Data()
        if requestData.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while requestData.count < 16_384 {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                requestData.append(contentsOf: buffer.prefix(read))
            }
            stream.close()
        }
        Self.lock.lock()
        let data = Self.payload, status = Self.status
        Self.requests += 1
        Self.body = String(data: requestData, encoding: .utf8) ?? ""
        Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
