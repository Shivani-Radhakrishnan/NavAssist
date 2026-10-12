import Foundation

/// The walkable network of a place: the paths a sighted helper actually walked.
///
/// Every edge is a stretch someone has physically walked, so routes only ever use
/// space known to be passable. Landmarks ("Kitchen", "Front door") are named nodes.
public struct RouteGraph: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public var position: Vec2
        public var landmark: String?
    }

    public private(set) var nodes: [Node] = []
    /// Undirected adjacency: node id -> neighbour ids.
    public private(set) var neighbours: [Int: Set<Int>] = [:]

    public init() {}

    public var landmarks: [Node] {
        nodes.filter { $0.landmark != nil }
            .sorted { ($0.landmark ?? "").localizedCaseInsensitiveCompare($1.landmark ?? "") == .orderedAscending }
    }

    public func node(_ id: Int) -> Node { nodes[id] }

    @discardableResult
    public mutating func addNode(at p: Vec2, landmark: String? = nil) -> Int {
        let id = nodes.count
        nodes.append(Node(id: id, position: p, landmark: landmark))
        neighbours[id] = []
        return id
    }

    public mutating func connect(_ a: Int, _ b: Int) {
        guard a != b else { return }
        neighbours[a, default: []].insert(b)
        neighbours[b, default: []].insert(a)
    }

    public mutating func setLandmark(_ name: String?, on id: Int) {
        nodes[id].landmark = name
    }

    public mutating func removeLandmark(named name: String) {
        for i in nodes.indices where nodes[i].landmark == name { nodes[i].landmark = nil }
    }

    /// Nearest node to p, if any is within `maxDistance` meters.
    public func nearestNode(to p: Vec2, within maxDistance: Double = .infinity) -> Int? {
        var best: (Int, Double)?
        for n in nodes {
            let d = n.position.distance(to: p)
            if d <= maxDistance, d < (best?.1 ?? .infinity) { best = (n.id, d) }
        }
        return best?.0
    }

    /// Shortest walked route between two nodes (A*), or nil if they aren't connected.
    public func shortestPath(from start: Int, to goal: Int) -> [Int]? {
        guard nodes.indices.contains(start), nodes.indices.contains(goal) else { return nil }
        let goalPos = nodes[goal].position
        var open: Set<Int> = [start]
        var came: [Int: Int] = [:]
        var g: [Int: Double] = [start: 0]
        var f: [Int: Double] = [start: nodes[start].position.distance(to: goalPos)]

        while let cur = open.min(by: { f[$0, default: .infinity] < f[$1, default: .infinity] }) {
            if cur == goal {
                var path = [cur]
                var c = cur
                while let prev = came[c] {
                    path.append(prev)
                    c = prev
                }
                return path.reversed()
            }
            open.remove(cur)
            for nb in neighbours[cur, default: []] {
                let tentative = g[cur, default: .infinity] + nodes[cur].position.distance(to: nodes[nb].position)
                if tentative < g[nb, default: .infinity] {
                    came[nb] = cur
                    g[nb] = tentative
                    f[nb] = tentative + nodes[nb].position.distance(to: goalPos)
                    open.insert(nb)
                }
            }
        }
        return nil
    }

    public func positions(of path: [Int]) -> [Vec2] { path.map { nodes[$0].position } }
}

/// Turns a stream of positions from a walking helper into a RouteGraph.
///
/// A node is dropped every `spacing` meters. When the helper comes back within
/// `mergeRadius` of an older node (a junction or a loop), the trail joins that node
/// instead of creating a duplicate, which is what makes routes between different
/// recorded walks possible.
public struct TrailRecorder: Sendable {
    public var graph: RouteGraph
    public var spacing: Double
    public var mergeRadius: Double
    /// Nodes this recent are ignored when looking for a junction, so the trail
    /// doesn't snap back onto itself while walking a straight line.
    public var recentWindow: Int

    private var lastNode: Int?
    private var recent: [Int] = []

    public init(graph: RouteGraph = RouteGraph(), spacing: Double = 0.5,
                mergeRadius: Double = 0.7, recentWindow: Int = 6) {
        self.graph = graph
        self.spacing = spacing
        self.mergeRadius = mergeRadius
        self.recentWindow = recentWindow
    }

    /// Start a new walk (e.g. after a pause) without connecting it to the previous trail end.
    public mutating func breakTrail() {
        lastNode = nil
        recent = []
    }

    /// Feed the helper's current position. Returns true if the graph changed.
    @discardableResult
    public mutating func add(_ p: Vec2) -> Bool {
        if let last = lastNode, graph.node(last).position.distance(to: p) < spacing {
            return false
        }
        let id = junction(near: p) ?? graph.addNode(at: p)
        if let last = lastNode { graph.connect(last, id) }
        lastNode = id
        recent.append(id)
        if recent.count > recentWindow { recent.removeFirst() }
        return true
    }

    /// Name the spot where the helper is standing. Reuses a nearby node if there is one.
    @discardableResult
    public mutating func markLandmark(_ name: String, at p: Vec2) -> Int {
        graph.removeLandmark(named: name)
        let id: Int
        if let near = graph.nearestNode(to: p, within: spacing * 0.6) {
            id = near
        } else {
            id = graph.addNode(at: p)
            if let last = lastNode { graph.connect(last, id) }
            lastNode = id
            recent.append(id)
        }
        graph.setLandmark(name, on: id)
        return id
    }

    private func junction(near p: Vec2) -> Int? {
        var best: (Int, Double)?
        for n in graph.nodes where !recent.contains(n.id) {
            let d = n.position.distance(to: p)
            if d <= mergeRadius, d < (best?.1 ?? .infinity) { best = (n.id, d) }
        }
        return best?.0
    }
}
