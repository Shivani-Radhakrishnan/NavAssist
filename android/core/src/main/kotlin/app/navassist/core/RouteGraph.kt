package app.navassist.core

import kotlin.math.abs
import kotlin.math.sqrt

/**
 * The walkable network of a place: the paths someone has actually walked with the app open.
 * Destinations are nodes with a spoken name ("Kitchen") or the text of a sign read there.
 */
class RouteGraph {
    data class Node(
        val id: Int,
        var position: Vec2,
        /** Height of the phone above the map's origin, in meters. Changes along a route mean stairs. */
        var height: Double? = null,
        /** Name the user gave this spot. */
        var landmark: String? = null,
        /** Text of a sign read by the camera at this spot. */
        var signText: String? = null,
    ) {
        /** What to call this spot when speaking. */
        val spokenName: String? get() = landmark ?: signText
    }

    private val _nodes = mutableListOf<Node>()
    val nodes: List<Node> get() = _nodes

    /** Undirected adjacency: node id -> neighbour ids. */
    private val _neighbours = mutableMapOf<Int, MutableSet<Int>>()
    val neighbours: Map<Int, Set<Int>> get() = _neighbours

    /** Spots the user named, alphabetically. */
    val landmarks: List<Node> get() = _nodes.filter { it.landmark != null }.sortedBy { it.landmark!!.lowercase() }

    /** Spots the user named plus spots where a sign was read. */
    val destinations: List<Node> get() = _nodes.filter { it.spokenName != null }

    fun node(id: Int): Node = _nodes[id]

    fun addNode(at: Vec2, height: Double? = null, landmark: String? = null): Int {
        val id = _nodes.size
        _nodes.add(Node(id, at, height, landmark))
        _neighbours[id] = mutableSetOf()
        return id
    }

    fun connect(a: Int, b: Int) {
        if (a == b) return
        _neighbours.getOrPut(a) { mutableSetOf() }.add(b)
        _neighbours.getOrPut(b) { mutableSetOf() }.add(a)
    }

    fun setLandmark(name: String?, on: Int) { _nodes[on].landmark = name }
    fun setSign(text: String?, on: Int) { _nodes[on].signText = text }

    fun removeLandmark(named: String) {
        val key = PlaceMatcher.normalize(named)
        _nodes.filter { it.landmark?.let(PlaceMatcher::normalize) == key }.forEach { it.landmark = null }
    }

    /** Nearest node to p within [maxDistance] meters, on the same floor when heights are known. */
    fun nearestNode(to: Vec2, height: Double? = null, within: Double = Double.POSITIVE_INFINITY): Int? =
        _nodes.filter { sameFloor(it.height, height) }
            .map { it.id to it.position.distanceTo(to) }
            .filter { it.second <= within }
            .minByOrNull { it.second }?.first

    /** Shortest walked route between two nodes (A*), or null if they aren't connected. */
    fun shortestPath(from: Int, to: Int): List<Int>? {
        if (from !in _nodes.indices || to !in _nodes.indices) return null
        val goal = _nodes[to].position
        val open = mutableSetOf(from)
        val came = mutableMapOf<Int, Int>()
        val g = mutableMapOf(from to 0.0)
        val f = mutableMapOf(from to _nodes[from].position.distanceTo(goal))
        while (open.isNotEmpty()) {
            val cur = open.minBy { f[it] ?: Double.POSITIVE_INFINITY }
            if (cur == to) {
                val path = mutableListOf(cur)
                var c = cur
                while (true) {
                    c = came[c] ?: break
                    path.add(c)
                }
                return path.reversed()
            }
            open.remove(cur)
            for (nb in _neighbours[cur].orEmpty()) {
                val tentative = (g[cur] ?: Double.POSITIVE_INFINITY) + _nodes[cur].position.distanceTo(_nodes[nb].position)
                if (tentative < (g[nb] ?: Double.POSITIVE_INFINITY)) {
                    came[nb] = cur
                    g[nb] = tentative
                    f[nb] = tentative + _nodes[nb].position.distanceTo(goal)
                    open.add(nb)
                }
            }
        }
        return null
    }

    fun positions(path: List<Int>): List<Vec2> = path.map { _nodes[it].position }
    fun heights(path: List<Int>): List<Double?> = path.map { _nodes[it].height }
}

/** Two heights are on the same floor unless both are known and more than 1.2 m apart. */
internal fun sameFloor(a: Double?, b: Double?): Boolean = a == null || b == null || abs(a - b) < 1.2

/**
 * Turns a stream of positions from someone walking into a [RouteGraph]: a node every
 * [spacing] meters, joining older nodes within [mergeRadius] on the same floor (junctions).
 */
class TrailRecorder(
    val graph: RouteGraph = RouteGraph(),
    val spacing: Double = 0.5,
    val mergeRadius: Double = 0.7,
    /** Recent nodes ignored when looking for a junction, so a straight walk doesn't snap back. */
    val recentWindow: Int = 6,
) {
    private var lastNode: Int? = null
    private val recent = ArrayDeque<Int>()

    /** Start a new walk without connecting it to the previous trail end. */
    fun breakTrail() {
        lastNode = null
        recent.clear()
    }

    /** Feed the walker's position. Returns true if the graph changed. */
    fun add(p: Vec2, height: Double? = null): Boolean {
        lastNode?.let { last ->
            val n = graph.node(last)
            val dh = (height ?: 0.0) - (n.height ?: height ?: 0.0)
            val d = n.position.distanceTo(p)
            // On stairs most of the movement is vertical, so count it too.
            if (sqrt(d * d + dh * dh) < spacing) return false
        }
        val id = junction(p, height) ?: graph.addNode(p, height)
        lastNode?.let { graph.connect(it, id) }
        lastNode = id
        recent.addLast(id)
        if (recent.size > recentWindow) recent.removeFirst()
        return true
    }

    /** Name the spot where the user stands (moving the name if it was used elsewhere). */
    fun markLandmark(name: String, at: Vec2, height: Double? = null): Int {
        graph.removeLandmark(name)
        val id = spot(at, height)
        graph.setLandmark(name, id)
        return id
    }

    /** Remember a sign read at p. Returns null if the same sign is already known within [dedupeRadius]. */
    fun markSign(text: String, at: Vec2, height: Double? = null, dedupeRadius: Double = 4.0): Int? {
        val key = PlaceMatcher.normalize(text)
        if (key.isEmpty()) return null
        val known = graph.nodes.any {
            it.signText?.let(PlaceMatcher::normalize) == key && sameFloor(it.height, height) &&
                it.position.distanceTo(at) <= dedupeRadius
        }
        if (known) return null
        val id = spot(at, height)
        val existing = graph.node(id).signText
        if (existing != null && existing != text) {
            val fresh = graph.addNode(at, height)
            graph.connect(id, fresh)
            graph.setSign(text, fresh)
            return fresh
        }
        graph.setSign(text, id)
        return id
    }

    private fun spot(at: Vec2, height: Double?): Int {
        graph.nearestNode(at, height, within = spacing * 0.6)?.let { return it }
        val id = graph.addNode(at, height)
        lastNode?.let { graph.connect(it, id) }
        lastNode = id
        recent.addLast(id)
        return id
    }

    private fun junction(p: Vec2, height: Double?): Int? =
        graph.nodes.asSequence()
            .filter { it.id !in recent && sameFloor(it.height, height) }
            .filter { n -> !(height != null && n.height != null && abs(height - n.height!!) > 0.3) }
            .map { it.id to it.position.distanceTo(p) }
            .filter { it.second <= mergeRadius }
            .minByOrNull { it.second }?.first
}
