package app.navassist.core

import kotlin.math.abs
import kotlin.math.floor
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ObstacleSceneTest {
    private fun box(lat: ClosedFloatingPointRange<Double>, fwd: ClosedFloatingPointRange<Double>, h: ClosedFloatingPointRange<Double>,
                    step: Double = 0.04, hStep: Double = 0.05): List<ObstaclePoint> {
        val out = mutableListOf<ObstaclePoint>()
        var x = lat.start
        while (x <= lat.endInclusive + 1e-9) {
            var f = fwd.start
            while (f <= fwd.endInclusive + 1e-9) {
                var z = h.start
                while (z <= h.endInclusive + 1e-9) { out += ObstaclePoint(x, f, z); z += hStep }
                f += step
            }
            x += step
        }
        return out
    }

    private fun wall(at: Double, from: Double, to: Double, height: ClosedFloatingPointRange<Double> = 0.2..1.8) =
        box(from..to, at..at, height, step = 0.05, hStep = 0.1)

    private fun floorPoints(): List<ObstaclePoint> {
        val out = mutableListOf<ObstaclePoint>()
        var f = 0.3
        while (f < 4.0) {
            var x = -1.0
            while (x < 1.0) { out += ObstaclePoint(x, f, 0.01); x += 0.1 }
            f += 0.05
        }
        return out
    }

    private fun profile(heightAt: (Double) -> Double?): List<ObstaclePoint> {
        val out = mutableListOf<ObstaclePoint>()
        var f = 0.4
        while (f <= 3.5) {
            heightAt(f)?.let { h -> var x = -0.4; while (x <= 0.4 + 1e-9) { out += ObstaclePoint(x, f, h); x += 0.1 } }
            f += 0.05
        }
        return out
    }

    // --- obstacle zones ---

    @Test fun metricAnalyzerIgnoresTheFloor() {
        val r = MetricZoneAnalyzer().analyze(floorPoints())
        assertEquals(listOf(0.0, 0.0, 0.0), r.danger)
    }

    @Test fun metricAnalyzerFindsZonesAndDistances() {
        val r = MetricZoneAnalyzer().analyze(floorPoints() + wall(1.0, -0.2, 0.2) + wall(3.0, 0.5, 1.0))
        assertTrue(r.danger[1] >= 1.0)
        assertTrue(abs((r.meters[1] ?: 0.0) - 1.0) < 0.01)
        assertTrue(r.danger[2] < 1.0)
        assertNull(r.meters[0])
    }

    @Test fun stopWhenVeryClose() = assertTrue(MetricZoneAnalyzer().analyze(wall(0.4, -0.3, 0.3)).immediateStop)

    @Test fun headHeightObstaclesCount() =
        assertTrue(MetricZoneAnalyzer().analyze(wall(1.0, -0.2, 0.2, 1.5..1.8)).danger[1] >= 1.0)

    @Test fun aBasketBesideThePathIsNotAnObstacleAhead() {
        val r = MetricZoneAnalyzer().analyze(floorPoints() + box(0.45..0.8, 1.0..1.3, 0.12..0.4))
        assertTrue(r.danger[1] < 1)
        assertTrue(r.danger[2] < 1)
    }

    @Test fun theBasketIsMentionedWhenAboutToBrushPastIt() {
        val r = MetricZoneAnalyzer().analyze(box(0.4..0.75, 0.45..0.7, 0.12..0.4))
        assertTrue(r.danger[2] >= 1)
        assertTrue(r.danger[1] < 1)
    }

    // --- announcer ---

    @Test fun waitsForAStableWarning() {
        val a = ObstacleAnnouncer()
        val blocked = ZoneReading(listOf(0.0, 2.0, 0.0), listOf(null, 1.0, null))
        val said = mutableListOf<String>()
        var t = 0.0
        repeat(5) { t += 0.1; said += speech(a.update(blocked, t)) }
        assertTrue(said.isEmpty())
        repeat(20) { t += 0.1; said += speech(a.update(blocked, t)) }
        assertEquals(listOf("Obstacle ahead, 1 meter, clearer on the left"), said)
    }

    @Test fun doesNotFlickerAroundTheThreshold() {
        val a = ObstacleAnnouncer()
        var said = 0
        for (i in 0 until 100) said += speech(a.update(ZoneReading(listOf(0.0, if (i % 2 == 0) 1.05 else 0.95, 0.0)), i * 0.1)).size
        assertTrue(said <= 3)
    }

    @Test fun pathClearAfterwards() {
        val a = ObstacleAnnouncer()
        val said = mutableListOf<String>()
        var t = 0.0
        repeat(20) { t += 0.1; said += speech(a.update(ZoneReading(listOf(2.0, 0.0, 0.0)), t)) }
        repeat(50) { t += 0.1; said += speech(a.update(ZoneReading(listOf(0.0, 0.0, 0.0)), t)) }
        assertEquals(listOf("Obstacle on the left", "Path clear"), said)
    }

    @Test fun immediateStopIsNotDelayed() = assertContains(
        ObstacleAnnouncer().update(ZoneReading(listOf(0.0, 5.0, 0.0), immediateStop = true), 0.0),
        GuidanceEvent.Speak("Stop. Obstacle right in front.", true))

    @Test fun clearerSideFollowsTheOpenSide() {
        val a = ObstacleAnnouncer()
        val said = mutableListOf<String>()
        var t = 0.0
        repeat(20) { t += 0.1; said += speech(a.update(ZoneReading(listOf(1.6, 2.0, 0.2)), t)) }
        assertEquals("Obstacle ahead, clearer on the right", said.last())
    }

    @Test fun aClosedDoorIsCalledADoor() {
        val a = ObstacleAnnouncer()
        val r = ZoneReading(listOf(0.0, 2.0, 0.0), listOf(null, 1.2, null), hints = SceneHints(doorAhead = 1.3))
        val said = mutableListOf<String>()
        var t = 0.0
        repeat(20) { t += 0.1; said += speech(a.update(r, t)) }
        assertEquals(listOf("Door ahead, 1.5 meters. Reach forward for the handle."), said)
    }

    @Test fun stairsAreAnnouncedFirstAndUrgently() {
        val a = ObstacleAnnouncer()
        val r = ZoneReading(listOf(0.0, 2.0, 0.0), listOf(null, 1.0, null),
                            hints = SceneHints(stairs = StairCue(StairCue.Direction.DOWN, 1.6)))
        assertTrue(a.update(r, 0.0).isEmpty())
        val second = a.update(r, 0.2)
        assertContains(second, GuidanceEvent.Speak("Careful. Stairs or a drop going down, 1.5 meters ahead. Stop and find the handrail.", true))
    }

    // --- relative depth, rotation, metric fit, stairs ahead ---

    @Test fun rotationMakesTheLeftEdgeTheTop() {
        val (out, w, h) = rotateClockwise(floatArrayOf(1f, 2f, 3f, 4f, 5f, 6f), 3, 2)
        assertEquals(2 to 3, w to h)
        assertEquals(listOf(4f, 1f, 5f, 2f, 6f, 3f), out.toList())
    }

    @Test fun relativeAnalyzerUsesTheFloorAsARuler() {
        val w = 30
        val h = 30
        val d = FloatArray(w * h) { 1f }
        val a = RelativeDepthZoneAnalyzer()
        assertTrue(a.analyze(d, w, h).danger.all { it < 1 })
        for (y in 6 until 20) for (x in 22 until 30) d[y * w + x] = 2f
        val r = a.analyze(d, w, h)
        assertTrue(r.danger[2] >= 1 && r.danger[0] < 1 && r.danger[1] < 1)
    }

    @Test fun recoversMetersFromFeaturePoints() {
        val rng = Random(3)
        val r = mutableListOf<Double>()
        val d = mutableListOf<Double>()
        for (i in 0 until 120) {
            val m = 0.5 + (i % 40) * 0.1
            r += 2.0 / m + 0.3 + rng.nextDouble(-0.02, 0.02)
            d += m
        }
        repeat(15) { r += rng.nextDouble(0.0, 5.0); d += rng.nextDouble(0.5, 4.0) }
        val fit = assertNotNull(InverseDepthFit.fit(r, d))
        assertTrue(abs(fit.a - 2.0) < 0.15)
        assertTrue(abs((fit.meters(2.0 / 1.5 + 0.3) ?: 0.0) - 1.5) < 0.1)
    }

    @Test fun refusesToGuessFromBadData() {
        assertNull(InverseDepthFit.fit(listOf(1.0, 2.0, 3.0), listOf(1.0, 2.0, 3.0)))
        val m = (0 until 30).map { 0.5 + it * 0.1 }
        assertNull(InverseDepthFit.fit(m.map { it * 2 }, m))
    }

    @Test fun flatFloorHasNoStairs() = assertNull(StairDetector().detect(profile { 0.0 }))

    @Test fun findsStairsGoingDown() {
        val cue = StairDetector().detect(profile { f -> if (f < 1.5) 0.0 else -0.17 * (1 + floor((f - 1.5) / 0.28)) })
        assertEquals(StairCue.Direction.DOWN, cue?.direction)
        assertTrue(abs((cue?.distance ?: 0.0) - 1.6) < 0.3)
    }

    @Test fun findsStepsGoingUp() {
        val cue = StairDetector().detect(profile { f -> if (f < 1.2) 0.0 else 0.17 * (1 + floor((f - 1.2) / 0.28)) })
        assertEquals(StairCue.Direction.UP, cue?.direction)
        assertTrue(abs((cue?.distance ?: 0.0) - 1.3) < 0.3)
    }

    @Test fun aWallIsNotStairsUp() {
        val pts = profile { if (it < 2.0) 0.0 else null } + box(-0.5..0.5, 2.0..2.05, 0.0..2.0)
        assertNull(StairDetector().detect(pts))
    }
}
