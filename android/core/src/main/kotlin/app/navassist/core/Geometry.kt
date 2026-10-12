package app.navassist.core

import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.sqrt

/**
 * A point or direction on the floor, in meters, seen from above.
 *
 * ARCore (like ARKit) has y pointing up and the camera starting out looking along -z.
 * [fromWorld] maps that onto ordinary math axes: +x = right, +y = forward, so a positive
 * (counter-clockwise) angle always means LEFT.
 */
data class Vec2(val x: Double, val y: Double) {
    operator fun plus(o: Vec2) = Vec2(x + o.x, y + o.y)
    operator fun minus(o: Vec2) = Vec2(x - o.x, y - o.y)
    operator fun times(k: Double) = Vec2(x * k, y * k)

    fun dot(o: Vec2) = x * o.x + y * o.y

    /** Positive when [o] is counter-clockwise (to the left) of this. */
    fun cross(o: Vec2) = x * o.y - y * o.x
    val length: Double get() = sqrt(x * x + y * y)
    fun distanceTo(o: Vec2) = (this - o).length

    val normalized: Vec2
        get() {
            val l = length
            return if (l > 1e-9) Vec2(x / l, y / l) else ZERO
        }

    companion object {
        val ZERO = Vec2(0.0, 0.0)
        fun fromWorld(x: Float, z: Float) = Vec2(x.toDouble(), -z.toDouble())
    }
}

/** Swift's `rounded()`: halves round away from zero (Kotlin's `round` rounds halves to even). */
internal fun Double.roundHalfAway(): Double = if (this >= 0) floor(this + 0.5) else ceil(this - 0.5)

/** Wrap an angle in degrees to -180..180. */
fun wrapDegrees(a: Double): Double {
    var r = (a + 180) % 360
    if (r < 0) r += 360
    return r - 180
}

/** Signed angle in degrees from direction [from] to direction [to]. Positive = left. */
fun signedAngle(from: Vec2, to: Vec2): Double = atan2(from.cross(to), from.dot(to)) * 180 / Math.PI

/** Closest point on segment a-b to p, and how far along the segment it is (0..1). */
fun closestPointOnSegment(p: Vec2, a: Vec2, b: Vec2): Pair<Vec2, Double> {
    val ab = b - a
    val len2 = ab.dot(ab)
    if (len2 < 1e-12) return a to 0.0
    val t = ((p - a).dot(ab) / len2).coerceIn(0.0, 1.0)
    return (a + ab * t) to t
}

fun distanceToSegment(p: Vec2, a: Vec2, b: Vec2): Double = p.distanceTo(closestPointOnSegment(p, a, b).first)

internal fun percentile(values: List<Double>, q: Double): Double {
    if (values.isEmpty()) return 0.0
    val sorted = values.sorted()
    val i = ((sorted.size - 1) * q).roundHalfAway().toInt().coerceIn(0, sorted.size - 1)
    return sorted[i]
}

internal fun median(values: List<Double>) = percentile(values, 0.5)
