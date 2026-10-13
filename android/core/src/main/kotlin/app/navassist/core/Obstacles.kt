package app.navassist.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/** Left / center / right, as seen by someone holding the phone in front of their chest. */
enum class Zone { LEFT, CENTER, RIGHT }

/** One 3-D point in front of the user, relative to where they face. */
data class ObstaclePoint(
    /** Meters to the right (negative = left). */
    val lateral: Double,
    /** Meters ahead. */
    val forward: Double,
    /** Meters above the floor. */
    val height: Double,
)

/** Per zone, how dangerous it looks (1.0 or more = blocked), and real distances when known. */
data class ZoneReading(
    val danger: List<Double>,
    val meters: List<Double?> = listOf(null, null, null),
    /** Something is so close in front that the user should stop right away. */
    val immediateStop: Boolean = false,
    /** Doors and stairs recognised in the same frame. */
    val hints: SceneHints = SceneHints(),
)

/** Real 3-D points (LiDAR / ARCore depth / converted neural depth): obstacles by position and size. */
data class MetricZoneAnalyzer(
    val bodyHalfWidth: Double = 0.3,     // the walking corridor ("ahead") is 60 cm wide
    val sideReach: Double = 1.0,
    val warnDistance: Double = 1.5,      // obstacles ahead closer than this are reported
    val sideWarnDistance: Double = 0.7,  // beside the path, only when about to brush past
    val stopDistance: Double = 0.6,
    val maxRange: Double = 4.0,
    val minHeight: Double = 0.12,        // ignore the floor
    val maxHeight: Double = 2.0,         // ignore the ceiling; keeps head-height obstacles
    val minPoints: Int = 12,
) {
    fun analyze(points: List<ObstaclePoint>): ZoneReading {
        val buckets = List(3) { mutableListOf<Double>() }
        for (p in points) {
            if (p.forward <= 0.15 || p.forward >= maxRange || p.height < minHeight || p.height > maxHeight) continue
            val zone = when {
                abs(p.lateral) <= bodyHalfWidth -> Zone.CENTER
                p.lateral < 0 && p.lateral >= -sideReach -> Zone.LEFT
                p.lateral > 0 && p.lateral <= sideReach -> Zone.RIGHT
                else -> continue
            }
            buckets[zone.ordinal] += p.forward
        }
        val danger = MutableList(3) { 0.0 }
        val meters = MutableList<Double?>(3) { null }
        for (z in 0 until 3) {
            if (buckets[z].size < minPoints) continue
            val near = percentile(buckets[z], 0.05)
            meters[z] = near
            val limit = if (z == Zone.CENTER.ordinal) warnDistance else sideWarnDistance
            danger[z] = limit / max(near, 0.05)
        }
        val stop = (meters[Zone.CENTER.ordinal] ?: Double.POSITIVE_INFINITY) < stopDistance
        return ZoneReading(danger, meters, stop)
    }
}

/**
 * Relative depth only (bigger = closer, no units): the floor just in front of the user is
 * the ruler, and a zone that looks much closer than that floor is blocked.
 */
class RelativeDepthZoneAnalyzer(var warnRatio: Double = 1.5, var maxAtFeetFrames: Int = 10) {
    private val floorRows = 0.85 to 1.00
    private val floorCols = 0.30 to 0.70
    private val zoneRows = 0.15 to 0.75
    private var floorRef: Double? = null
    private var lastTime: Double? = null
    private var atFeetFrames = 0

    /**
     * [depth] is row-major, width x height, upright, bigger = closer. Pass [time] (seconds) when
     * frames can be far apart: a ruler older than 1 s is dropped. "At your feet" persisting for
     * more than [maxAtFeetFrames] frames re-seeds the ruler instead of saying stop forever.
     */
    fun analyze(depth: FloatArray, width: Int, height: Int, time: Double? = null): ZoneReading {
        if (width <= 0 || height <= 0 || depth.size != width * height) return ZoneReading(listOf(0.0, 0.0, 0.0))
        if (time != null) {
            val last = lastTime
            if (last != null && time - last > 1.0) { floorRef = null; atFeetFrames = 0 }
            lastTime = time
        }
        val floorNow = max(median(region(depth, width, height, floorRows, floorCols)), 1e-6)
        val previous = floorRef
        floorRef = when {
            previous == null -> floorNow
            floorNow < 1.5 * previous -> { atFeetFrames = 0; 0.9 * previous + 0.1 * floorNow }
            ++atFeetFrames > maxAtFeetFrames -> { atFeetFrames = 0; floorNow }
            else -> previous
        }
        val ref = floorRef!!
        val danger = (0 until 3).map { z ->
            val near = percentile(region(depth, width, height, zoneRows, z / 3.0 to (z + 1) / 3.0), 0.90)
            near / ref / warnRatio
        }.toMutableList()
        val atFeet = floorNow >= 1.5 * ref
        if (atFeet) danger[Zone.CENTER.ordinal] = max(danger[Zone.CENTER.ordinal], 1.5)
        return ZoneReading(danger, immediateStop = atFeet)
    }

    private fun region(d: FloatArray, w: Int, h: Int, rows: Pair<Double, Double>, cols: Pair<Double, Double>): List<Double> {
        val y0 = (rows.first * h).toInt()
        val y1 = max((rows.second * h).toInt(), y0 + 1)
        val x0 = (cols.first * w).toInt()
        val x1 = max((cols.second * w).toInt(), x0 + 1)
        val out = ArrayList<Double>((y1 - y0) * (x1 - x0))
        for (y in y0 until min(y1, h)) for (x in x0 until min(x1, w)) out += d[y * w + x].toDouble()
        return out
    }
}

/** Rotate a row-major image 90 degrees clockwise. Returns (data, newWidth, newHeight). */
fun rotateClockwise(d: FloatArray, width: Int, height: Int): Triple<FloatArray, Int, Int> {
    val out = FloatArray(width * height)
    for (y2 in 0 until width) for (x2 in 0 until height) out[y2 * height + x2] = d[(height - 1 - x2) * width + y2]
    return Triple(out, height, width)
}

/**
 * Decides when to speak obstacle, door and stair warnings: smoothing, a delay before a zone
 * counts as blocked or clear, a gap between thresholds so it doesn't flicker, and repeats only
 * every few seconds. Stairs come first.
 */
class ObstacleAnnouncer(var phrasing: Phrasing = Phrasing()) {
    private val smoothing = 0.4
    private val blockSeconds = 0.4
    private val clearSeconds = 1.0
    private val clearRatio = 0.85
    private val stableSeconds = 0.6
    private val pathClearSeconds = 2.0
    private val repeatSeconds = 4.0
    private val sideMargin = 0.15

    val blocked = booleanArrayOf(false, false, false)
    private var smooth: List<Double>? = null
    private val changingSince = arrayOfNulls<Double>(3)
    private var side: String? = null
    private var spoken: String? = null
    private var lastSaid = Double.NEGATIVE_INFINITY
    private var pending: String? = null
    private var pendingSince = 0.0
    private var clearSince: Double? = null
    private var stopSaidAt = Double.NEGATIVE_INFINITY
    private var stairsSaidAt = Double.NEGATIVE_INFINITY
    private var stairsSeenSince: Double? = null
    private var stairsInViewSaidAt = Double.NEGATIVE_INFINITY
    private var lastHints = SceneHints()

    fun update(r: ZoneReading, time: Double): List<GuidanceEvent> {
        val t = time
        lastHints = r.hints
        val stairs = r.hints.stairs
        if (stairs != null) {
            if (stairsSeenSince == null) stairsSeenSince = t
            if (t - stairsSeenSince!! >= 0.15 && t - stairsSaidAt >= 6) {
                stairsSaidAt = t
                val what = if (stairs.direction == StairCue.Direction.DOWN) "Stairs or a drop going down" else "Steps going up"
                return listOf(GuidanceEvent.Haptic(HapticCue.STOP), GuidanceEvent.Speak(
                    "Careful. $what, ${phrasing.distance(stairs.distance)} ahead. Stop and find the handrail.", true))
            }
        } else {
            stairsSeenSince = null
        }
        if (r.hints.stairsInView && t - stairsInViewSaidAt >= 15 && t - stairsSaidAt >= 6) {
            stairsInViewSaidAt = t
            val msg = r.hints.stairsAhead?.let { "Stairs ahead, ${phrasing.distance(it)}. Slow down." } ?: "Stairs may be ahead. Slow down."
            return listOf(GuidanceEvent.Haptic(HapticCue.OBSTACLE), GuidanceEvent.Speak(msg, false))
        }
        if (r.immediateStop) {
            if (t - stopSaidAt >= 2) {
                stopSaidAt = t
                spoken = "stop"
                lastSaid = t
                return listOf(GuidanceEvent.Haptic(HapticCue.STOP), GuidanceEvent.Speak("Stop. Obstacle right in front.", true))
            }
            return emptyList()
        }

        val s = smooth?.zip(r.danger) { old, new -> (1 - smoothing) * old + smoothing * new } ?: r.danger
        smooth = s

        for (k in 0 until 3) {
            val wantsChange = if (blocked[k]) s[k] < clearRatio else s[k] >= 1.0
            val need = if (blocked[k]) clearSeconds else blockSeconds
            val since = changingSince[k]
            when {
                !wantsChange -> changingSince[k] = null
                since == null -> changingSince[k] = t
                t - since >= need -> { blocked[k] = !blocked[k]; changingSince[k] = null }
            }
        }

        side = if (blocked[1]) clearerSide(s) else null
        val msg = warningText(r.meters)
        if (msg != pending) {
            pending = msg
            pendingSince = t
        }
        val stable = t - pendingSince >= stableSeconds

        val out = mutableListOf<GuidanceEvent>()
        if (msg == null) {
            if (clearSince == null) clearSince = t
            if (spoken != null && t - clearSince!! >= pathClearSeconds) {
                out += GuidanceEvent.Speak("Path clear", false)
                spoken = null
            }
        } else {
            clearSince = null
            if (stable && (msg != spoken || t - lastSaid >= repeatSeconds)) {
                out += GuidanceEvent.Haptic(HapticCue.OBSTACLE)
                out += GuidanceEvent.Speak(msg, msg != spoken && blocked[1])
                spoken = msg
                lastSaid = t
            }
        }
        return out
    }

    private fun clearerSide(s: List<Double>): String {
        if (blocked[0] != blocked[2]) return if (blocked[0]) "right" else "left"
        val best = if (s[0] <= s[2]) "left" else "right"
        val prev = side
        if (prev != null && best != prev && abs(s[0] - s[2]) < sideMargin) return prev
        return best
    }

    private fun warningText(meters: List<Double?>): String? {
        val (l, c, r) = Triple(blocked[0], blocked[1], blocked[2])
        if (c) {
            val door = lastHints.doorAhead
            if (door != null && abs(door - (meters[1] ?: door)) < 0.8) {
                lastHints.handleSide?.let { return "Door ahead, ${phrasing.distance(door)}. Handle on the ${it.name.lowercase()}." }
                return "Door ahead, ${phrasing.distance(door)}. Reach forward for the handle."
            }
            var ahead = "Obstacle ahead"
            meters[1]?.let { ahead += ", ${phrasing.distance(it)}" }
            if (l && r) return "$ahead. Stop."
            return "$ahead, clearer on the ${side ?: "left"}"
        }
        return when {
            l && r -> "Obstacles on both sides"
            l -> "Obstacle on the left"
            r -> "Obstacle on the right"
            else -> null
        }
    }
}
