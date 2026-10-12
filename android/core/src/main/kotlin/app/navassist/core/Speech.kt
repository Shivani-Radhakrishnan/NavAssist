package app.navassist.core

/** How important a spoken message is. Higher can interrupt lower, never the other way round. */
enum class SpeechPriority {
    /** Signs read, coaching cues, "path clear". */
    INFO,
    /** Directions and system messages. */
    NAVIGATION,
    /** Obstacles ahead, stairs, "stop". */
    SAFETY,
}

/**
 * Decides what to say next, so messages never fight:
 * - a message interrupts the current one only if it is more important, or equally important and
 *   urgent; a safety message is never cut off in its first [safetyMinimum] seconds;
 * - anything that has to wait is queued (a few per priority) and dropped once older than
 *   [maxAge], so stale directions aren't read out late;
 * - an interrupted message goes back to the front of its queue;
 * - while the user is giving a voice command, nothing is spoken (the microphone would hear it);
 *   queued messages are released when listening ends.
 *
 * The app's speech engine calls [request] / [finished] / [setListening] and performs the action
 * returned. All decisions are here, so they can be tested.
 */
class SpeechArbiter(
    var maxAge: Double = 4.0,
    var safetyMinimum: Double = 1.5,
    var queueLimit: Int = 3,
) {
    sealed interface Action {
        data object None : Action
        /** Start speaking (nothing is playing). */
        data class Speak(val text: String) : Action
        /** Stop the current sentence immediately and speak this instead. */
        data class Interrupt(val text: String) : Action
    }

    private data class Item(val text: String, val priority: SpeechPriority, val time: Double)

    private var current: Item? = null
    private var currentStarted = 0.0
    private val queues = mutableMapOf<SpeechPriority, MutableList<Item>>()
    var listening = false
        private set

    val isSpeaking: Boolean get() = current != null

    fun request(text: String, priority: SpeechPriority, urgent: Boolean, now: Double): Action {
        val item = Item(text, priority, now)
        if (listening) {
            enqueue(item)
            return Action.None
        }
        val cur = current ?: run {
            start(item, now)
            return Action.Speak(text)
        }
        if (cur.text == text && cur.priority == priority) return Action.None      // already saying it
        val protected = cur.priority == SpeechPriority.SAFETY && now - currentStarted < safetyMinimum
        val outranks = priority > cur.priority || (priority == cur.priority && urgent)
        if (outranks && !protected) {
            enqueueFront(cur)          // finish it later if it's still fresh
            start(item, now)
            return Action.Interrupt(text)
        }
        enqueue(item)
        return Action.None
    }

    /** The current sentence finished (or was cancelled): what's next? */
    fun finished(now: Double): Action {
        current = null
        return if (listening) Action.None else next(now)
    }

    /** The microphone opened (true) or closed (false). */
    fun setListening(on: Boolean, now: Double): Action {
        listening = on
        if (on) {
            current?.let { enqueueFront(it) }
            current = null
            return Action.None
        }
        return if (current == null) next(now) else Action.None
    }

    /** Drop everything (e.g. the user stopped the route). */
    fun clear() {
        current = null
        queues.clear()
    }

    private fun next(now: Double): Action {
        for (p in SpeechPriority.entries.reversed()) {
            val q = queues.getOrPut(p) { mutableListOf() }
            q.removeAll { now - it.time > maxAge }
            if (q.isNotEmpty()) {
                val item = q.removeAt(0)
                start(item, now)
                return Action.Speak(item.text)
            }
        }
        return Action.None
    }

    private fun start(item: Item, now: Double) {
        current = item
        currentStarted = now
    }

    private fun enqueue(item: Item) {
        val q = queues.getOrPut(item.priority) { mutableListOf() }
        q.removeAll { it.text == item.text }
        q.add(item)
        while (q.size > queueLimit) q.removeAt(0)
    }

    private fun enqueueFront(item: Item) {
        val q = queues.getOrPut(item.priority) { mutableListOf() }
        q.removeAll { it.text == item.text }
        q.add(0, item)
        while (q.size > queueLimit) q.removeAt(q.size - 1)
    }
}

/** Speech in a batch that comes with a "stop" or "obstacle" vibration is a safety message. */
val List<GuidanceEvent>.impliedPriority: SpeechPriority
    get() = if (any { it is GuidanceEvent.Haptic && (it.cue == HapticCue.STOP || it.cue == HapticCue.OBSTACLE) })
        SpeechPriority.SAFETY else SpeechPriority.NAVIGATION
