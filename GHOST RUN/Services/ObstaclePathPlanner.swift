import CoreLocation
import Foundation

enum ObstacleRouteError: Error { case blocked, noPath, incompleteData, unavailable, serverNotConfigured }

// A* only when a straight segment intersects mapped geometry. No road snapping.
struct ObstaclePathPlanner {
    let cellSize: Double
    let maximumVisited: Int
    init(cellSize: Double = 5, maximumVisited: Int = 80_000) {
        self.cellSize = max(2, cellSize)
        self.maximumVisited = maximumVisited
    }

    func route(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D,
               map: ObstacleMap) throws -> WalkingPath {
        let start = map.point(origin), end = map.point(destination)
        guard map.isClear(start, start), map.isClear(end, end) else { throw ObstacleRouteError.blocked }
        if map.isClear(start, end) {
            guard let result = WalkingPath(coordinates: [origin, destination], obstacleMap: map) else { throw ObstacleRouteError.noPath }
            return result
        }
        let side = Int(ceil(map.radius * 2 / cellSize))
        guard side > 0, side * side <= 200_000 else { throw ObstacleRouteError.noPath }
        func position(_ id: Int) -> GroundPoint {
            .init(x: -map.radius + (Double(id % side) + 0.5) * cellSize,
                  y: -map.radius + (Double(id / side) + 0.5) * cellSize)
        }
        func connections(_ p: GroundPoint) -> [Int] {
            let cx = Int(floor((p.x + map.radius) / cellSize)), cy = Int(floor((p.y + map.radius) / cellSize))
            var result: [Int] = []
            for dy in -2...2 { for dx in -2...2 {
                let x = cx + dx, y = cy + dy
                if x >= 0 && y >= 0 && x < side && y < side {
                    let id = y * side + x
                    if map.isClear(p, position(id)) { result.append(id) }
                }
            } }
            return result
        }
        let goals = Set(connections(end))
        guard !goals.isEmpty else { throw ObstacleRouteError.noPath }
        var costs = [Double](repeating: .infinity, count: side * side)
        var previous = [Int](repeating: -1, count: side * side)
        var closed = [Bool](repeating: false, count: side * side)
        var queue = PathMinHeap()
        for id in connections(start) {
            costs[id] = start.distance(to: position(id))
            queue.push(id: id, priority: costs[id] + position(id).distance(to: end))
        }
        var visited = 0
        while let current = queue.pop() {
            if closed[current] { continue }
            closed[current] = true
            visited += 1
            if visited % 128 == 0 { try Task.checkCancellation() }
            guard visited <= maximumVisited else { throw ObstacleRouteError.noPath }
            if goals.contains(current) {
                var cells = [GroundPoint]()
                var id = current
                while id >= 0 { cells.append(position(id)); id = previous[id] }
                let raw = [start] + cells.reversed() + [end]
                // Remove grid zigzags only if the entire replacement segment is clear.
                var simplified = [start]
                var anchor = 0
                while anchor < raw.count - 1 {
                    var next = raw.count - 1
                    while next > anchor + 1 && !map.isClear(raw[anchor], raw[next]) { next -= 1 }
                    guard map.isClear(raw[anchor], raw[next]) else { throw ObstacleRouteError.noPath }
                    simplified.append(raw[next])
                    anchor = next
                }
                guard let path = WalkingPath(coordinates: simplified.map(map.coordinate), obstacleMap: map) else { throw ObstacleRouteError.noPath }
                return path
            }
            let x = current % side, y = current / side
            for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                let nx = x + dx, ny = y + dy
                guard nx >= 0, ny >= 0, nx < side, ny < side else { continue }
                let neighbor = ny * side + nx
                guard !closed[neighbor] else { continue }
                let candidate = costs[current] + position(current).distance(to: position(neighbor))
                guard candidate < costs[neighbor], map.isClear(position(current), position(neighbor)) else { continue }
                costs[neighbor] = candidate
                previous[neighbor] = current
                queue.push(id: neighbor, priority: candidate + position(neighbor).distance(to: end))
            } }
        }
        throw ObstacleRouteError.noPath
    }
}

private struct PathMinHeap {
    private var nodes: [(id: Int, priority: Double)] = []
    mutating func push(id: Int, priority: Double) {
        nodes.append((id, priority))
        var index = nodes.count - 1
        while index > 0 {
            let parent = (index - 1) / 2
            if nodes[parent].priority <= priority { break }
            nodes.swapAt(parent, index)
            index = parent
        }
    }
    mutating func pop() -> Int? {
        guard let first = nodes.first else { return nil }
        if nodes.count == 1 { nodes.removeLast(); return first.id }
        nodes[0] = nodes.removeLast()
        var index = 0
        while index * 2 + 1 < nodes.count {
            var child = index * 2 + 1
            if child + 1 < nodes.count, nodes[child + 1].priority < nodes[child].priority { child += 1 }
            if nodes[index].priority <= nodes[child].priority { break }
            nodes.swapAt(index, child)
            index = child
        }
        return first.id
    }
}
