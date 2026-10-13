package app.navassist.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Mirrors DetectionTests.swift. */
class DetectionTest {
    private fun box(kind: Detection.Kind, x: Double, y: Double, w: Double, h: Double, c: Double = 0.9) =
        Detection(kind, c, x, y, w, h)

    @Test fun aDoorAheadGetsADistanceAndItsHandleSide() {
        val hints = DetectionInterpreter().hints(listOf(
            box(Detection.Kind.DOOR, 0.35, 0.1, 0.3, 0.8), box(Detection.Kind.DOOR_HANDLE, 0.56, 0.5, 0.04, 0.04))) { _, _ -> 2.4 }
        assertEquals(2.4, hints.doorAhead)
        assertEquals(Side.RIGHT, hints.handleSide)
    }

    @Test fun doorsOutsideTheCorridorAndWeakDetectionsAreIgnored() {
        val hints = DetectionInterpreter().hints(listOf(
            box(Detection.Kind.DOOR, 0.0, 0.1, 0.2, 0.8), box(Detection.Kind.DOOR, 0.4, 0.1, 0.2, 0.8, 0.2))) { _, _ -> 1.0 }
        assertNull(hints.doorAhead)
        assertNull(hints.handleSide)
    }

    @Test fun theNearestDoorWinsAndAHandleOnAnotherDoorDoesNotCount() {
        val hints = DetectionInterpreter().hints(listOf(
            box(Detection.Kind.DOOR, 0.3, 0.2, 0.2, 0.5), box(Detection.Kind.DOOR, 0.5, 0.1, 0.3, 0.8),
            box(Detection.Kind.DOOR_HANDLE, 0.32, 0.45, 0.03, 0.03))) { u, _ -> if (u < 0.45) 5.0 else 1.5 }
        assertEquals(1.5, hints.doorAhead)
        assertNull(hints.handleSide)
    }

    @Test fun stairsAheadAreMeasuredWhereTheyStart() {
        var sampledAt = 0.0
        val hints = DetectionInterpreter().hints(listOf(box(Detection.Kind.STAIRS, 0.2, 0.5, 0.6, 0.4))) { _, v -> sampledAt = v; 3.1 }
        assertTrue(hints.stairsInView)
        assertEquals(3.1, hints.stairsAhead)
        assertTrue(sampledAt > 0.85)
    }

    @Test fun announcementsUseTheStairDistance() {
        val a = ObstacleAnnouncer()
        val said = a.update(ZoneReading(listOf(0.0, 0.0, 0.0), hints = SceneHints(stairsInView = true, stairsAhead = 3.0)), 0.0)
            .filterIsInstance<GuidanceEvent.Speak>().map { it.text }
        assertTrue(said.first().startsWith("Stairs ahead, 3"))
    }
}
