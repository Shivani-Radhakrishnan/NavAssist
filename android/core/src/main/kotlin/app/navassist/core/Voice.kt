package app.navassist.core

import kotlin.math.max
import kotlin.math.min

/** What the user asked for, from one spoken sentence. */
sealed interface VoiceCommand {
    data class Save(val name: String) : VoiceCommand          // "save this place as kitchen"
    data object SaveWithoutName : VoiceCommand                // "save this place as" and then nothing usable
    data class Navigate(val name: String) : VoiceCommand      // "take me to the kitchen"
    data class WhereIs(val name: String) : VoiceCommand       // "where is the exit"
    data object WhereAmI : VoiceCommand
    data object WhatsAround : VoiceCommand
    data object Stop : VoiceCommand
    data object RepeatLast : VoiceCommand
    data object ListPlaces : VoiceCommand
    data object Help : VoiceCommand
    data class Unknown(val text: String) : VoiceCommand

    companion object {
        private val fillers = listOf("please", "can you", "could you", "would you", "hey", "okay", "ok", "um", "uh")

        private val stopPhrases = setOf("stop", "cancel", "stop navigation", "stop navigating", "cancel route", "stop route", "end route")
        private val repeatPhrases = setOf("repeat", "again", "say again", "repeat that", "what", "pardon", "what did you say", "next", "what's next")
        private val whereAmIPhrases = setOf("where am i", "where am i now", "my location", "current location")
        private val aroundPhrases = setOf("what's around", "whats around", "what is around", "what's near", "what's nearby",
            "what is near me", "what's near me", "what's around me", "what is around me", "describe surroundings", "look around")
        private val listPhrases = setOf("list places", "what places", "what places do you know", "which places", "list locations",
            "saved places", "where can i go", "what can i go to", "places")
        private val helpPhrases = setOf("help", "what can i say", "commands", "what can you do")

        private val savePatterns = listOf(
            "save (?:this |the )?(?:place|location|spot|position|here)? ?as",
            "record (?:this |the )?(?:place|location|spot|position)? ?as",
            "record (?:this |the )?(?:place|location|spot|position)",
            "save (?:this |the )?(?:place|location|spot|position)",
            "remember (?:this|here|this place|this spot|this location) as",
            "mark (?:this|here|this place|this spot) as",
            "call (?:this|here) (?:place )?",
            "name (?:this|here) (?:place )?",
            "this is (?:the |my )?",
            "i am at (?:the |my )?", "i'm at (?:the |my )?",
            "add (?:a )?(?:place|location|landmark)",
        )
        private val wherePatterns = listOf(
            "where is (?:the |my )?", "where's (?:the |my )?", "how far is (?:the |my )?",
            "which way is (?:the |my )?", "find (?:the |my )?",
        )
        private val navigatePatterns = listOf(
            "navigate (?:me )?to", "take me to", "guide me to", "bring me to", "lead me to",
            "go to", "walk me to", "directions to", "get me to", "how do i get to",
            "i want to go to", "i need to go to", "route to", "navigate",
        )

        /** Understands many natural ways of saying the same thing; case, punctuation and filler don't matter. */
        fun parse(raw: String): VoiceCommand {
            var s = raw.lowercase().replace(Regex("[^a-z0-9' ]"), " ")
            for (f in fillers) s = s.replace(Regex("\\b$f\\b"), " ")
            s = s.split(" ").filter { it.isNotEmpty() }.joinToString(" ")
            if (s.isEmpty()) return Unknown(raw)

            fun after(patterns: List<String>): String? {
                for (p in patterns) {
                    val m = Regex("^(?:$p)\\b\\s*(.+)$").find(s) ?: continue
                    val rest = cleanName(m.groupValues[1])
                    if (rest.isNotEmpty()) return rest
                }
                return null
            }

            // Stop wins whenever it leads the sentence ("stop stop", "stop guiding", "cancel the route").
            val words = s.split(" ")
            val stopWords = setOf("stop", "cancel", "end", "quit", "halt", "the", "route", "navigation",
                                  "navigating", "guiding", "guidance", "now", "it", "that")
            if (words.first() in setOf("stop", "cancel", "halt", "quit") && (words.all { it in stopWords } || words.size <= 3)) return Stop

            when (s) {
                in stopPhrases -> return Stop
                in repeatPhrases -> return RepeatLast
                in whereAmIPhrases -> return WhereAmI
                in aroundPhrases -> return WhatsAround
                in listPhrases -> return ListPlaces
                in helpPhrases -> return Help
            }
            after(savePatterns)?.let { return if (isUsableName(it)) Save(it) else SaveWithoutName }
            val saveFiller = setOf("save", "record", "remember", "mark", "this", "the", "place", "location", "spot", "here", "as", "position")
            if (Regex("^(?:save|record|remember|mark)\\b").containsMatchIn(s) && words.size <= 5 && words.all { it in saveFiller }) {
                return SaveWithoutName
            }
            after(wherePatterns)?.let { return WhereIs(it) }
            after(navigatePatterns)?.let { return Navigate(it) }
            return Unknown(raw)
        }

        /** A spoken name must contain something besides filler ("save this place as" + pause gives "as"). */
        internal fun isUsableName(name: String): Boolean {
            val filler = setOf("as", "here", "this", "place", "spot", "location", "the", "a", "it", "that", "um", "uh")
            return name.split(" ").any { it.isNotEmpty() && it !in filler }
        }

        private fun cleanName(s: String): String {
            var t = s.trim()
            for (prefix in listOf("the ", "my ", "a ", "an ")) if (t.startsWith(prefix)) t = t.removePrefix(prefix)
            for (suffix in listOf(" please", " now")) if (t.endsWith(suffix)) t = t.removeSuffix(suffix)
            return t.trim()
        }
    }
}

/** Finds the place the user meant, tolerating speech-recognition slips. */
object PlaceMatcher {
    private val numberWords = mapOf(
        "zero" to "0", "oh" to "0", "o" to "0", "one" to "1", "two" to "2", "to" to "2", "too" to "2", "three" to "3",
        "four" to "4", "for" to "4", "five" to "5", "six" to "6", "seven" to "7", "eight" to "8", "nine" to "9",
        "ten" to "10", "first" to "1", "second" to "2", "third" to "3", "fourth" to "4", "fifth" to "5",
    )
    private val ignored = setOf("the", "a", "an", "my", "of", "to")
    private val ambiguous = setOf("to", "too", "for", "o", "first", "second", "third", "fourth", "fifth")
    private val digitWords = setOf("zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "oh")

    private fun isInt(s: String) = s.toIntOrNull() != null

    /** Lowercase, no punctuation, number words as digits, digits joined ("2 0 4" -> "204"), filler removed. */
    fun normalize(s: String): String {
        val words = s.lowercase().replace(Regex("[^a-z0-9 ]"), " ").split(" ").filter { it.isNotEmpty() }
        val out = mutableListOf<String>()
        words.forEachIndexed { i, w ->
            val neighbourIsNumber = listOf(i - 1, i + 1).any { j -> j in words.indices && (isInt(words[j]) || words[j] in digitWords) }
            val d = numberWords[w]
            when {
                d != null && (w !in ambiguous || neighbourIsNumber) ->
                    if (out.isNotEmpty() && isInt(out.last())) out[out.size - 1] = out.last() + d else out += d
                isInt(w) && out.isNotEmpty() && isInt(out.last()) -> out[out.size - 1] = out.last() + w
                w !in ignored -> out += w
            }
        }
        return out.joinToString(" ")
    }

    /** 0..1: how well a spoken query matches a place name. */
    fun score(query: String, name: String): Double {
        val q = normalize(query)
        val n = normalize(name)
        if (q.isEmpty() || n.isEmpty()) return 0.0
        if (q == n) return 1.0
        val qs = q.replace(" ", "")
        val ns = n.replace(" ", "")
        if (qs == ns) return 0.97
        val qt = q.split(" ").toSet()
        val nt = n.split(" ").toSet()
        val qNums = qt.filter(::isInt).toSet()
        val nNums = nt.filter(::isInt).toSet()
        if (qNums.isNotEmpty() && nNums.isNotEmpty() && qNums.intersect(nNums).isEmpty()) return 0.0
        // Every spoken word is in the name ("exit" -> "Emergency Exit"): a confident match.
        if (nt.containsAll(qt) || qt.containsAll(nt)) {
            return 0.75 + 0.2 * min(qt.size, nt.size).toDouble() / max(qt.size, nt.size)
        }
        val jaccard = qt.intersect(nt).size.toDouble() / qt.union(nt).size
        val edit = 1 - levenshtein(qs, ns).toDouble() / max(qs.length, ns.length)
        return max(jaccard, edit)
    }

    /** Best matching destination, preferring named places over signs, and nearer ones on ties. */
    fun best(query: String, graph: RouteGraph, near: Vec2? = null, threshold: Double = 0.72): RouteGraph.Node? {
        var best: RouteGraph.Node? = null
        var bestScore = -1.0
        for (n in graph.destinations) {
            var s = max(n.landmark?.let { score(query, it) + 0.02 } ?: 0.0, n.signText?.let { score(query, it) } ?: 0.0)
            if (s < threshold) continue
            if (near != null) s -= min(n.position.distanceTo(near), 100.0) / 10_000
            if (s > bestScore) { best = n; bestScore = s }
        }
        return best
    }

    internal fun levenshtein(a: String, b: String): Int {
        if (a.isEmpty()) return b.length
        if (b.isEmpty()) return a.length
        var prev = IntArray(b.length + 1) { it }
        for (i in 1..a.length) {
            val cur = IntArray(b.length + 1).also { it[0] = i }
            for (j in 1..b.length) {
                cur[j] = minOf(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
            }
            prev = cur
        }
        return prev[b.length]
    }
}

/** Decides whether text the camera read looks like a sign worth remembering. */
object SignFilter {
    fun clean(raw: String, confidence: Float, relativeHeight: Double): String? {
        if (confidence < 0.5f || relativeHeight < 0.025) return null
        val t = raw.trim().replace(Regex("\\s+"), " ")
        if (t.length !in 2..32) return null
        if (t.split(" ").size > 5) return null
        val letters = t.count { it.isLetter() }
        val digits = t.count { it.isDigit() }
        if (letters + digits < (t.length * 0.7).toInt()) return null
        if (letters < 2 && digits < 2) return null
        val lower = t.lowercase()
        if (listOf("www", "http", ".com", "$", "€", "£").any { lower.contains(it) }) return null
        // ALL-CAPS words can be spelled out letter by letter by the speech voice, so title-case them.
        return if (t == t.uppercase() && letters >= 3) {
            t.split(" ").joinToString(" ") { w -> w.lowercase().replaceFirstChar { it.uppercase() } }
        } else t
    }
}
