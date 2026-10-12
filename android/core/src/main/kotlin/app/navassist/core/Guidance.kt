package app.navassist.core

import kotlin.math.abs
import kotlin.math.max

enum class HapticCue { TURN_LEFT, TURN_RIGHT, ON_TRACK, WAYPOINT, ARRIVED, OFF_ROUTE, OBSTACLE, STOP }

sealed interface GuidanceEvent {
    /** [urgent] speech interrupts whatever is being said. */
    data class Speak(val text: String, val urgent: Boolean) : GuidanceEvent
    data class Haptic(val cue: HapticCue) : GuidanceEvent
    data object Arrived : GuidanceEvent
    /** The user has left the route; the caller should plan a new one from where they are. */
    data object OffRoute : GuidanceEvent
}

data class GuidanceSettings(
    val arriveRadius: Double = 0.8,
    val waypointRadius: Double = 0.9,
    val offRouteDistance: Double = 1.5,
    val offRouteSeconds: Double = 2.5,
    /** Facing more than this many degrees away from the next point counts as off course... */
    val misalignDegrees: Double = 35.0,
    /** ...and within this many degrees counts as back on course. */
    val alignDegrees: Double = 18.0,
    val headingPromptInterval: Double = 4.0,
    /** Warn about an upcoming turn this far before it. */
    val approachDistance: Double = 2.0,
    val phrasing: Phrasing = Phrasing(),
)

/**
 * Turn-by-turn guidance along one planned route. Feed it the user's position and facing
 * direction many times a second; it returns what to say and which vibration to play.
 * `heights` (one per route point) lets it warn about stairs.
 */
class Guide(
    route: List<Vec2>,
    heights: List<Double?>? = null,
    val destinationName: String,
    val settings: GuidanceSettings = GuidanceSettings(),
) {
    val stairs: List<StairFlight> = heights?.let { findStairs(route, it) } ?: emptyList()
    val route: List<Vec2> = removeShortLegs(simplifyRoute(route, 0.35), 0.6).let { simple ->
        when {
            simple.size >= 2 -> simple
            route.size == 1 -> listOf(route[0], route[0])
            else -> route
        }
    }

    /** Height of each kept route point, so arrival and turns happen on the right floor. */
    val routeHeights: List<Double?> = run {
        if (heights == null || heights.size != route.size) List(this.route.size) { null }
        else {
            var used = 0
            this.route.map { pt ->
                while (used < route.size - 1 && route[used] != pt) used++
                heights[minOf(used, heights.size - 1)]
            }
        }
    }

    /** The map node being navigated to, so a new route can be planned after going off route. */
    var destinationNodeId: Int? = null

    var target = 1
        private set
    var finished = false
        private set

    private var offSince: Double? = null
    private var currentHeight: Double? = null
    private var aligned = true
    private var lastHeadingPrompt = Double.NEGATIVE_INFINITY
    private val approachAnnounced = mutableSetOf<Int>()
    private val stairsWarned = mutableSetOf<Int>()
    private val stairsStarted = mutableSetOf<Int>()
    private val stairsEnded = mutableSetOf<Int>()
    private val say get() = settings.phrasing

    /** Remaining walking distance from p along the route. */
    fun remainingDistance(from: Vec2): Double {
        if (finished || target >= route.size) return 0.0
        var d = from.distanceTo(route[target])
        for (i in target until route.size - 1) d += route[i].distanceTo(route[i + 1])
        return d
    }

    val isLastLeg: Boolean get() = target >= route.size - 1

    /** The turn (degrees, positive = left) at the point being walked toward; 0 on the last leg. */
    val upcomingTurn: Double get() = turnAt(target)

    private fun legLength(p: Vec2) = p.distanceTo(route[target])

    private fun turnAt(i: Int): Double {
        if (i <= 0 || i + 1 >= route.size) return 0.0
        return wrapDegrees(signedAngle(route[i] - route[i - 1], route[i + 1] - route[i]))
    }

    fun start(position: Vec2, heading: Vec2, time: Double): List<GuidanceEvent> {
        val out = mutableListOf<GuidanceEvent>(
            GuidanceEvent.Speak("Route to $destinationName, ${say.distance(remainingDistance(position))}.", true))
        out += legCue(position, heading, null)
        lastHeadingPrompt = time
        return out
    }

    /** Tracking was lost or paused: forget a half-measured "off route" time. */
    fun pause() {
        offSince = null
    }

    fun update(position: Vec2, heading: Vec2, time: Double, height: Double? = null): List<GuidanceEvent> {
        if (finished) return emptyList()
        val p = position
        currentHeight = height
        val out = mutableListOf<GuidanceEvent>()

        if (p.distanceTo(route.last()) <= settings.arriveRadius && sameFloor(height, routeHeights.last())) {
            finished = true
            return listOf(GuidanceEvent.Haptic(HapticCue.ARRIVED),
                          GuidanceEvent.Speak("You have arrived at $destinationName.", true), GuidanceEvent.Arrived)
        }

        if (distanceToRemainingRoute(p) > settings.offRouteDistance) {
            if (offSince == null) offSince = time
            if (time - offSince!! >= settings.offRouteSeconds) {
                finished = true
                return listOf(GuidanceEvent.Haptic(HapticCue.OFF_ROUTE), GuidanceEvent.OffRoute)
            }
        } else {
            offSince = null
        }

        while (!isLastLeg && reachedTarget(p)) {
            val turnHere = turnAt(target)
            target += 1
            aligned = true
            out += GuidanceEvent.Haptic(when {
                abs(turnHere) < 20 -> HapticCue.WAYPOINT
                turnHere > 0 -> HapticCue.TURN_LEFT
                else -> HapticCue.TURN_RIGHT
            })
            out += legCue(p, heading, turnWords(turnHere) + " now")
            lastHeadingPrompt = time
        }

        out += stairCues(p)

        if (!isLastLeg && target !in approachAnnounced) {
            val d = p.distanceTo(route[target])
            val tw = turnAt(target)
            if (d <= settings.approachDistance && d > settings.waypointRadius && abs(tw) >= 20) {
                approachAnnounced += target
                out += GuidanceEvent.Speak("In ${say.distance(d)}, ${turnWords(tw).lowercase()}.", false)
            }
        }

        val rel = signedAngle(heading, route[target] - p)
        if (abs(rel) > settings.misalignDegrees) {
            aligned = false
            if (time - lastHeadingPrompt >= settings.headingPromptInterval) {
                lastHeadingPrompt = time
                out += GuidanceEvent.Haptic(if (rel > 0) HapticCue.TURN_LEFT else HapticCue.TURN_RIGHT)
                out += GuidanceEvent.Speak(headingPrompt(rel), false)
            }
        } else if (!aligned && abs(rel) <= settings.alignDegrees) {
            aligned = true
            out += GuidanceEvent.Haptic(HapticCue.ON_TRACK)
            out += GuidanceEvent.Speak("Straight ahead", false)
        }
        return out
    }

    /** Full status for a "where am I / repeat" request. */
    fun status(position: Vec2, heading: Vec2): String {
        if (finished) return "No active route."
        val parts = mutableListOf("$destinationName is ${say.distance(remainingDistance(position))} away.")
        val rel = signedAngle(heading, route[target] - position)
        if (abs(rel) > settings.misalignDegrees) parts += headingPrompt(rel) + "."
        parts += if (isLastLeg) "Walk ${say.distance(legLength(position))} to arrive."
                 else "Walk ${say.distance(legLength(position))}, then ${turnWords(turnAt(target)).lowercase()}."
        return parts.joinToString(" ")
    }

    private fun stairCues(p: Vec2): List<GuidanceEvent> {
        val out = mutableListOf<GuidanceEvent>()
        stairs.forEachIndexed { i, f ->
            val toStart = p.distanceTo(f.start)
            if (i !in stairsWarned && toStart <= 4 && toStart > 1.2) {
                stairsWarned += i
                out += GuidanceEvent.Haptic(HapticCue.OBSTACLE)
                val handrail = if (f.steps > 2) "Hold the handrail." else ""
                out += GuidanceEvent.Speak("${f.description.replaceFirstChar { it.uppercase() }} in ${say.distance(toStart)}. $handrail", true)
            }
            if (i !in stairsStarted && toStart <= 1.2) {
                stairsWarned += i
                stairsStarted += i
                out += GuidanceEvent.Haptic(HapticCue.STOP)
                val dir = if (f.goingUp) "up" else "down"
                out += GuidanceEvent.Speak(if (f.steps == 1) "Step $dir now." else "Stairs now, going $dir.", true)
            }
            if (i in stairsStarted && i !in stairsEnded && f.steps > 1 && p.distanceTo(f.end) <= 0.8) {
                stairsEnded += i
                out += GuidanceEvent.Haptic(HapticCue.ON_TRACK)
                out += GuidanceEvent.Speak("End of stairs.", false)
            }
        }
        return out
    }

    private fun legCue(p: Vec2, h: Vec2, prefix: String?): List<GuidanceEvent> {
        val rel = signedAngle(h, route[target] - p)
        val walk = "walk ${say.distance(legLength(p))}"
        if (prefix != null) {
            // "Turn right now" already says which way; stay "not aligned" for "Straight ahead" later.
            aligned = abs(rel) <= settings.alignDegrees
            return listOf(GuidanceEvent.Speak("$prefix. Then $walk.", true))
        }
        val sentence = if (abs(rel) > settings.misalignDegrees) {
            aligned = false
            "${headingPrompt(rel)}, then $walk"
        } else {
            "Walk straight ahead, ${say.distance(legLength(p))}"
        }
        val out = mutableListOf<GuidanceEvent>()
        if (!aligned) out += GuidanceEvent.Haptic(if (rel > 0) HapticCue.TURN_LEFT else HapticCue.TURN_RIGHT)
        out += GuidanceEvent.Speak("$sentence.", false)
        return out
    }

    private fun reachedTarget(p: Vec2): Boolean {
        if (!sameFloor(currentHeight, routeHeights[target])) return false
        if (p.distanceTo(route[target]) <= settings.waypointRadius) return true
        val (point, t) = closestPointOnSegment(p, route[target - 1], route[target])
        val next = distanceToSegment(p, route[target], route[target + 1])
        return t >= 0.95 && next < p.distanceTo(point)
    }

    fun distanceToRemainingRoute(p: Vec2): Double =
        (target - 1 until route.size - 1).minOfOrNull { distanceToSegment(p, route[it], route[it + 1]) }
            ?: Double.POSITIVE_INFINITY
}

/** Douglas-Peucker: drop points within [tolerance] m of a straight line through their neighbours. */
fun simplifyRoute(pts: List<Vec2>, tolerance: Double): List<Vec2> {
    if (pts.size <= 2) return pts
    val keep = BooleanArray(pts.size).also { it[0] = true; it[pts.size - 1] = true }
    val stack = ArrayDeque(listOf(0 to pts.size - 1))
    while (stack.isNotEmpty()) {
        val (a, b) = stack.removeLast()
        if (b <= a + 1) continue
        var worstIndex = a
        var worst = 0.0
        for (i in a + 1 until b) {
            val d = distanceToSegment(pts[i], pts[a], pts[b])
            if (d > worst) { worst = d; worstIndex = i }
        }
        if (worst > tolerance) {
            keep[worstIndex] = true
            stack.addLast(a to worstIndex)
            stack.addLast(worstIndex to b)
        }
    }
    return pts.filterIndexed { i, _ -> keep[i] }
}

/** Merge legs shorter than [minLength] into their neighbours, keeping both ends. */
fun removeShortLegs(pts: List<Vec2>, minLength: Double): List<Vec2> {
    val p = pts.toMutableList()
    var changed = true
    while (changed && p.size > 2) {
        changed = false
        for (i in 0 until p.size - 1) {
            if (p[i].distanceTo(p[i + 1]) >= minLength) continue
            when {
                i + 1 < p.size - 1 -> p.removeAt(i + 1)
                i > 0 -> p.removeAt(i)
                else -> continue
            }
            changed = true
            break
        }
    }
    return p
}

/** A flight of stairs (or a single step) found from the heights recorded along a route. */
data class StairFlight(val start: Vec2, val end: Vec2, /** positive = up, meters */ val rise: Double) {
    val goingUp get() = rise > 0
    /** A typical stair riser is about 17 cm. */
    val steps: Int get() = max(1, (abs(rise) / 0.17).roundHalfAway().toInt())
    val description: String
        get() = if (steps == 1) "a step ${if (goingUp) "up" else "down"}"
                else "stairs going ${if (goingUp) "up" else "down"}, about $steps steps"
}

/** Stretches where height changes by more than 30 cm per meter walked are stairs. */
fun findStairs(route: List<Vec2>, heights: List<Double?>): List<StairFlight> {
    if (route.size != heights.size || route.size < 2) return emptyList()
    val flights = mutableListOf<StairFlight>()
    var start = -1
    var end = -1
    var rise = 0.0
    fun close() {
        if (start >= 0 && abs(rise) >= 0.12) flights += StairFlight(route[start], route[end], rise)
        start = -1
        rise = 0.0
    }
    for (i in 0 until route.size - 1) {
        val h0 = heights[i]
        val h1 = heights[i + 1]
        if (h0 == null || h1 == null) { close(); continue }
        val dh = h1 - h0
        val d = route[i].distanceTo(route[i + 1])
        val steep = abs(dh) >= 0.08 && abs(dh) / max(d, 0.05) >= 0.3
        when {
            steep && start >= 0 && (rise > 0) == (dh > 0) -> { end = i + 1; rise += dh }
            steep -> { close(); start = i; end = i + 1; rise = dh }
            else -> close()
        }
    }
    close()
    return flights
}
