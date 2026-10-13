package app.navassist.core

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow

/**
 * Converts a depth network's *relative* inverse depth to meters, from sparse points with known
 * depth (ARCore/ARKit feature points): network value = a * (1 / meters) + b.
 */
data class InverseDepthFit(val a: Double, val b: Double, val r2: Double, val pointsUsed: Int) {
    /** Meters for a network value; null beyond the fitted range (farther than 20 m). */
    fun meters(value: Double): Double? {
        val inv = (value - b) / a
        return if (inv > 1.0 / 20.0) 1 / inv else null
    }

    companion object {
        /** Robust least squares: fit, drop the worst 25%, refit (twice). Null if too few points or a poor fit. */
        fun fit(networkValues: List<Double>, meters: List<Double>, minPoints: Int = 12, minR2: Double = 0.5): InverseDepthFit? {
            var pairs = networkValues.zip(meters)
                .filter { (r, d) -> d > 0.2 && d < 15 && r.isFinite() }
                .map { (r, d) -> 1 / d to r }
            if (pairs.size < minPoints) return null
            fun solve(p: List<Pair<Double, Double>>): Pair<Double, Double>? {
                val n = p.size.toDouble()
                val sx = p.sumOf { it.first }
                val sy = p.sumOf { it.second }
                val sxx = p.sumOf { it.first * it.first }
                val sxy = p.sumOf { it.first * it.second }
                val den = n * sxx - sx * sx
                if (abs(den) <= 1e-12) return null
                val a = (n * sxy - sx * sy) / den
                return a to (sy - a * sx) / n
            }
            var (a, b) = solve(pairs) ?: return null
            repeat(2) {
                val (ca, cb) = a to b
                pairs = pairs.sortedBy { abs(it.second - (ca * it.first + cb)) }
                    .take(max(minPoints, (pairs.size * 0.75).toInt()))
                val s = solve(pairs) ?: return null
                a = s.first
                b = s.second
            }
            if (a <= 0) return null
            val mean = pairs.sumOf { it.second } / pairs.size
            val ssTot = pairs.sumOf { (it.second - mean).pow(2) }
            val ssRes = pairs.sumOf { (it.second - (a * it.first + b)).pow(2) }
            val r2 = if (ssTot > 0) 1 - ssRes / ssTot else 0.0
            if (r2 < minR2) return null
            return InverseDepthFit(a, b, r2, pairs.size)
        }
    }
}

data class StairCue(val direction: Direction, /** meters to the first step */ val distance: Double) {
    enum class Direction { UP, DOWN }
}

/**
 * Looks at the walking surface in the corridor in 25 cm slices: a drop of 15 cm or more is
 * stairs down / a drop-off; rises of step height over two slices are stairs up. A wall isn't
 * stairs up, because its lowest points are still at floor level.
 */
class StairDetector(
    private val corridorHalfWidth: Double = 0.45,
    private val sliceDepth: Double = 0.25,
    private val rangeStart: Double = 0.4,
    private val rangeEnd: Double = 3.5,
    private val minPointsPerSlice: Int = 6,
) {
    fun detect(points: List<ObstaclePoint>): StairCue? {
        val n = ((rangeEnd - rangeStart) / sliceDepth).toInt()
        val slices = List(n) { mutableListOf<Double>() }
        for (p in points) {
            if (abs(p.lateral) > corridorHalfWidth || p.forward < rangeStart || p.forward > rangeEnd) continue
            slices[min(((p.forward - rangeStart) / sliceDepth).toInt(), n - 1)] += p.height
        }
        val surface = slices.map { if (it.size >= minPointsPerSlice) percentile(it, 0.2) else null }
        fun distance(i: Int) = rangeStart + (i + 0.5) * sliceDepth

        val firstFlat = surface.indexOfFirst { it != null && abs(it) < 0.08 }
        if (firstFlat < 0) return null
        for (i in firstFlat + 1 until n) {
            val h = surface[i] ?: continue
            if (h <= -0.15) {
                val next = surface.drop(i + 1).firstOrNull { it != null }
                if (next == null || next <= -0.1) return StairCue(StairCue.Direction.DOWN, distance(i))
            }
            val h2 = surface.getOrNull(i + 1)
            if (h in 0.1..0.3 && h2 != null && h2 - h in 0.08..0.3) return StairCue(StairCue.Direction.UP, distance(i))
        }
        return null
    }
}

/** What the camera recognises about the scene beyond raw obstacles. */
data class SceneHints(
    /** Meters to a door in the walking direction, if one is seen. */
    val doorAhead: Double? = null,
    /** Which side of that door its handle is on, when the detector sees it. */
    val handleSide: Side? = null,
    val stairs: StairCue? = null,
    /** Stairs are in view (from the detector, or an image classifier as a fallback). */
    val stairsInView: Boolean = false,
    /** Meters to where those stairs start, when the detector located them and depth is known. */
    val stairsAhead: Double? = null,
)
