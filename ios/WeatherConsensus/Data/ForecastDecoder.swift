import Foundation

/// Why a load could not give us a fresh forecast. Shown as a short note; the last good file stays on screen.
nonisolated enum LoadProblem: Error, Equatable, Sendable {
    /// No internet connection.
    case offline
    /// The server answered with something other than HTTP 200.
    case httpStatus(Int)
    /// Any other network failure (timeout, DNS, TLS).
    case network(String)
    /// The file says it uses a schema this version of the app does not know.
    case unsupportedSchemaVersion(Int)
    /// The file is not valid JSON or does not match schema version 1.
    case unreadable(String)
    /// The good file could not be written to the phone.
    case storage(String)
}

/// Turns the bytes of a published file into a `PlaceForecast`, checking the schema version first.
nonisolated enum ForecastDecoder {
    /// The only schema version this app reads.
    static let supportedSchemaVersion = 1

    private struct VersionProbe: Decodable {
        let schemaVersion: Int

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
        }
    }

    static func decode(_ data: Data) throws(LoadProblem) -> PlaceForecast {
        let decoder = JSONDecoder()
        // issued_at and friends are `YYYY-MM-DDTHH:MM:SSZ`; .iso8601 reads exactly that.
        decoder.dateDecodingStrategy = .iso8601

        let version: Int
        do {
            version = try decoder.decode(VersionProbe.self, from: data).schemaVersion
        } catch {
            throw .unreadable("No schema_version: \(error.localizedDescription)")
        }
        guard version == supportedSchemaVersion else {
            throw .unsupportedSchemaVersion(version)
        }

        do {
            return try decoder.decode(PlaceForecast.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
    }
}
