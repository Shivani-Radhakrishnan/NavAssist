import Foundation

/// The walkable network of a place: the paths someone has actually walked with the app open.
///
/// Every edge is a stretch someone has physically walked, so routes only ever use
/// space known to be passable. Destinations are nodes with a spoken name ("Kitchen")
/// or with the text of a sign the camera read there ("Room 204").
public struct RouteGraph: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public var position: Vec2
        /// Height of the phone above the map's origin, in meters. Changes along a route mean stairs.
        public var height: Double?
        /// Name the user gave this spot.
        public var landmark: String?
        /// Text of a sign read by the camera at this spot.
        public var signText: String?

        /// What to call this spot when speaking.
        public var spokenName: String? { landmark ?? signText }
    }

    public private(set) var nodes: [Node] = []
    /// Undirected adjacency: node id -> neighbour ids.
    public private(set) var neighbours: [Int: Set<Int>] = [:]

    public init() {}

    /// Spots the user named, alphabetically.
    public var landmarks: [Node] {
        nodes.filter { $0.landmark != nil }
            .sorted { ($0.landmark ?? "").localizedCaseInsensitiveCompare($1.landmark ?? "") == .orderedAscending }
    }

    /// Spots the user named plus spots where a sign was read.
    public var destinations: [Node] { nodes.filter { $0.spokenName != nil } }

    public func node(_ id: Int) -> Node { nodes[id] }

    @discardableResult
    public mutating func addNode(at p: Vec2, height: Double? = nil, landmark: String? = nil) -> Int {
        let id = nodes.count
        nodes.append(Node(id: id, position: p, height: height, landmark: landmark, signText: nil))
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

    public mutating func setSign(_ text: String?, on id: Int) {
        nodes[id].signText = text
    }

    public mutating func removeLandmark(named name: String) {
        let key = PlaceMatcher.normalize(name)
        for i in nodes.indices where nodes[i].landmark.map(PlaceMatcher.normalize) == key { nodes[i].landmark = nil }
    }

    /// Nearest node to p, if any is within `maxDistance` meters (and, when heights are
    /// known, on the same floor).
    public func nearestNode(to p: Vec2, height: Double? = nil, within maxDistance: Double = .infinity) -> Int? {
        var best: (Int, Double)?
        for n in nodes where sameFloor(n.height, height) {
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
    public func heights(of path: [Int]) -> [Double?] { path.map { nodes[$0].height } }
}

/// Two heights are on the same floor unless both are known and more than 1.2 m apart.
func sameFloor(_ a: Double?, _ b: Double?) -> Bool {
    guard let a, let b else { return true }
    return abs(a - b) < 1.2
}

/// Turns a stream of positions from someone walking into a RouteGraph.
///
/// A node is dropped every `spacing` meters. When the walker comes back within
/// `mergeRadius` of an older node on the same floor (a junction or a loop), the trail
/// joins that node instead of creating a duplicate, which is what makes routes between
/// different walks possible.
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

    /// Start a new walk (e.g. after tracking was lost) without connecting it to the previous trail end.
    public mutating func breakTrail() {
        lastNode = nil
        recent = []
    }

    /// Feed the walker's current position. Returns true if the graph changed.
    @discardableResult
    public mutating func add(_ p: Vec2, height: Double? = nil) -> Bool {
        if let last = lastNode {
            let n = graph.node(last)
            let dh = (height ?? 0) - (n.height ?? height ?? 0)
            // On stairs most of the movement is vertical, so count it too.
            if (n.position.distance(to: p) * n.position.distance(to: p) + dh * dh).squareRoot() < spacing {
                return false
            }
        }
        let id = junction(near: p, height: height) ?? graph.addNode(at: p, height: height)
        if let last = lastNode { graph.connect(last, id) }
        lastNode = id
        recent.append(id)
        if recent.count > recentWindow { recent.removeFirst() }
        return true
    }

    /// Name the spot where the user is standing. Reuses a nearby node if there is one,
    /// and moves the name if it was used somewhere else before.
    @discardableResult
    public mutating func markLandmark(_ name: String, at p: Vec2, height: Double? = nil) -> Int {
        graph.removeLandmark(named: name)
        let id = spot(at: p, height: height)
        graph.setLandmark(name, on: id)
        return id
    }

    /// Remember a sign read at p. Returns nil if the same sign is already known within `dedupeRadius`.
    @discardableResult
    public mutating func markSign(_ text: String, at p: Vec2, height: Double? = nil, dedupeRadius: Double = 4) -> Int? {
        let key = PlaceMatcher.normalize(text)
        guard !key.isEmpty else { return nil }
        let known = graph.nodes.contains {
            $0.signText.map(PlaceMatcher.normalize) == key && sameFloor($0.height, height)
                && $0.position.distance(to: p) <= dedupeRadius
        }
        if known { return nil }
        let id = spot(at: p, height: height)
        if let existing = graph.node(id).signText, existing != text {
            // One sign per node: put this one on a fresh node joined to it.
            let fresh = graph.addNode(at: p, height: height)
            graph.connect(id, fresh)
            graph.setSign(text, on: fresh)
            return fresh
        }
        graph.setSign(text, on: id)
        return id
    }

    private mutating func spot(at p: Vec2, height: Double?) -> Int {
        if let near = graph.nearestNode(to: p, height: height, within: spacing * 0.6) { return near }
        let id = graph.addNode(at: p, height: height)
        if let last = lastNode { graph.connect(last, id) }
        lastNode = id
        recent.append(id)
        return id
    }

    private func junction(near p: Vec2, height: Double?) -> Int? {
        var best: (Int, Double)?
        for n in graph.nodes where !recent.contains(n.id) && sameFloor(n.height, height) {
            if let h = height, let nh = n.height, abs(h - nh) > 0.3 { continue }   // not across a stair flight
            let d = n.position.distance(to: p)
            if d <= mergeRadius, d < (best?.1 ?? .infinity) { best = (n.id, d) }
        }
        return best?.0
    }
}
