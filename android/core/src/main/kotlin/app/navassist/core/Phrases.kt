package app.navassist.core

import java.util.Locale
import kotlin.math.abs
import kotlin.math.max

/** How distances are spoken. */
enum class DistanceUnit { METERS, FEET, STEPS }

data class Phrasing(val unit: DistanceUnit = DistanceUnit.METERS, val stepLength: Double = 0.7) {
    fun distance(meters: Double): String = when (unit) {
        DistanceUnit.METERS -> {
            val v = if (meters < 10) (meters * 2).roundHalfAway() / 2 else meters.roundHalfAway()
            when {
                v <= 0.5 -> "half a meter"
                v == 1.0 -> "1 meter"
                v == v.roundHalfAway() -> "${v.toInt()} meters"
                else -> String.format(Locale.US, "%.1f meters", v)
            }
        }
        DistanceUnit.FEET -> {
            val f = max(1, (meters * 3.28084).roundHalfAway().toInt())
            if (f == 1) "1 foot" else "$f feet"
        }
        DistanceUnit.STEPS -> {
            val s = max(1, (meters / stepLength).roundHalfAway().toInt())
            if (s == 1) "1 step" else "$s steps"
        }
    }
}

/** Clock-face direction for a relative angle (positive = left). 12 is straight ahead. */
fun clockDirection(relativeDegrees: Double): Int {
    val hour = (12 - relativeDegrees / 30).roundHalfAway().toInt() % 12
    return if (hour <= 0) hour + 12 else hour
}

/** Words for a change of direction between two legs of a route (positive = left). */
fun turnWords(turnDegrees: Double): String {
    val side = if (turnDegrees > 0) "left" else "right"
    val t = abs(turnDegrees)
    return when {
        t < 20 -> "Continue straight"
        t < 45 -> "Bear slightly $side"
        t < 120 -> "Turn $side"
        t < 155 -> "Turn sharply $side"
        else -> "Turn around"
    }
}

/** "Turn to 3 o'clock" style prompt used when the user is facing the wrong way. */
fun headingPrompt(relativeDegrees: Double): String {
    val h = clockDirection(relativeDegrees)
    return if (h == 6) "Turn around" else "Turn to $h o'clock"
}
