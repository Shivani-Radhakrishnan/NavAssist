import Foundation

/// A recorded place (a home, an office floor...) as saved to disk.
///
/// The ARKit world map that lets the phone recognise the place again is saved next to
/// this file as raw data by the app; this struct holds everything else.
public struct PlaceFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var created: Date
    /// When the app was last used here; the most recent place is tried first at launch.
    public var lastUsed: Date?
    public var graph: RouteGraph

    public init(name: String, graph: RouteGraph, created: Date = Date()) {
        self.version = Self.currentVersion
        self.name = name
        self.created = created
        self.graph = graph
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(self)
    }

    public enum ValidationError: Error, Equatable {
        case newerVersion(Int)
        case corruptGraph(String)
    }

    /// Decode and check a saved place. A damaged or hand-edited file is rejected with an error
    /// instead of crashing the app later (node ids out of order, edges to missing nodes).
    public static func decode(_ data: Data) throws -> PlaceFile {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let place = try dec.decode(PlaceFile.self, from: data)
        guard place.version <= currentVersion else { throw ValidationError.newerVersion(place.version) }
        let n = place.graph.nodes.count
        for (i, node) in place.graph.nodes.enumerated() where node.id != i {
            throw ValidationError.corruptGraph("node \(i) has id \(node.id)")
        }
        for (id, nbs) in place.graph.neighbours {
            guard id >= 0, id < n, nbs.allSatisfy({ $0 >= 0 && $0 < n }) else {
                throw ValidationError.corruptGraph("edge from \(id) refers to a missing node")
            }
        }
        return place
    }

    /// File-system-safe folder name for a place.
    public static func folderName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = String(name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Place" : cleaned
    }
}
