package app.navassist.core

/**
 * One object found by the door / door-handle / stairs detector (trained on Open Images; see
 * training/detector). Boxes are normalised to the upright camera image, origin top left.
 */
data class Detection(val kind: Kind, val confidence: Double, val x: Double, val y: Double, val width: Double, val height: Double) {
    enum class Kind { DOOR, DOOR_HANDLE, STAIRS }

    val centerX get() = x + width / 2
    val centerY get() = y + height / 2
    val maxX get() = x + width
    val maxY get() = y + height

    internal fun contains(px: Double, py: Double, margin: Double): Boolean {
        val mx = width * margin
        val my = height * margin
        return px >= x - mx && px <= maxX + mx && py >= y - my && py <= maxY + my
    }
}

/** Which side of a door its handle is on, from the user's point of view. */
enum class Side { LEFT, RIGHT }

/**
 * Turns detector boxes into scene hints: a door in the walking direction and how far it is,
 * which side its handle is on, and stairs ahead with a distance. [depth] gives meters to the
 * surface at a normalised image point, or null when unknown. Mirrors Detections.swift.
 */
class DetectionInterpreter(
    var minConfidence: Map<Detection.Kind, Double> = mapOf(
        Detection.Kind.DOOR to 0.5, Detection.Kind.DOOR_HANDLE to 0.35, Detection.Kind.STAIRS to 0.5),
    var corridor: ClosedFloatingPointRange<Double> = 0.3..0.7,
    var maxRange: Double = 6.0,
) {
    fun hints(detections: List<Detection>, depth: (Double, Double) -> Double?): SceneHints {
        val kept = detections.filter { it.confidence >= (minConfidence[it.kind] ?: 0.5) }
        val ahead = kept.filter { it.x < corridor.endInclusive && it.maxX > corridor.start }

        val doors = ahead.filter { it.kind == Detection.Kind.DOOR }.map { it to depth(it.centerX, it.centerY) }
        val door = doors.sortedWith(compareBy<Pair<Detection, Double?>> { it.second == null }
            .thenBy { it.second ?: 0.0 }.thenByDescending { it.first.width * it.first.height }).firstOrNull()
        var doorAhead: Double? = null
        var handleSide: Side? = null
        if (door != null) {
            val (box, meters) = door
            if (meters != null && meters <= maxRange) doorAhead = meters
            kept.filter { it.kind == Detection.Kind.DOOR_HANDLE && box.contains(it.centerX, it.centerY, 0.1) }
                .maxByOrNull { it.confidence }
                ?.let { handleSide = if (it.centerX < box.centerX) Side.LEFT else Side.RIGHT }
        }

        val stairs = ahead.filter { it.kind == Detection.Kind.STAIRS }
        val stairsAhead = stairs.mapNotNull { depth(it.centerX, minOf(it.maxY - 0.05 * it.height, 0.99)) }
            .filter { it <= maxRange }.minOrNull()
        return SceneHints(doorAhead = doorAhead, handleSide = handleSide, stairsInView = stairs.isNotEmpty(),
                          stairsAhead = stairsAhead)
    }
}
