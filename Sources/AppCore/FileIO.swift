import AppDomain
import FPMacros
import FP
import Foundation
import ReactiveConcurrency

// MARK: - Errors

/// A specific failure type rather than `any Error`: the caller genuinely needs to distinguish
/// "nothing saved yet" from "saved but unreadable". The first is the normal first-run state; the
/// second means data loss and should never be silently treated as empty.
@Prisms
public enum FileError: Error, Sendable, Equatable {
    case notFound
    case unreadable(String)
    case unwritable(String)
    case malformed(String)
}

// MARK: - Live implementation

/// Reads a JSON document from Documents. Cold — nothing touches the disk until subscribed.
func makeFileReader<A: Decodable & Sendable>(
    _ type: A.Type,
    filename: String
) -> Publisher<Result<A, FileError>, Never> {
    Publisher { continuation in
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: url.path) else {
            continuation.yield(.failure(.notFound))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            continuation.yield(.success(try decoder.decode(A.self, from: data)))
        } catch let error as DecodingError {
            // Distinguished from an IO failure on purpose — a decode error means the file is there
            // but its shape changed, which is a migration problem, not a missing file.
            continuation.yield(.failure(.malformed(String(describing: error))))
        } catch {
            continuation.yield(.failure(.unreadable(error.localizedDescription)))
        }
    }
}

/// Writes a JSON document to Documents, atomically.
///
/// Atomic matters here: a fuel log half-written when the app is killed would take every past fill
/// with it, and this app spends its life being backgrounded and terminated.
func makeFileWriter<A: Encodable & Sendable>(
    _ value: A,
    filename: String
) -> Publisher<Result<Void, FileError>, Never> {
    Publisher { continuation in
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(value).write(to: url, options: .atomic)
            continuation.yield(.success(()))
        } catch {
            continuation.yield(.failure(.unwritable(error.localizedDescription)))
        }
    }
}

public enum TripStore {
    /// Kept in its own tiny file rather than inside the fuel log: it is written every few hundred
    /// metres, and rewriting the whole fill history at that rate would be both wasteful and a
    /// needless risk to the only durable record of every refuel.
    public static let filename = "trip-distance.json"
}

public enum FuelStore {
    /// Plain JSON in Documents, visible in the Files app — so the record can be inspected, backed
    /// up, or corrected by hand without needing the app at all.
    public static let filename = "fuel-log.json"
}
