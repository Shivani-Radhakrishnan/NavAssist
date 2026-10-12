package app.navassist.core

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertContains
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class VoiceStairsTest {
    @Test fun parsesCommands() {
        val cases = listOf(
            "Save this place as kitchen" to VoiceCommand.Save("kitchen"),
            "record location kitchen" to VoiceCommand.Save("kitchen"),
            "Record location as the front door" to VoiceCommand.Save("front door"),
            "remember this as my desk" to VoiceCommand.Save("desk"),
            "Mark here as bathroom." to VoiceCommand.Save("bathroom"),
            "this is the living room" to VoiceCommand.Save("living room"),
            "Take me to the kitchen" to VoiceCommand.Navigate("kitchen"),
            "navigate me to room 204" to VoiceCommand.Navigate("room 204"),
            "Please navigate to the exit" to VoiceCommand.Navigate("exit"),
            "how do I get to the lift" to VoiceCommand.Navigate("lift"),
            "go to bathroom" to VoiceCommand.Navigate("bathroom"),
            "Where is the exit?" to VoiceCommand.WhereIs("exit"),
            "where's my bed" to VoiceCommand.WhereIs("bed"),
            "Where am I?" to VoiceCommand.WhereAmI,
            "what's around me" to VoiceCommand.WhatsAround,
            "Stop" to VoiceCommand.Stop,
            "cancel route" to VoiceCommand.Stop,
            "repeat" to VoiceCommand.RepeatLast,
            "what places do you know" to VoiceCommand.ListPlaces,
            "help" to VoiceCommand.Help,
        )
        for ((spoken, expected) in cases) assertEquals(expected, VoiceCommand.parse(spoken), "\"$spoken\"")
    }

    @Test fun unknownSpeechIsReportedAsUnknown() {
        assertEquals(VoiceCommand.Unknown("banana"), VoiceCommand.parse("banana"))
        assertEquals(VoiceCommand.Unknown(""), VoiceCommand.parse(""))
    }

    @Test fun normalizesSpokenNumbers() {
        assertEquals("room 204", PlaceMatcher.normalize("Room two oh four"))
        assertEquals("room 204", PlaceMatcher.normalize("ROOM 2 0 4"))
        assertEquals("way kitchen", PlaceMatcher.normalize("the way to the kitchen"))
        assertEquals("floor 2", PlaceMatcher.normalize("Floor 2"))
    }

    @Test fun matchesDespiteRecognitionSlips() {
        assertEquals(1.0, PlaceMatcher.score("kitchen", "Kitchen"))
        assertEquals(1.0, PlaceMatcher.score("room two oh four", "ROOM 204"))
        assertTrue(PlaceMatcher.score("rest room", "Restroom") > 0.9)
        assertTrue(PlaceMatcher.score("kitchin", "Kitchen") > 0.8)
        assertEquals(0.0, PlaceMatcher.score("room 205", "Room 204"))
        assertTrue(PlaceMatcher.score("garage", "Kitchen") < 0.5)
    }

    @Test fun bestDestinationPrefersNamedPlacesThenNearestSign() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 20.0)))
        rec.markSign("EXIT", Vec2(0.0, 1.0))
        rec.markSign("EXIT", Vec2(0.0, 19.0))
        rec.markLandmark("Kitchen", Vec2(0.0, 10.0))
        rec.markSign("Kitchen", Vec2(0.0, 15.0))
        val g = rec.graph
        assertTrue(PlaceMatcher.best("exit", g, Vec2(0.0, 18.0))!!.position.distanceTo(Vec2(0.0, 19.0)) < 0.5)
        assertTrue(PlaceMatcher.best("exit", g, Vec2(0.0, 2.0))!!.position.distanceTo(Vec2(0.0, 1.0)) < 0.5)
        assertEquals("Kitchen", PlaceMatcher.best("kitchen", g, Vec2(0.0, 15.0))?.landmark)
        assertNull(PlaceMatcher.best("garage", g))
    }

    @Test fun signFilterKeepsSignsAndDropsNoise() {
        assertEquals("Room 204", SignFilter.clean("ROOM 204", 0.9f, 0.05))
        assertEquals("Exit", SignFilter.clean("Exit", 0.9f, 0.05))
        assertEquals("Exit", SignFilter.clean("EXIT", 0.9f, 0.05))
        assertNull(SignFilter.clean("Exit", 0.3f, 0.05))
        assertNull(SignFilter.clean("Exit", 0.9f, 0.01))
        assertNull(SignFilter.clean("This is a long sentence from a poster on the wall", 0.9f, 0.05))
        assertNull(SignFilter.clean("www.example.com", 0.9f, 0.05))
        assertNull(SignFilter.clean("#@!", 0.9f, 0.05))
    }

    @Test fun theSameSignIsRememberedOnce() {
        val rec = TrailRecorder()
        walk(rec, listOf(Vec2(0.0, 0.0), Vec2(0.0, 10.0)))
        assertNotNull(rec.markSign("Room 204", Vec2(0.0, 5.0)))
        assertNull(rec.markSign("ROOM 204", Vec2(0.0, 6.0)))
        assertNotNull(rec.markSign("Room 204", Vec2(0.0, 10.0)))
        assertEquals(2, rec.graph.nodes.count { it.signText != null })
    }

    @Test fun differentFloorsDoNotMerge() {
        val rec = TrailRecorder()
        walk3D(rec, listOf(Vec2(0.0, 0.0) to 0.0, Vec2(0.0, 5.0) to 0.0))
        rec.breakTrail()
        walk3D(rec, listOf(Vec2(-2.0, 2.5) to 3.0, Vec2(2.0, 2.5) to 3.0))
        val lower = rec.graph.nearestNode(Vec2(0.0, 2.5), 0.0)!!
        val upper = rec.graph.nearestNode(Vec2(0.0, 2.5), 3.0)!!
        assertNull(rec.graph.shortestPath(lower, upper))
    }

    @Test fun findsAFlightOfStairs() {
        val rec = TrailRecorder()
        walk3D(rec, listOf(Vec2(0.0, 0.0) to 0.0, Vec2(0.0, 3.0) to 0.0, Vec2(0.0, 6.0) to 2.0, Vec2(0.0, 9.0) to 2.0))
        val dest = rec.markLandmark("Upstairs", Vec2(0.0, 9.0), 2.0)
        val path = rec.graph.shortestPath(0, dest)!!
        val flights = findStairs(rec.graph.positions(path), rec.graph.heights(path))
        assertEquals(1, flights.size)
        assertTrue(flights[0].goingUp)
        assertTrue(abs(flights[0].steps - 12) <= 1)
        assertTrue(flights[0].start.distanceTo(Vec2(0.0, 3.0)) < 0.6)
    }

    @Test fun rampsAndDriftAreNotStairs() {
        val route = (0..20).map { Vec2(0.0, it * 0.5) }
        assertTrue(findStairs(route, (0..20).map { it * 0.5 * 0.08 }).isEmpty())
        assertTrue(findStairs(route, (0..20).map { it * 0.01 }).isEmpty())
    }

    @Test fun guideWarnsBeforeStairs() {
        val rec = TrailRecorder()
        walk3D(rec, listOf(Vec2(0.0, 0.0) to 0.0, Vec2(0.0, 6.0) to 0.0, Vec2(0.0, 9.0) to -2.0, Vec2(0.0, 12.0) to -2.0))
        val dest = rec.markLandmark("Basement", Vec2(0.0, 12.0), -2.0)
        val path = rec.graph.shortestPath(0, dest)!!
        val guide = Guide(rec.graph.positions(path), rec.graph.heights(path), "Basement")
        val r = simulate(guide, Vec2(0.0, 0.0))
        assertTrue(r.arrived)
        val warning = r.said.indexOfFirst { it.startsWith("Stairs going down") }
        assertTrue(warning >= 0, "said: ${r.said}")
        assertTrue(r.said[warning].contains("Hold the handrail"))
        assertContains(r.said, "Stairs now, going down.")
        assertContains(r.said, "End of stairs.")
        assertTrue(warning < r.said.indexOf("Stairs now, going down."))
    }
}
