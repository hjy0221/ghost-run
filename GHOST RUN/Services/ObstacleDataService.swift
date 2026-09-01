import CoreLocation
import Foundation

@MainActor
protocol ObstacleMapProviding: AnyObject {
    func map(around coordinate: CLLocationCoordinate2D) async throws -> ObstacleMap
    func cancelAll()
}

// The public Overpass endpoint is for this developer's prototype only. A shipped
// app must configure its own/contracted endpoint; public infrastructure is not an app backend.
@MainActor
final class ObstacleDataService: ObstacleMapProviding {
    private let configuration: GameConfiguration
    private let session: URLSession
    private let endpoint: URL?
    private var cache: ObstacleMap?
    private var inFlight: Task<ObstacleMap, Error>?
    private var generation = 0
    private var nextRequest = Date.distantPast

    init(configuration: GameConfiguration = .standard, endpoint: URL? = nil, session: URLSession? = nil) {
        self.configuration = configuration
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 25
        settings.timeoutIntervalForResource = 30
        settings.urlCache = nil
        settings.httpCookieStorage = nil
        self.session = session ?? URLSession(configuration: settings)
        let configured = (Bundle.main.object(forInfoDictionaryKey: "GhostObstacleEndpoint") as? String).flatMap(URL.init(string:))
#if DEBUG
        self.endpoint = endpoint ?? configured ?? URL(string: "https://overpass-api.de/api/interpreter")
#else
        self.endpoint = endpoint ?? configured
#endif
    }

    func map(around coordinate: CLLocationCoordinate2D) async throws -> ObstacleMap {
        try Task.checkCancellation()
        guard CLLocationCoordinate2DIsValid(coordinate), abs(coordinate.latitude) < 80 else { throw ObstacleRouteError.unavailable }
        let margin = configuration.spawnDistance.upperBound + 110
        if let cache, Date().timeIntervalSince(cache.fetchedAt) < configuration.obstacleCacheDuration,
           cache.covers(coordinate, margin: margin) { return cache }
        let requestGeneration = generation
        if let inFlight {
            let result = try await inFlight.value
            try Task.checkCancellation()
            guard requestGeneration == generation, result.covers(coordinate, margin: margin) else { throw ObstacleRouteError.unavailable }
            return result
        }
        guard let endpoint, endpoint.scheme == "https" else { throw ObstacleRouteError.serverNotConfigured }
        guard Date() >= nextRequest else { throw ObstacleRouteError.unavailable }
        nextRequest = Date().addingTimeInterval(configuration.obstacleRequestInterval)

        // Send a coarse regional bounding box, not the exact player fix or route.
        let latitude = (coordinate.latitude / 0.002).rounded() * 0.002
        let longitude = (coordinate.longitude / 0.002).rounded() * 0.002
        let radius = configuration.obstacleQueryRadius
        let dy = radius / 111_320, dx = radius / (111_320 * cos(latitude * .pi / 180))
        let bbox = "\(latitude - dy),\(longitude - dx),\(latitude + dy),\(longitude + dx)"
        let query = """
        [out:json][timeout:20][maxsize:33554432];
        (way["building"]["building"!="no"](\(bbox));relation["building"]["building"!="no"](\(bbox));
         way["building:part"]["building:part"!="no"](\(bbox));relation["building:part"]["building:part"!="no"](\(bbox));
         way["natural"="water"](\(bbox));relation["natural"="water"](\(bbox));
         way["barrier"~"^(wall|fence|retaining_wall)$"](\(bbox)););out geom;
        """
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("GhostRun-DevelopmentPrototype/1.0", forHTTPHeaderField: "User-Agent")
        var encoded = URLComponents()
        encoded.queryItems = [.init(name: "data", value: query)]
        request.httpBody = encoded.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        let clearance = configuration.obstacleClearance
        let task = Task { [session] in
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 8_388_608 else { throw ObstacleRouteError.unavailable }
            return try await Task.detached(priority: .userInitiated) {
                try OverpassObstacleDecoder.decode(data, latitude: latitude, longitude: longitude,
                                                   radius: radius, clearance: clearance)
            }.value
        }
        inFlight = task
        defer { if requestGeneration == generation { inFlight = nil } }
        let result = try await task.value
        try Task.checkCancellation()
        guard requestGeneration == generation else { throw CancellationError() }
        cache = result
        return result
    }

    func cancelAll() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        cache = nil
    }
}

enum OverpassObstacleDecoder {
    private struct Reply: Decodable { let elements: [Element]; let remark: String? }
    private struct Coordinate: Decodable {
        let lat: Double, lon: Double
        var value: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    }
    private struct Member: Decodable { let type: String; let ref: Int64?; let role: String?; let geometry: [Coordinate]? }
    private struct Element: Decodable {
        let id: Int64?
        let type: String
        let tags: [String: String]?
        let geometry: [Coordinate]?
        let members: [Member]?
    }

    static func decode(_ data: Data, latitude: Double, longitude: Double, radius: Double,
                       clearance: Double = 2, fetchedAt: Date = Date()) throws -> ObstacleMap {
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        // Overpass can return HTTP 200 with a partial result and an error remark.
        guard reply.remark == nil, !reply.elements.isEmpty, reply.elements.count <= 20_000 else {
            throw ObstacleRouteError.incompleteData
        }
        let frame = ObstacleMap(latitude: latitude, longitude: longitude, radius: radius, obstacles: [], clearance: clearance)
        var obstacles: [GroundObstacle] = []
        var totalPoints = 0
        let relations = Dictionary(reply.elements.compactMap { element -> (Int64, Element)? in
            guard element.type == "relation", let id = element.id else { return nil }
            return (id, element)
        }, uniquingKeysWith: { first, _ in first })
        func points(_ coordinates: [Coordinate]?) throws -> [GroundPoint] {
            guard let coordinates, coordinates.count >= 2,
                  coordinates.allSatisfy({ CLLocationCoordinate2DIsValid($0.value) }) else { throw ObstacleRouteError.incompleteData }
            totalPoints += coordinates.count
            guard totalPoints <= 150_000 else { throw ObstacleRouteError.incompleteData }
            return coordinates.map { frame.point($0.value) }
        }
        func outerFragments(_ element: Element, depth: Int = 0) throws -> [[GroundPoint]] {
            guard depth < 8, let members = element.members else { throw ObstacleRouteError.incompleteData }
            let roles = element.tags?["type"] == "building" ? ["outline"] : ["outer", ""]
            let outer = members.filter { roles.contains($0.role ?? "") }
            var fragments: [[GroundPoint]] = []
            for member in outer {
                if member.type == "way" { fragments.append(try points(member.geometry)) }
                else if member.type == "relation", let ref = member.ref, let child = relations[ref] {
                    fragments.append(contentsOf: try outerFragments(child, depth: depth + 1))
                } else if member.type != "node" { throw ObstacleRouteError.incompleteData }
                // A point member has no area/edge; it cannot replace the complete way rings.
            }
            guard !fragments.isEmpty else { throw ObstacleRouteError.incompleteData }
            return fragments
        }
        for element in reply.elements {
            try Task.checkCancellation()
            let tags = element.tags ?? [:]
            let area = (tags["building"].map { $0 != "no" } ?? false)
                || (tags["building:part"].map { $0 != "no" } ?? false) || tags["natural"] == "water"
            let wall = ["wall", "fence", "retaining_wall"].contains(tags["barrier"] ?? "")
            guard area || wall else { continue }
            if element.type == "way" {
                let vertices = try points(element.geometry)
                if area, vertices.first!.distance(to: vertices.last!) > 0.05 { throw ObstacleRouteError.incompleteData }
                guard let shape = GroundObstacle(points: area ? Array(vertices.dropLast()) : vertices, isArea: area) else {
                    throw ObstacleRouteError.incompleteData
                }
                obstacles.append(shape)
            } else if element.type == "relation", area {
                // Conservatively fill courtyard holes; do not guess through gaps.
                var fragments = try outerFragments(element)
                while var ring = fragments.popLast() {
                    while ring.first!.distance(to: ring.last!) > 0.05 {
                        guard let index = fragments.firstIndex(where: {
                            ring.last!.distance(to: $0.first!) < 0.05 || ring.last!.distance(to: $0.last!) < 0.05
                        }) else { throw ObstacleRouteError.incompleteData }
                        var next = fragments.remove(at: index)
                        if ring.last!.distance(to: next.first!) >= 0.05 { next.reverse() }
                        ring.append(contentsOf: next.dropFirst())
                    }
                    guard let shape = GroundObstacle(points: Array(ring.dropLast())) else { throw ObstacleRouteError.incompleteData }
                    obstacles.append(shape)
                }
            } else { throw ObstacleRouteError.incompleteData }
        }
        guard !obstacles.isEmpty else { throw ObstacleRouteError.incompleteData }
        return ObstacleMap(latitude: latitude, longitude: longitude, radius: radius, obstacles: obstacles,
                           fetchedAt: fetchedAt, clearance: clearance)
    }
}
