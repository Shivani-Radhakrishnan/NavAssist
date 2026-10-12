import Foundation

/// How important a spoken message is. Higher can interrupt lower, never the other way round.
public enum SpeechPriority: Int, Comparable, Sendable, CaseIterable {
    /// Signs read, coaching cues, "path clear".
    case info = 0
    /// Directions and system messages.
    case navigation = 1
    /// Obstacles ahead, stairs, "stop".
    case safety = 2

    public static func < (a: SpeechPriority, b: SpeechPriority) -> Bool { a.rawValue < b.rawValue }
}

/// Decides what to say next, so messages never fight:
/// - a message interrupts the current one only if it is more important, or equally important and
///   urgent; a safety message is never cut off in its first `safetyMinimum` seconds;
/// - anything that has to wait is queued (a few per priority) and dropped once older than
///   `maxAge`, so stale directions aren't read out late;
/// - an interrupted message goes back to the front of its queue;
/// - while the user is giving a voice command, nothing is spoken (the microphone would hear it);
///   queued messages are released when listening ends.
///
/// The app's speech engine calls `request` / `finished` / `setListening` and performs the action
/// returned. All decisions are here, so they can be tested.
public struct SpeechArbiter: Sendable {
    public enum Action: Equatable, Sendable {
        case none
        /// Start speaking (nothing is playing).
        case speak(String)
        /// Stop the current sentence immediately and speak this instead.
        case interrupt(String)
    }

    public var maxAge = 4.0
    public var safetyMinimum = 1.5
    public var queueLimit = 3

    private struct Item: Sendable {
        var text: String
        var priority: SpeechPriority
        var time: Double
    }

    private var current: Item?
    private var currentStarted = 0.0
    private var queues: [SpeechPriority: [Item]] = [:]
    public private(set) var listening = false

    public init() {}

    public var isSpeaking: Bool { current != nil }

    public mutating func request(_ text: String, priority: SpeechPriority, urgent: Bool, now: Double) -> Action {
        let item = Item(text: text, priority: priority, time: now)
        if listening {
            enqueue(item)
            return .none
        }
        guard let cur = current else {
            start(item, now)
            return .speak(text)
        }
        if cur.text == text, cur.priority == priority { return .none }        // already saying it
        let protected = cur.priority == .safety && now - currentStarted < safetyMinimum
        let outranks = priority > cur.priority || (priority == cur.priority && urgent)
        if outranks && !protected {
            enqueueFront(cur)          // finish it later if it's still fresh
            start(item, now)
            return .interrupt(text)
        }
        enqueue(item)
        return .none
    }

    /// The current sentence finished (or was cancelled): what's next?
    public mutating func finished(now: Double) -> Action {
        current = nil
        return listening ? .none : next(now)
    }

    /// The microphone opened (true) or closed (false).
    public mutating func setListening(_ on: Bool, now: Double) -> Action {
        listening = on
        if on {
            if let cur = current { enqueueFront(cur) }
            current = nil
            return .none
        }
        return current == nil ? next(now) : .none
    }

    /// Drop everything (e.g. the user stopped the route).
    public mutating func clear() {
        current = nil
        queues = [:]
    }

    private mutating func next(_ now: Double) -> Action {
        for p in SpeechPriority.allCases.reversed() {
            var q = queues[p, default: []].filter { now - $0.time <= maxAge }
            if !q.isEmpty {
                let item = q.removeFirst()
                queues[p] = q
                start(item, now)
                return .speak(item.text)
            }
            queues[p] = q
        }
        return .none
    }

    private mutating func start(_ item: Item, _ now: Double) {
        current = item
        currentStarted = now
    }

    private mutating func enqueue(_ item: Item) {
        var q = queues[item.priority, default: []]
        q.removeAll { $0.text == item.text }
        q.append(item)
        if q.count > queueLimit { q.removeFirst(q.count - queueLimit) }
        queues[item.priority] = q
    }

    private mutating func enqueueFront(_ item: Item) {
        var q = queues[item.priority, default: []]
        q.removeAll { $0.text == item.text }
        q.insert(item, at: 0)
        if q.count > queueLimit { q.removeLast(q.count - queueLimit) }
        queues[item.priority] = q
    }
}

extension Array where Element == GuidanceEvent {
    /// Speech in a batch that comes with a "stop" or "obstacle" vibration is a safety message.
    public var impliedPriority: SpeechPriority {
        contains { if case .haptic(let c) = $0 { return c == .stop || c == .obstacle } else { return false } }
            ? .safety : .navigation
    }
}
