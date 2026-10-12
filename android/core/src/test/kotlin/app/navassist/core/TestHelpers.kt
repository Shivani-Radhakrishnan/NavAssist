package app.navassist.core

import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.random.Random

/** Walk a polyline in small steps, like someone recording a route. */
fun walk(rec: TrailRecorder, corners: List<Vec2>, step: Double = 0.1, wobble: Double = 0.0, rng: Random = Random(1)) {
    for ((a, b) in corners.zipWithNext()) {
        val n = max(1, (a.distanceTo(b) / step).toInt())
        for (i in 0..n) {
            val p = a + (b - a) * (i.toDouble() / n)
            val jitter = if (wobble == 0.0) Vec2.ZERO
                         else Vec2(rng.nextDouble(-wobble, wobble), rng.nextDouble(-wobble, wobble))
            rec.add(p + jitter)
        }
    }
}

/** Walk corners that each have a height. */
fun walk3D(rec: TrailRecorder, corners: List<Pair<Vec2, Double>>, step: Double = 0.1) {
    for ((a, b) in corners.zipWithNext()) {
        val n = max(1, (max(a.first.distanceTo(b.first), kotlin.math.abs(b.second - a.second)) / step).toInt())
        for (i in 0..n) {
            val f = i.toDouble() / n
            rec.add(a.first + (b.first - a.first) * f, a.second + (b.second - a.second) * f)
        }
    }
}

data class SimResult(val said: List<String>, val arrived: Boolean, val events: List<GuidanceEvent>)

/** A user who follows the guide exactly at [speed] m/s, turning instantly. */
fun simulate(guide: Guide, start: Vec2, speed: Double = 1.0, dt: Double = 0.1, maxSeconds: Double = 120.0): SimResult {
    var p = start
    var heading = Vec2(0.0, 1.0)
    val events = guide.start(p, heading, 0.0).toMutableList()
    var t = 0.0
    while (t < maxSeconds && !guide.finished) {
        t += dt
        val target = guide.route[guide.target]
        val dir = (target - p).normalized
        if (dir.length > 0) heading = dir
        p = p + heading * min(speed * dt, p.distanceTo(target))
        events += guide.update(p, heading, t)
    }
    return SimResult(speech(events), GuidanceEvent.Arrived in events, events)
}

fun speech(events: List<GuidanceEvent>) = events.filterIsInstance<GuidanceEvent.Speak>().map { it.text }

fun rotate(h: Vec2, degrees: Double): Vec2 {
    val r = degrees * Math.PI / 180
    return Vec2(h.x * cos(r) - h.y * sin(r), h.x * sin(r) + h.y * cos(r))
}
