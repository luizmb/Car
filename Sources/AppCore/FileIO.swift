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
