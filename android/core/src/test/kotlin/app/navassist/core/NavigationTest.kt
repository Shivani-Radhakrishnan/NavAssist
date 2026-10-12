package app.navassist.core

import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class NavigationTest {
    @Test fun clockFaceDirections() {
        assertEquals(12, clockDirection(0.0))
        assertEquals(9, clockDirection(90.0))
        assertEquals(3, clockDirection(-90.0))
        assertEquals(6, clockDirection(180.0))
        assertEquals(1, clockDirection(-30.0))
        assertEquals(2, clockDirection(-60.0))
    }

    @Test fun turnWordsByAngle() {
        assertEquals("Continue straight", turnWords(5.0))
        assertEquals("Turn left", turnWords(90.0))
        assertEquals("Turn right", turnWords(-90.0))
        assertEquals("Bear slightly right", turnWords(-30.0))
        assertEquals("Turn around", turnWords(170.0))
    }

    @Test fun distancePhrasing() {
        assertEquals("1 meter", Phrasing(DistanceUnit.METERS).distance(1.1))
        assertEquals("2.5 meters", Phrasing(DistanceUnit.METERS).distance(2.7))
        assertEquals("12 meters", Phrasing(DistanceUnit.METERS).distance(12.4))
        assertEquals("5 steps", Phrasing(DistanceUnit.STEPS, 0.7).distance(3.5))
        assertEquals("3 feet", Phrasing(DistanceUnit.FEET).distance(1.0))
    }

    @Test fun signedAngleIsPositiveToTheLeft() {
        val forward = Vec2(0.0, 1.0)
        assertTrue(abs(signedAngle(forward, Vec2(-1.0, 0.0)) - 90) < 1e-9)
        assertTrue(abs(signedAngle(forward, Vec2(1.0, 0.0)) + 90) < 1e-9)
        assertEquals(Vec2(0.0, 1.0), Vec2.fromWorld(0f, -1f))
        assertEquals(Vec2(1.0, -0.0), Vec2.fromWorld(1f, 0f))
    }

    @Test fun recorderDropsNodesAtSpacing() {
        val rec = TrailRecorder(spacing = 0.5)
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 5.0)))
        assertEquals(11, rec.graph.nodes.size)
        assertEquals(11, rec.graph.shortestPath(0, 10)?.size)
    }

    @Test fun separateWalksJoinAtJunctions() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 8.0)))
        rec.markLandmark("North end", Vec2(0.0, 8.0))
        rec.breakTrail()
        walk(rec, listOf(Vec2(-4.0, 4.0), Vec2(4.0, 4.0)))
        rec.markLandmark("East room", Vec2(4.0, 4.0))
        val g = rec.graph
        val north = g.landmarks.first { it.landmark == "North end" }.id
        val east = g.landmarks.first { it.landmark == "East room" }.id
        val path = assertNotNull(g.shortestPath(north, east), "crossing walks should connect")
        val pts = g.positions(path)
        assertTrue(pts.zipWithNext { a, b -> a.distanceTo(b) }.sum() < 9.5)
    }

    @Test fun unconnectedPlacesHaveNoRoute() {
        val g = RouteGraph()
        val a = g.addNode(Vec2(0.0, 0.0))
        val b = g.addNode(Vec2(10.0, 0.0))
        assertNull(g.shortestPath(a, b))
    }

    @Test fun renamingALandmarkMovesIt() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 4.0)))
        rec.markLandmark("Desk", Vec2(0.0, 1.0))
        rec.markLandmark("Desk", Vec2(0.0, 4.0))
        val desks = rec.graph.nodes.filter { it.landmark == "Desk" }
        assertEquals(1, desks.size)
        assertTrue(desks[0].position.distanceTo(Vec2(0.0, 4.0)) < 0.3)
    }

    @Test fun simplifyRemovesWobble() {
        val pts = (0..20).map { Vec2(if (it % 2 == 0) 0.05 else -0.05, it * 0.5) }
        assertEquals(2, simplifyRoute(pts, 0.35).size)
    }

    @Test fun guidesAroundAnLShapedCorridor() {
        // Repeated with different wobble, like the Swift flakiness check.
        repeat(15) { seed ->
            val rec = TrailRecorder()
            walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 6.0), Vec2(4.0, 6.0)), wobble = 0.05, rng = Random(seed))
            val dest = rec.markLandmark("Kitchen", Vec2(4.0, 6.0))
            val guide = Guide(rec.graph.positions(rec.graph.shortestPath(0, dest)!!), destinationName = "Kitchen")
            assertEquals(3, guide.route.size, "wobble should be simplified to two legs (seed $seed)")
            val r = simulate(guide, Vec2(0.0, 0.0))
            assertTrue(r.arrived)
            assertTrue(r.said.first().startsWith("Route to Kitchen"))
            assertTrue(r.said.any { it.contains("turn right") }, "should warn of the upcoming turn")
            assertTrue(r.said.any { it.startsWith("Turn right now") })
            assertEquals("You have arrived at Kitchen.", r.said.last())
            assertFalse(r.said.any { it.contains("o'clock") })
        }
    }

    @Test fun correctsAUserFacingTheWrongWay() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 5.0)), destinationName = "Door")
        val events = guide.start(Vec2.ZERO, Vec2(1.0, 0.0), 0.0)
        assertContains(events, GuidanceEvent.Speak("Turn to 9 o'clock, then walk 5 meters.", false))
        assertContains(events, GuidanceEvent.Haptic(HapticCue.TURN_LEFT))
        val later = guide.update(Vec2(0.0, 0.1), Vec2(0.0, 1.0), 1.0)
        assertContains(later, GuidanceEvent.Speak("Straight ahead", false))
    }

    @Test fun headingCorrectionsAreRateLimited() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)), destinationName = "Door")
        guide.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0)
        var prompts = 0
        var t = 0.0
        while (t < 10) {
            t += 0.1
            prompts += speech(guide.update(Vec2(0.0, 0.5), Vec2(1.0, 0.0), t)).count { it.contains("o'clock") }
        }
        assertTrue(prompts in 2..3, "about one prompt every 4 seconds, got $prompts")
    }

    @Test fun detectsLeavingTheRoute() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)), destinationName = "Door")
        guide.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0)
        for (i in 1..10) guide.update(Vec2(2.0, 3.0), Vec2(0.0, 1.0), i * 0.1)
        guide.update(Vec2(0.0, 3.0), Vec2(0.0, 1.0), 1.2)
        assertFalse(guide.finished)
        val events = (0..30).flatMap { guide.update(Vec2(2.5, 4.0), Vec2(0.0, 1.0), 2 + it * 0.1) }
        assertContains(events, GuidanceEvent.OffRoute)
        assertTrue(guide.finished)
    }

    @Test fun walkingPastACornerStillAdvances() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 4.0), Vec2(4.0, 4.0)), destinationName = "Room")
        guide.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0)
        guide.update(Vec2(0.0, 2.8), Vec2(0.0, 1.0), 1.0)
        guide.update(Vec2(1.0, 3.9), Vec2(1.0, 0.0), 2.0)
        assertEquals(2, guide.target)
    }

    @Test fun statusSummarisesTheRoute() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 3.0), Vec2(-2.0, 3.0)), destinationName = "Bathroom")
        assertEquals("Bathroom is 5 meters away. Walk 3 meters, then turn left.", guide.status(Vec2.ZERO, Vec2(0.0, 1.0)))
    }

    @Test fun stepsUnitIsUsedEverywhere() {
        val guide = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 3.0)), destinationName = "Sofa",
                          settings = GuidanceSettings(phrasing = Phrasing(DistanceUnit.STEPS, 0.5)))
        assertEquals(GuidanceEvent.Speak("Route to Sofa, 6 steps.", true), guide.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0).first())
    }
}
