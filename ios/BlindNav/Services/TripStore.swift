import BlindNavCore
import Foundation

/// Saves trip logs to Documents/Trips (visible in the Files app under "On My iPhone › BlindNav").
struct TripStore {
    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Trips", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    func save(_ log: TripLog) {
        let stamp = ISO8601DateFormatter().string(from: log.started).replacingOccurrences(of: ":", with: "-")
        let base = "\(PlaceFile.folderName(for: log.participant))_\(stamp)_\(log.adaptive ? "cues" : "nocues")"
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(log).write(to: root.appendingPathComponent(base + ".json"), options: .atomic)
        try? log.csv().write(to: root.appendingPathComponent(base + ".csv"), atomically: true, encoding: .utf8)
    }

    func count() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.hasSuffix(".json") }.count
    }

    /// All trips' CSVs joined into one file (one header), ready to share.
    func combinedCSV() -> URL? {
        let files = ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "csv" && $0.lastPathComponent != "all_trips.csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return nil }
        var out = ""
        for (i, f) in files.enumerated() {
            guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            out += (i == 0 ? lines : Array(lines.dropFirst())).joined(separator: "\n") + "\n"
        }
        let url = root.appendingPathComponent("all_trips.csv")
        try? out.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func deleteAll() {
        for f in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: f)
        }
    }

    /// Model weights trained by analysis/train_predictor.py: Documents/predictor.json (copied
    /// in with the Files app) wins over one bundled in the app; otherwise the built-in defaults.
    static func loadPredictor() -> BehaviorPredictor {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        for url in [docs.appendingPathComponent("predictor.json"), Bundle.main.url(forResource: "predictor", withExtension: "json")] {
            if let url, let data = try? Data(contentsOf: url),
               let p = try? JSONDecoder().decode(BehaviorPredictor.self, from: data) {
                return p
            }
        }
        return .defaults
    }
}
