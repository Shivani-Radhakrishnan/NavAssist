package app.navassist.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Regression tests for issues found in code review (mirrors ReviewFixTests.swift). */
class ReviewFixTest {
    private val nav = SpeechPriority.NAVIGATION
    private val safety = SpeechPriority.SAFETY
    private val info = SpeechPriority.INFO
    private fun speak(t: String) = SpeechArbiter.Action.Speak(t)
    private val none = SpeechArbiter.Action.None

    // Speech priorities

    @Test fun safetyInterruptsNavigationButNotTheOtherWayRound() {
        val a = SpeechArbiter()
        assertEquals(speak("Turn right now."), a.request("Turn right now.", nav, true, 0.0))
        assertEquals(SpeechArbiter.Action.Interrupt("Stop. Obstacle right in front."),
                     a.request("Stop. Obstacle right in front.", safety, true, 0.3))
        assertEquals(none, a.request("Turn left now.", nav, true, 0.5))
        assertEquals(speak("Turn right now."), a.finished(2.0))
    }

    @Test fun aSafetyMessageIsNotCutOffInItsFirstMoments() {
        val a = SpeechArbiter()
        a.request("Stop. Obstacle right in front.", safety, true, 0.0)
        assertEquals(none, a.request("Careful. Steps going up.", safety, true, 0.5))
        assertEquals(speak("Careful. Steps going up."), a.finished(1.6))
    }

    @Test fun oneShotDirectionsAreNotLostBehindInfo() {
        val a = SpeechArbiter()
        a.request("Sign: Exit", info, false, 0.0)
        assertEquals(SpeechArbiter.Action.Interrupt("In 2 meters, turn left."), a.request("In 2 meters, turn left.", nav, false, 0.2))
        a.request("Sign: Room 204", info, false, 0.3)
        assertEquals(speak("Sign: Exit"), a.finished(1.0))
        assertEquals(speak("Sign: Room 204"), a.finished(2.0))
        val b = SpeechArbiter()
        b.request("Walk straight ahead, 6 meters.", nav, false, 0.0)
        assertEquals(none, b.request("In 2 meters, turn left.", nav, false, 0.5))
        assertEquals(speak("In 2 meters, turn left."), b.finished(1.5))
    }

    @Test fun staleMessagesAreDropped() {
        val a = SpeechArbiter()
        a.request("Long sentence", nav, false, 0.0)
        a.request("Walk 3 meters, then turn left.", nav, false, 0.1)
        assertEquals(none, a.finished(10.0))
    }

    @Test fun nothingIsSpokenWhileTheUserIsTalking() {
        val a = SpeechArbiter()
        a.setListening(true, 0.0)
        assertEquals(none, a.request("Turn to 3 o'clock", nav, false, 0.5))
        assertEquals(none, a.request("Stairs now, going down.", safety, true, 1.0))
        assertEquals(speak("Stairs now, going down."), a.setListening(false, 2.0))
        assertEquals(speak("Turn to 3 o'clock"), a.finished(3.0))
    }

    @Test fun batchesWithStopOrObstacleVibrationAreSafety() {
        assertEquals(safety, listOf(GuidanceEvent.Haptic(HapticCue.STOP), GuidanceEvent.Speak("Stairs now, going down.", true)).impliedPriority)
        assertEquals(nav, listOf(GuidanceEvent.Haptic(HapticCue.TURN_RIGHT), GuidanceEvent.Speak("Turn right now.", true)).impliedPriority)
    }

    // Floors

    @Test fun aDestinationDirectlyAboveIsNotArrivedOnTheWrongFloor() {
        val route = listOf(Vec2(0.0, 0.0), Vec2(0.0, 4.0), Vec2(0.0, 8.0), Vec2(0.2, 0.2))
        val g = Guide(route, listOf(0.0, 0.0, 3.0, 3.0), "Bedroom")
        g.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0)
        val ev = g.update(Vec2(0.1, 0.1), Vec2(0.0, 1.0), 0.1, height = 0.0)
        assertFalse(GuidanceEvent.Arrived in ev)
        assertFalse(g.finished)
        val up = g.update(Vec2(0.1, 0.1), Vec2(0.0, 1.0), 30.0, height = 3.0)
        assertTrue(GuidanceEvent.Arrived in up || g.target > 1)
    }

    @Test fun pauseForgetsTheOffRouteTimer() {
        val g = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)), destinationName = "Door")
        g.start(Vec2.ZERO, Vec2(0.0, 1.0), 0.0)
        g.update(Vec2(3.0, 2.0), Vec2(0.0, 1.0), 1.0)
        g.pause()
        val ev = g.update(Vec2(3.0, 2.0), Vec2(0.0, 1.0), 9.0)
        assertFalse(GuidanceEvent.OffRoute in ev, "the first pose after a gap must not count as 8 s off route")
    }

    // Routing from where the user is

    @Test fun aStrayFragmentDoesNotBlockTheRoute() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)))
        val goal = rec.markLandmark("Door", Vec2(0.0, 10.0))
        rec.breakTrail()
        walk(rec, listOf(Vec2(1.2, 5.0), Vec2(1.25, 5.3)))
        val here = Vec2(1.0, 5.0)
        assertNull(rec.graph.shortestPath(rec.graph.nearestNode(here)!!, goal), "nearest node is the fragment")
        assertNotNull(rec.graph.route(here, to = goal), "but a connected node 1 m further works")
    }

    @Test fun theRecentWindowStaysSmallSoLoopsStillClose() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 6.0)))
        for (i in 0 until 40) rec.markSign("Sign $i", Vec2(i * 0.01 + 5, 6.0), dedupeRadius = 0.0)
        walk(rec, listOf(Vec2(0.0, 6.0), Vec2(3.0, 6.0), Vec2(3.0, 0.0), Vec2(0.0, 0.0)))
        val start = rec.graph.nearestNode(Vec2(0.0, 0.0))!!
        assertTrue(rec.graph.neighbours[start].orEmpty().size >= 2, "the loop should close at the start")
    }

    @Test fun signsSeenFromAfarAttachToTheirPlaceOnTheMapOnly() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 12.0)))
        val before = rec.graph.nodes.size
        val id = rec.markSign("EXIT", Vec2(0.4, 10.0), attachWithin = 2.0)
        assertNotNull(id)
        assertTrue(rec.graph.node(id).position.distanceTo(Vec2(0.0, 10.0)) < 0.6)
        assertEquals(before, rec.graph.nodes.size, "no new path invented")
        assertNull(rec.markSign("Lab", Vec2(8.0, 5.0), attachWithin = 2.0))
    }

    // Relative-depth fallback

    @Test fun theFallbackDoesNotLockIntoStop() {
        val w = 30; val h = 30
        val a = RelativeDepthZoneAnalyzer()
        a.analyze(FloatArray(w * h) { 0.2f }, w, h)
        var stops = 0
        repeat(300) { if (a.analyze(FloatArray(w * h) { 0.5f }, w, h).immediateStop) stops++ }
        assertTrue(stops <= 12, "re-seeds after a short while instead of saying stop forever (got $stops)")
    }

    @Test fun aStaleRulerIsDropped() {
        val w = 30; val h = 30
        val a = RelativeDepthZoneAnalyzer()
        a.analyze(FloatArray(w * h) { 0.2f }, w, h, time = 0.0)
        assertFalse(a.analyze(FloatArray(w * h) { 0.5f }, w, h, time = 60.0).immediateStop)
    }

    // Voice

    @Test fun savingWithoutANameAsksForOne() {
        assertEquals(VoiceCommand.SaveWithoutName, VoiceCommand.parse("save this place as"))
        assertEquals(VoiceCommand.SaveWithoutName, VoiceCommand.parse("save this place as here"))
        assertEquals(VoiceCommand.SaveWithoutName, VoiceCommand.parse("record location"))
        assertEquals(VoiceCommand.Save("kitchen"), VoiceCommand.parse("save this place as kitchen"))
    }

    @Test fun stopIsUnderstoodHoweverItIsSaid() {
        for (s in listOf("stop", "Stop stop", "stop guiding", "stop the route", "cancel navigation", "cancel it")) {
            assertEquals(VoiceCommand.Stop, VoiceCommand.parse(s), s)
        }
        assertNotEquals(VoiceCommand.Stop, VoiceCommand.parse("stop at the kitchen on the way"))
    }

    @Test fun partOfANameIsEnough() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)))
        rec.markSign("Emergency Exit", Vec2(0.0, 9.0))
        assertEquals("Emergency Exit", PlaceMatcher.best("exit", rec.graph)?.signText)
        assertEquals(0.0, PlaceMatcher.score("room 205", "Room 204"), "numbers still have to match")
    }

    // Trip logs

    @Test fun replanningStartsAFreshRouteInTheLog() {
        val rec = TripRecorder("P1, test", "Door", adaptive = false, routeLength = 10.0)
        val g = Guide(listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)), destinationName = "Door")
        rec.record(NavSample.make(g, Vec2.ZERO, Vec2(0.0, 1.0), 0.0, 0.0))
        rec.newRoute()
        rec.record(NavSample.make(g, Vec2(0.0, 1.0), Vec2(0.0, 1.0), 0.0, 0.1))
        assertEquals(listOf(0, 1), rec.log.samples.map { it.route })
        assertTrue(",P1  test," in rec.log.csv(), "commas in names can't break the CSV columns")
    }
}
