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

/// Reads a named JSON document from the app database. Cold — nothing is touched until subscribed.
///
/// The error vocabulary survives the move from files unchanged, because the distinctions it draws
/// are about the *data*, not the container: an absent row is the normal first-run state, a row
/// that fails to decode means the shape changed, and an absent database means the disk failed.
func makeDocumentReader<A: Decodable & Sendable>(
    _ type: A.Type,
    name: String,
    database: AppDatabase?
) -> Publisher<Result<A, FileError>, Never> {
    Publisher { continuation in
        guard let database else {
            continuation.yield(.failure(.unreadable("app database unavailable")))
            return
        }
        guard let json = database.document(name) else {
            continuation.yield(.failure(.notFound))
            return
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            continuation.yield(.success(try decoder.decode(A.self, from: Data(json.utf8))))
        } catch {
            // A decode error means the row is there but its shape changed — a migration problem,
            // never to be silently treated as empty.
            continuation.yield(.failure(.malformed(String(describing: error))))
        }
    }
}

/// Writes a named JSON document to the app database, replacing it whole — the same semantics the
/// atomic file write had, for the same reason: a fuel log half-written when the app is killed
/// would take every past fill with it.
func makeDocumentWriter<A: Encodable & Sendable>(
    _ value: A,
    name: String,
    database: AppDatabase?
) -> Publisher<Result<Void, FileError>, Never> {
    Publisher { continuation in
        guard let database else {
            continuation.yield(.failure(.unwritable("app database unavailable")))
            return
        }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            database.saveDocument(name, json: String(decoding: data, as: UTF8.self))
            continuation.yield(.success(()))
        } catch {
            continuation.yield(.failure(.unwritable(String(describing: error))))
        }
    }
}
