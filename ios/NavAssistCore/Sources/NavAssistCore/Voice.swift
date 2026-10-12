import Foundation

/// What the user asked for, from one spoken sentence.
public enum VoiceCommand: Equatable, Sendable {
    case save(String)          // "save this place as kitchen", "record location kitchen"
    case saveWithoutName       // "save this place as" ... and then nothing usable
    case navigate(String)      // "take me to the kitchen", "navigate to room 204"
    case whereIs(String)       // "where is the exit"
    case whereAmI
    case whatsAround
    case stop
    case repeatLast
    case listPlaces
    case help
    case unknown(String)

    /// Understands many natural ways of saying the same thing. Case and punctuation
    /// don't matter; "please" and filler words are ignored.
    public static func parse(_ raw: String) -> VoiceCommand {
        var s = raw.lowercased()
            .replacingOccurrences(of: "[^a-z0-9' ]", with: " ", options: .regularExpression)
        for filler in ["please", "can you", "could you", "would you", "hey", "okay", "ok", "um", "uh"] {
            s = s.replacingOccurrences(of: "\\b\(filler)\\b", with: " ", options: .regularExpression)
        }
        s = s.split(separator: " ").joined(separator: " ")
        if s.isEmpty { return .unknown(raw) }

        func after(_ patterns: [String]) -> String? {
            for p in patterns {
                if let r = s.range(of: "^(?:\(p))\\b\\s*(.+)$", options: .regularExpression) {
                    let whole = String(s[r])
                    if let m = whole.range(of: "^(?:\(p))\\b\\s*", options: .regularExpression) {
                        let rest = cleanName(String(whole[m.upperBound...]))
                        if !rest.isEmpty { return rest }
                    }
                }
            }
            return nil
        }

        // Stop wins whenever it leads the sentence ("stop", "stop stop", "stop guiding", "cancel the route").
        let words = s.split(separator: " ").map(String.init)
        let stopWords: Set<String> = ["stop", "cancel", "end", "quit", "halt", "the", "route", "navigation",
                                      "navigating", "guiding", "guidance", "now", "it", "that"]
        if let first = words.first, ["stop", "cancel", "halt", "quit"].contains(first),
           words.allSatisfy({ stopWords.contains($0) }) || words.count <= 3 {
            return .stop
        }

        // Exact short commands first.
        switch s {
        case "stop", "cancel", "stop navigation", "stop navigating", "cancel route", "stop route", "end route":
            return .stop
        case "repeat", "again", "say again", "repeat that", "what", "pardon", "what did you say", "next", "what's next":
            return .repeatLast
        case "where am i", "where am i now", "my location", "current location":
            return .whereAmI
        case "what's around", "whats around", "what is around", "what's near", "what's nearby", "what is near me",
             "what's near me", "what's around me", "what is around me", "describe surroundings", "look around":
            return .whatsAround
        case "list places", "what places", "what places do you know", "which places", "list locations",
             "saved places", "where can i go", "what can i go to", "places":
            return .listPlaces
        case "help", "what can i say", "commands", "what can you do":
            return .help
        default:
            break
        }

        if let name = after([
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
        ]) { return isUsableName(name) ? .save(name) : .saveWithoutName }
        if s.range(of: "^(?:save|record|remember|mark)\\b", options: .regularExpression) != nil,
           s.split(separator: " ").count <= 5,
           s.split(separator: " ").allSatisfy({ ["save", "record", "remember", "mark", "this", "the", "place", "location",
                                                 "spot", "here", "as", "position"].contains(String($0)) }) {
            return .saveWithoutName
        }

        if let name = after([
            "where is (?:the |my )?", "where's (?:the |my )?", "how far is (?:the |my )?",
            "which way is (?:the |my )?", "find (?:the |my )?",
        ]) { return .whereIs(name) }

        if let name = after([
            "navigate (?:me )?to", "take me to", "guide me to", "bring me to", "lead me to",
            "go to", "walk me to", "directions to", "get me to", "how do i get to",
            "i want to go to", "i need to go to", "route to", "navigate",
        ]) { return .navigate(name) }

        return .unknown(raw)
    }

    /// A spoken name must contain something besides filler ("save this place as" + pause gives "as").
    static func isUsableName(_ name: String) -> Bool {
        let filler: Set<String> = ["as", "here", "this", "place", "spot", "location", "the", "a", "it", "that", "um", "uh"]
        return name.split(separator: " ").contains { !filler.contains(String($0)) }
    }

    private static func cleanName(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["the ", "my ", "a ", "an "] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
        for suffix in [" please", " now"] where t.hasSuffix(suffix) { t.removeLast(suffix.count) }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Finds the place the user meant, tolerating speech-recognition slips:
/// "kitchen" = "the Kitchen", "room two oh four" = sign "ROOM 204", "rest room" = "Restroom".
public enum PlaceMatcher {
    static let numberWords: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "to": "2", "too": "2", "three": "3",
        "four": "4", "for": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "first": "1", "second": "2", "third": "3", "fourth": "4", "fifth": "5",
    ]
    static let ignored: Set<String> = ["the", "a", "an", "my", "of", "to"]

    /// Lowercase, no punctuation, number words as digits, digits joined ("2 0 4" -> "204"),
    /// and filler words removed.
    public static func normalize(_ s: String) -> String {
        let words = s.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
        var out: [String] = []
        for (i, w) in words.enumerated() {
            // "to"/"for"/"o" only count as numbers next to other digits ("room two oh four").
            let neighbourIsNumber = [i - 1, i + 1].contains { j in
                words.indices.contains(j) && (Int(words[j]) != nil || ["zero", "one", "two", "three", "four", "five", "six",
                                                                        "seven", "eight", "nine", "oh"].contains(words[j]))
            }
            let ambiguous: Set<String> = ["to", "too", "for", "o", "first", "second", "third", "fourth", "fifth"]
            if let d = numberWords[w], !ambiguous.contains(w) || neighbourIsNumber {
                if let last = out.last, Int(last) != nil { out[out.count - 1] = last + d } else { out.append(d) }
            } else if Int(w) != nil, let last = out.last, Int(last) != nil {
                out[out.count - 1] = last + w
            } else if !ignored.contains(w) {
                out.append(w)
            }
        }
        return out.joined(separator: " ")
    }

    /// 0...1: how well a spoken query matches a place name.
    public static func score(_ query: String, _ name: String) -> Double {
        let q = normalize(query), n = normalize(name)
        guard !q.isEmpty, !n.isEmpty else { return 0 }
        if q == n { return 1 }
        let qs = q.replacingOccurrences(of: " ", with: ""), ns = n.replacingOccurrences(of: " ", with: "")
        if qs == ns { return 0.97 }                                    // "rest room" vs "restroom"
        let qt = Set(q.split(separator: " ")), nt = Set(n.split(separator: " "))
        // Numbers must agree: "room 204" is not "room 205".
        let qNums = qt.filter { Int($0) != nil }, nNums = nt.filter { Int($0) != nil }
        if !qNums.isEmpty, !nNums.isEmpty, qNums.isDisjoint(with: nNums) { return 0 }
        // Every spoken word is in the name ("exit" -> "Emergency Exit", "kitchen" -> "Kitchen 2"):
        // a confident match, a little less the more extra words the name has.
        if qt.isSubset(of: nt) || nt.isSubset(of: qt) {
            return 0.75 + 0.2 * Double(min(qt.count, nt.count)) / Double(max(qt.count, nt.count))
        }
        let jaccard = Double(qt.intersection(nt).count) / Double(qt.union(nt).count)
        let edit = 1 - Double(levenshtein(qs, ns)) / Double(max(qs.count, ns.count))
        return max(jaccard, edit)
    }

    /// Best matching destination, preferring user-named places over signs and nearer
    /// ones when several match equally (there may be many "Exit" signs).
    public static func best(_ query: String, in graph: RouteGraph, near p: Vec2? = nil,
                            threshold: Double = 0.72) -> RouteGraph.Node? {
        var best: (node: RouteGraph.Node, score: Double)?
        for n in graph.destinations {
            var s = max(n.landmark.map { score(query, $0) + 0.02 } ?? 0, n.signText.map { score(query, $0) } ?? 0)
            guard s >= threshold else { continue }
            if let p { s -= min(n.position.distance(to: p), 100) / 10_000 }   // tie-break by distance
            if s > (best?.score ?? -1) { best = (n, s) }
        }
        return best?.node
    }

    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// Decides whether text the camera read looks like a sign worth remembering.
public enum SignFilter {
    /// Cleaned-up sign text, or nil if it's probably not a sign (too long, mostly
    /// symbols, a lone letter, a price...).
    public static func clean(_ raw: String, confidence: Float, relativeHeight: Double) -> String? {
        guard confidence >= 0.5, relativeHeight >= 0.025 else { return nil }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard (2...32).contains(t.count) else { return nil }
        let words = t.split(separator: " ")
        guard words.count <= 5 else { return nil }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        let digits = t.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
        guard letters + digits >= Int(Double(t.count) * 0.7) else { return nil }
        guard letters >= 2 || digits >= 2 else { return nil }
        // Common noise from screens, clothing and packaging.
        let lower = t.lowercased()
        if ["www", "http", ".com", "$", "€", "£"].contains(where: lower.contains) { return nil }
        // Signs are usually Title Case or UPPER CASE; tidy shouting into Title Case for speech.
        // ALL-CAPS words can be spelled out letter by letter by the speech voice.
        return t == t.uppercased() && letters >= 3 ? t.capitalized : t
    }
}
