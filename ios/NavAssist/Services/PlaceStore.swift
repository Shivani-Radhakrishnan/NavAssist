import ARKit
import NavAssistCore

/// Saves places to the app's Documents folder:
///     Documents/Places/<name>/place.json    routes and landmarks
///     Documents/Places/<name>/world.armap   what ARKit needs to recognise the place
struct PlaceStore {
    enum StoreError: LocalizedError {
        case mapUnreadable
        var errorDescription: String? { "The saved map for this place could not be read." }
    }

    let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Places", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private func folder(_ name: String) -> URL {
        root.appendingPathComponent(PlaceFile.folderName(for: name), isDirectory: true)
    }

    func list() -> [PlaceFile] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { dir in
            (try? Data(contentsOf: dir.appendingPathComponent("place.json"))).flatMap { try? PlaceFile.decode($0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ place: PlaceFile, map: ARWorldMap) throws {
        let dir = folder(place.name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mapData = try NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
        try mapData.write(to: dir.appendingPathComponent("world.armap"), options: .atomic)
        try place.encoded().write(to: dir.appendingPathComponent("place.json"), options: .atomic)
    }

    func loadMap(for place: PlaceFile) throws -> ARWorldMap {
        let data = try Data(contentsOf: folder(place.name).appendingPathComponent("world.armap"))
        guard let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) else {
            throw StoreError.mapUnreadable
        }
        return map
    }

    func delete(_ place: PlaceFile) throws {
        try FileManager.default.removeItem(at: folder(place.name))
    }
}
