package app.navassist.core

import java.util.Locale
import java.util.UUID
import kotlin.math.abs
import kotlin.math.atan2
import kotlin.math.exp
import kotlin.math.max
import kotlin.math.min

/** One snapshot of the walker during a guided trip (10 Hz). */
data class NavSample(
    val t: Double,
    val x: Double,
    val y: Double,
    val height: Double,
    /** Facing direction in degrees (0 = +x, 90 = forward/+y). */
    val heading: Double,
    val target: Int,
    val distToTarget: Double,
    val distToDestination: Double,
    val distToRoute: Double,
    /** Angle from facing direction to the target point (positive = left). */
    val relToTarget: Double,
    /** Turn to make at the target point (positive = left); 0 if none. */
    val upcomingTurn: Double,
    /** Angle from facing direction to the direction of the next leg. */
    val relToNextLeg: Double,
    /** Sideways offset from the current leg, positive toward the side of the upcoming turn. */
    val lateralTowardTurn: Double,
) {
    companion object {
        fun make(guide: Guide, position: Vec2, heading: Vec2, height: Double, time: Double): NavSample {
            val r = guide.route
            val ti = min(guide.target, r.size - 1)
            val a = r[max(ti - 1, 0)]
            val b = r[ti]
            val turn = guide.upcomingTurn
            val nextDir = if (ti + 1 < r.size) r[ti + 1] - r[ti] else b - a
            val leg = (b - a).normalized
            val side = if (leg.length > 0) leg.cross(position - a) else 0.0
            val towardTurn = if (turn == 0.0) 0.0 else if (turn > 0) side else -side
            return NavSample(
                t = time, x = position.x, y = position.y, height = height,
                heading = atan2(heading.y, heading.x) * 180 / Math.PI,
                target = ti,
                distToTarget = position.distanceTo(b),
                distToDestination = guide.remainingDistance(position),
                distToRoute = guide.distanceToRemainingRoute(position),
                relToTarget = signedAngle(heading, b - position),
                upcomingTurn = turn,
                relToNextLeg = signedAngle(heading, nextDir),
                lateralTowardTurn = towardTurn,
            )
        }
    }
}

/** Features describing the last few seconds of walking, roughly in 0..1. */
data class BehaviorFeatures(val values: List<Double>) {
    companion object {
        val names = listOf("speed", "speedDrop", "headingRate", "oscillation", "nearCorner", "turningTowardNextLeg", "lateralTowardTurn")
    }
}

class FeatureExtractor {
    private val history = mutableListOf<NavSample>()

    fun reset() = history.clear()

    /** Add a sample; returns features once there are at least 1.5 s of history. */
    fun add(s: NavSample): BehaviorFeatures? {
        history += s
        history.removeAll { s.t - it.t > 5.0 }
        val first = history.firstOrNull() ?: return null
        if (s.t - first.t < 1.5) return null
        return BehaviorFeatures(listOf(
            min(speed(1.0) / 1.2, 1.5),
            speedDrop(),
            min(headingRate(1.0) / 90, 2.0),
            oscillation(2.0),
            nearCorner(s),
            turningTowardNextLeg(s),
            max(-1.0, min(s.lateralTowardTurn / 1.0, 1.5)),
        ))
    }

    private fun window(seconds: Double): List<NavSample> {
        val last = history.lastOrNull() ?: return emptyList()
        return history.filter { last.t - it.t <= seconds }
    }

    /** Speed from net distance moved (step-length sums would turn tracking jitter into fake speed). */
    internal fun speed(seconds: Double): Double {
        val w = window(seconds)
        val a = w.firstOrNull() ?: return 0.0
        val b = w.last()
        if (b.t <= a.t) return 0.0
        return Vec2(a.x, a.y).distanceTo(Vec2(b.x, b.y)) / (b.t - a.t)
    }

    private fun speedDrop(): Double {
        val recent = speed(1.0)
        val usual = max(speed(5.0), 0.3)
        return (1 - recent / usual).coerceIn(0.0, 1.0)
    }

    private fun totalTurning(w: List<NavSample>) = w.zipWithNext { p, q -> abs(wrapDegrees(q.heading - p.heading)) }.sum()

    private fun headingRate(seconds: Double): Double {
        val w = window(seconds)
        val a = w.firstOrNull() ?: return 0.0
        val b = w.last()
        if (b.t <= a.t) return 0.0
        return totalTurning(w) / (b.t - a.t)
    }

    private fun oscillation(seconds: Double): Double {
        val w = window(seconds)
        val a = w.firstOrNull() ?: return 0.0
        val b = w.last()
        return min((totalTurning(w) - abs(wrapDegrees(b.heading - a.heading))) / 90, 2.0)
    }

    private fun nearCorner(s: NavSample) = if (abs(s.upcomingTurn) >= 20) exp(-s.distToTarget / 2) else 0.0

    private fun turningTowardNextLeg(s: NavSample): Double {
        if (abs(s.upcomingTurn) < 20 || s.distToTarget <= 1.2) return 0.0
        val past = window(1.0).firstOrNull() ?: return 0.0
        if (past.target != s.target) return 0.0
        val closing = abs(past.relToNextLeg) - abs(s.relToNextLeg)
        val leaving = abs(s.relToTarget) - abs(past.relToTarget)
        return ((closing + leaving) / 60).coerceIn(0.0, 1.5)
    }
}

/** Logistic regression: p = sigmoid(w . x + b). Small, explainable, and trainable from logs. */
data class LogisticModel(var weights: List<Double>, var bias: Double) {
    fun probability(x: List<Double>): Double {
        val z = weights.zip(x).fold(bias) { acc, (w, v) -> acc + w * v }
        return 1 / (1 + exp(-z))
    }

    /** Class-weighted batch gradient descent with L2 regularisation (same as the iOS version). */
    fun train(xs: List<List<Double>>, ys: List<Boolean>, epochs: Int = 400, learningRate: Double = 0.5, l2: Double = 0.001) {
        if (xs.isEmpty() || xs.size != ys.size) return
        val pos = ys.count { it }.toDouble()
        val neg = ys.size - pos
        val wPos = if (pos > 0) ys.size / (2 * pos) else 1.0
        val wNeg = if (neg > 0) ys.size / (2 * neg) else 1.0
        val w = weights.toDoubleArray()
        repeat(epochs) {
            val gw = DoubleArray(w.size)
            var gb = 0.0
            for ((x, y) in xs.zip(ys)) {
                var z = bias
                for (j in w.indices) z += w[j] * x[j]
                val err = (1 / (1 + exp(-z)) - if (y) 1.0 else 0.0) * if (y) wPos else wNeg
                for (j in w.indices) gw[j] += err * x[j]
                gb += err
            }
            val n = xs.size.toDouble()
            for (j in w.indices) w[j] -= learningRate * (gw[j] / n + l2 * w[j])
            bias -= learningRate * gb / n
        }
        weights = w.toList()
    }
}

/** Predicts hesitation and early turns. */
data class BehaviorPredictor(val hesitation: LogisticModel, val earlyTurn: LogisticModel) {
    fun predict(f: BehaviorFeatures): Pair<Double, Double> = hesitation.probability(f.values) to earlyTurn.probability(f.values)

    companion object {
        /** Hand-set starting weights (feature order: BehaviorFeatures.names); retrain on real logs. */
        fun defaults() = BehaviorPredictor(
            LogisticModel(listOf(-6.0, 3.0, 1.0, 2.5, 1.0, 0.0, 0.0), -1.0),
            LogisticModel(listOf(0.5, 0.0, 1.0, 0.0, -1.5, 4.0, 3.0), -3.0),
        )
    }
}

/** What the app says when the predictor expects trouble. */
class AdaptiveCoach(var threshold: Double = 0.6, var phrasing: Phrasing = Phrasing()) {
    private var lastHesitationCue = Double.NEGATIVE_INFINITY
    private val earlyCuesForTarget = mutableMapOf<Int, Int>()
    private var lastEarlyCue = Double.NEGATIVE_INFINITY

    fun update(s: NavSample, hesitation: Double, earlyTurn: Double): List<GuidanceEvent> {
        if (earlyTurn >= threshold && abs(s.upcomingTurn) >= 20 && s.distToTarget > 1.5 &&
            (earlyCuesForTarget[s.target] ?: 0) < 2 && s.t - lastEarlyCue >= 4) {
            earlyCuesForTarget[s.target] = (earlyCuesForTarget[s.target] ?: 0) + 1
            lastEarlyCue = s.t
            return listOf(GuidanceEvent.Haptic(HapticCue.ON_TRACK),
                          GuidanceEvent.Speak("Not yet. Keep straight for ${phrasing.distance(s.distToTarget)} more.", true))
        }
        if (hesitation >= threshold && s.distToDestination > 1.5 && s.t - lastHesitationCue >= 7) {
            lastHesitationCue = s.t
            val next = if (abs(s.upcomingTurn) >= 20) "${turnWords(s.upcomingTurn)} in ${phrasing.distance(s.distToTarget)}."
                       else "Keep going straight, ${phrasing.distance(s.distToTarget)}."
            val text = if (abs(s.relToTarget) > 35) "${headingPrompt(s.relToTarget)}. Then ${next.replaceFirstChar { it.lowercase() }}"
                       else "You're on track. $next"
            return listOf(GuidanceEvent.Speak(text, false))
        }
        return emptyList()
    }
}

enum class TripEventKind(val id: String) {
    HESITATION("hesitation"), EARLY_TURN("earlyTurn"), OFF_ROUTE("offRoute"), CUE("cue"), ARRIVED("arrived"), STOPPED("stopped")
}

data class TripEvent(val t: Double, val kind: TripEventKind, val detail: String = "")

/** Detects hesitations (stopped 2 s+) and early turns (0.6 m drift toward the next leg before the corner). */
class BehaviorDetector(private val stopSpeed: Double = 0.15, private val stopSeconds: Double = 2.0, private val earlyLateral: Double = 0.6) {
    private var slowSince: Double? = null
    private var stopCounted = false
    private val earlyCounted = mutableSetOf<Int>()
    private val recent = mutableListOf<NavSample>()

    fun add(s: NavSample): List<TripEvent> {
        recent += s
        recent.removeAll { s.t - it.t > 1.0 }
        val out = mutableListOf<TripEvent>()
        val span = recent.last().t - recent.first().t
        val moved = Vec2(recent.first().x, recent.first().y).distanceTo(Vec2(s.x, s.y))
        val speed = if (span > 0.5) moved / span else 1.0
        if (speed < stopSpeed && s.distToDestination > 1.5) {
            if (slowSince == null) slowSince = s.t
            val since = slowSince!!
            if (s.t - since >= stopSeconds && !stopCounted) {
                stopCounted = true
                out += TripEvent(since, TripEventKind.HESITATION, String.format(Locale.US, "%.1f m before target", s.distToTarget))
            }
        } else {
            slowSince = null
            stopCounted = false
        }
        if (abs(s.upcomingTurn) >= 30 && s.distToTarget > 1.5 && s.lateralTowardTurn >= earlyLateral && s.target !in earlyCounted) {
            earlyCounted += s.target
            out += TripEvent(s.t, TripEventKind.EARLY_TURN, String.format(Locale.US, "%.1f m before the corner", s.distToTarget))
        }
        return out
    }
}

/** Everything recorded about one guided trip. */
data class TripLog(
    val id: String,
    val participant: String,
    val destination: String,
    /** Were predictive cues on for this trip? */
    val adaptive: Boolean,
    val routeLength: Double,
    var outcome: Outcome,
    val samples: MutableList<NavSample> = mutableListOf(),
    val events: MutableList<TripEvent> = mutableListOf(),
) {
    enum class Outcome(val id: String) { ARRIVED("arrived"), STOPPED("stopped"), ABANDONED("abandoned") }

    val duration: Double get() = (samples.lastOrNull()?.t ?: 0.0) - (samples.firstOrNull()?.t ?: 0.0)
    fun count(k: TripEventKind) = events.count { it.kind == k }
    /** Navigation errors = going off route + turning early. */
    val errors: Int get() = count(TripEventKind.OFF_ROUTE) + count(TripEventKind.EARLY_TURN)

    /** One row per sample, the same columns as the iOS app, for analysis/analyze_trips.py. */
    fun csv(): String {
        val f = { v: Double -> String.format(Locale.US, "%.3f", v) }
        val featureCols = BehaviorFeatures.names.joinToString(",") { "f_$it" }
        val rows = mutableListOf("trip,participant,adaptive,destination,outcome,t,x,y,height,heading,target,dist_to_target," +
            "dist_to_destination,dist_to_route,rel_to_target,upcoming_turn,rel_to_next_leg,lateral_toward_turn,$featureCols,event")
        val t0 = samples.firstOrNull()?.t ?: 0.0
        val pending = ArrayDeque(events.sortedBy { it.t })
        val fx = FeatureExtractor()
        val blank = BehaviorFeatures.names.joinToString(",") { "" }
        val dest = destination.replace(",", " ")
        for (s in samples) {
            val feats = fx.add(s)?.values?.joinToString(",") { String.format(Locale.US, "%.4f", it) } ?: blank
            val ev = mutableListOf<String>()
            while (pending.isNotEmpty() && pending.first().t <= s.t) ev += pending.removeFirst().kind.id
            rows += listOf(id, participant, if (adaptive) "1" else "0", dest, outcome.id, f(s.t - t0), f(s.x), f(s.y), f(s.height),
                f(s.heading), "${s.target}", f(s.distToTarget), f(s.distToDestination), f(s.distToRoute), f(s.relToTarget),
                f(s.upcomingTurn), f(s.relToNextLeg), f(s.lateralTowardTurn), feats, ev.joinToString("|")).joinToString(",")
        }
        return rows.joinToString("\n") + "\n"
    }
}

/** Runs alongside a Guide: records samples, detects events, predicts and coaches. */
class TripRecorder(
    participant: String,
    destination: String,
    adaptive: Boolean,
    routeLength: Double,
    var predictor: BehaviorPredictor = BehaviorPredictor.defaults(),
    val coach: AdaptiveCoach = AdaptiveCoach(),
) {
    val log = TripLog(UUID.randomUUID().toString().uppercase(), participant, destination, adaptive, routeLength, TripLog.Outcome.ABANDONED)
    private val features = FeatureExtractor()
    private val detector = BehaviorDetector()
    var lastPrediction: Pair<Double, Double> = 0.0 to 0.0
        private set

    /** Record one sample. Returns the coach's cues (empty when cues are off). */
    fun record(s: NavSample): List<GuidanceEvent> {
        log.samples += s
        log.events += detector.add(s)
        val f = features.add(s) ?: return emptyList()
        lastPrediction = predictor.predict(f)
        if (!log.adaptive) return emptyList()
        val cues = coach.update(s, lastPrediction.first, lastPrediction.second)
        cues.filterIsInstance<GuidanceEvent.Speak>().forEach { log.events += TripEvent(s.t, TripEventKind.CUE, it.text) }
        return cues
    }

    fun note(kind: TripEventKind, at: Double, detail: String = "") {
        log.events += TripEvent(at, kind, detail)
    }

    fun finish(outcome: TripLog.Outcome): TripLog {
        log.outcome = outcome
        return log
    }
}
