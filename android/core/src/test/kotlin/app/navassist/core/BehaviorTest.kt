package app.navassist.core

import kotlin.math.cos
import kotlin.math.sin
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BehaviorTest {
    sealed interface Style {
        data object Follows : Style
        data class TurnsEarly(val by: Double) : Style
        data class Hesitates(val at: Double, val seconds: Double) : Style
    }

    private val lRoute = listOf(Vec2(0.0, 0.0), Vec2(0.0, 8.0), Vec2(6.0, 8.0))

    data class Trip(val log: TripLog, val said: List<String>, val predictions: List<Triple<Double, Double, Double>>)

    /** A simulated walker at 1 m/s through the L-shaped route, as in the iOS tests. */
    private fun simulateTrip(style: Style, adaptive: Boolean, obeysCues: Boolean = false): Trip {
        val guide = Guide(lRoute, destinationName = "Door")
        val rec = TripRecorder("P0", "Door", adaptive, 14.0)
        var p = Vec2(0.0, 0.0)
        var h = Vec2(0.0, 1.0)
        val said = mutableListOf<String>()
        val preds = mutableListOf<Triple<Double, Double, Double>>()
        var t = 0.0
        var stoppedFor = 0.0
        var heldStraightUntil = -1.0
        guide.start(p, h, 0.0)
        while (t < 60 && !guide.finished) {
            t += 0.1
            var aim = guide.route[guide.target]
            when (style) {
                Style.Follows -> {}
                is Style.TurnsEarly ->
                    if (guide.target == 1 && p.distanceTo(lRoute[1]) < style.by && t > heldStraightUntil) aim = lRoute[2]
                is Style.Hesitates ->
                    if (guide.target == 1 && lRoute[1].y - p.y <= style.at && stoppedFor < style.seconds) {
                        stoppedFor += 0.1
                        val look = sin(stoppedFor * 3) * 60 * Math.PI / 180
                        h = Vec2(-sin(look), cos(look))
                        said += speech(rec.record(NavSample.make(guide, p, h, 0.0, t)))
                        preds += Triple(t, rec.lastPrediction.first, rec.lastPrediction.second)
                        continue
                    }
            }
            val want = signedAngle(h, (aim - p).normalized)
            h = rotate(h, want.coerceIn(-9.0, 9.0))
            p = p + h * 0.1
            val spoken = speech(rec.record(NavSample.make(guide, p, h, 0.0, t)))
            said += spoken
            if (obeysCues && spoken.any { it.startsWith("Not yet") }) heldStraightUntil = t + 3
            preds += Triple(t, rec.lastPrediction.first, rec.lastPrediction.second)
            for (e in guide.update(p, h, t)) {
                if (e == GuidanceEvent.OffRoute) rec.note(TripEventKind.OFF_ROUTE, t)
                if (e == GuidanceEvent.Arrived) rec.note(TripEventKind.ARRIVED, t)
            }
        }
        return Trip(rec.finish(if (guide.finished) TripLog.Outcome.ARRIVED else TripLog.Outcome.ABANDONED), said, preds)
    }

    @Test fun aWalkerWhoFollowsHasNoErrorsAndHearsNoCues() {
        val r = simulateTrip(Style.Follows, adaptive = true)
        assertEquals(0, r.log.errors)
        assertEquals(0, r.log.count(TripEventKind.HESITATION))
        assertTrue(r.said.isEmpty(), "said: ${r.said}")
        assertTrue(r.predictions.all { it.second < 0.6 && it.third < 0.6 })
    }

    @Test fun detectsAnEarlyTurn() {
        val r = simulateTrip(Style.TurnsEarly(4.0), adaptive = false)
        assertEquals(1, r.log.count(TripEventKind.EARLY_TURN))
    }

    @Test fun predictsTheEarlyTurnBeforeItHappens() {
        val r = simulateTrip(Style.TurnsEarly(4.0), adaptive = false)
        val happened = r.log.events.first { it.kind == TripEventKind.EARLY_TURN }.t
        val predicted = r.predictions.first { it.third >= 0.6 }.first
        assertTrue(predicted < happened, "predicted at $predicted, happened at $happened")
    }

    @Test fun coachHoldsAnEarlyTurnerOnTheLeg() {
        val r = simulateTrip(Style.TurnsEarly(4.0), adaptive = true)
        assertTrue(r.said.any { it.startsWith("Not yet. Keep straight for") }, "said: ${r.said}")
    }

    @Test fun cuesReduceErrorsWhenTheWalkerListens() {
        val without = simulateTrip(Style.TurnsEarly(4.0), adaptive = false)
        val with = simulateTrip(Style.TurnsEarly(4.0), adaptive = true, obeysCues = true)
        assertTrue(with.log.errors < without.log.errors)
    }

    @Test fun detectsAndPredictsHesitation() {
        val r = simulateTrip(Style.Hesitates(2.5, 3.5), adaptive = true)
        assertEquals(1, r.log.count(TripEventKind.HESITATION))
        assertTrue(r.predictions.any { it.second >= 0.6 })
        assertTrue(r.said.any { it.startsWith("You're on track") || it.contains("o'clock") }, "said: ${r.said}")
    }

    @Test fun adaptiveOffMeansSilentButStillMeasured() {
        val r = simulateTrip(Style.Hesitates(2.5, 3.5), adaptive = false)
        assertTrue(r.said.isEmpty())
        assertEquals(1, r.log.count(TripEventKind.HESITATION))
    }

    @Test fun logisticModelLearnsASeparableRule() {
        val xs = (0 until 200).map { listOf(it / 200.0, (it % 7) / 7.0) }
        val ys = (0 until 200).map { it / 200.0 > 0.5 }
        val m = LogisticModel(listOf(0.0, 0.0), 0.0)
        m.train(xs, ys, epochs = 2000, learningRate = 2.0)
        assertTrue(m.probability(listOf(0.9, 0.3)) > 0.8)
        assertTrue(m.probability(listOf(0.1, 0.3)) < 0.2)
    }

    @Test fun tripLogExportsTheSameCsvColumnsAsIos() {
        val r = simulateTrip(Style.TurnsEarly(4.0), adaptive = true)
        val lines = r.log.csv().trimEnd().split("\n")
        assertTrue(lines.first().startsWith("trip,participant,adaptive,destination,outcome,t,"))
        assertTrue(lines.first().contains("f_speed"))
        assertEquals(r.log.samples.size + 1, lines.size)
        assertTrue(lines.any { it.endsWith("earlyTurn") || it.contains("earlyTurn|") || it.contains("|earlyTurn") })
    }
}
