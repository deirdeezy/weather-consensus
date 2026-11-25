import Foundation

/// Keeps the latest good file for each place on the phone, and nothing else.
///
/// Layout: `Application Support/Forecasts/<place id>.json`, one file per place.
/// Saving replaces the file atomically, then removes anything in the folder that is not
/// a `<place id>.json` file (older copies, leftovers from an interrupted write), so storage
/// never grows over time (docs/BUILD_PLAN.md, Stage 3).
///
/// The folder is excluded from backup: every file can be downloaded again. Apple's guidance:
/// "Exclude from the backup any file that your app can recreate or redownload"
/// (Foundation, Using the file system effectively). Some file operations reset the flag,
/// so it is set again on every save (Foundation, Optimizing Your App's Data for iCloud Backup).
nonisolated struct ForecastStore: Sendable {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// The store the app uses: `Application Support/Forecasts`.
    static func appDefault() -> ForecastStore {
        let base = URL.applicationSupportDirectory
        return ForecastStore(directory: base.appending(path: "Forecasts", directoryHint: .isDirectory))
    }

    /// Place ids are `^[a-z0-9-]+$` (docs/place-v1.schema.json).
    static func isValidPlaceID(_ id: String) -> Bool {
        !id.isEmpty && id.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }

    func fileURL(for placeID: String) -> URL {
        directory.appending(path: "\(placeID).json", directoryHint: .notDirectory)
    }

    /// Saves the raw bytes (unknown fields kept) as the latest file for this place,
    /// then deletes any older copies.
    func save(_ data: Data, placeID: String) throws(LoadProblem) {
        guard Self.isValidPlaceID(placeID) else { throw .storage("Bad place id") }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL(for: placeID), options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var folder = directory
            try folder.setResourceValues(values)
        } catch {
            throw .storage(error.localizedDescription)
        }
        removeOlderCopies()
    }

    /// The saved bytes for a place, if any.
    func savedData(placeID: String) -> Data? {
        guard Self.isValidPlaceID(placeID) else { return nil }
        return try? Data(contentsOf: fileURL(for: placeID))
    }

    /// The saved forecast for a place, if a readable schema v1 file is there.
    func savedForecast(placeID: String) -> PlaceForecast? {
        guard let data = savedData(placeID: placeID) else { return nil }
        return try? ForecastDecoder.decode(data)
    }

    /// Every file in the store folder (used by tests and by the clean-up).
    func storedFiles() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: []
        )) ?? []
    }

    /// Deletes everything in the folder that is not exactly `<place id>.json`.
    /// One name per place means one file per place.
    func removeOlderCopies() {
        for url in storedFiles() {
            let name = url.lastPathComponent
            let isLatestFile = name.hasSuffix(".json") && Self.isValidPlaceID(String(name.dropLast(5)))
            if !isLatestFile {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
