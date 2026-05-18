import Foundation

public enum Either<T, U> {
    case left(T)
    case right(U)

    public var left: T? {
        switch self {
        case let .left(value): return value
        default: return nil
        }
    }

    public var right: U? {
        switch self {
        case let .right(value): return value
        default: return nil
        }
    }
}

public extension Either {
    init(_ t: T) {
        self = .left(t)
    }

    init(_ u: U) {
        self = .right(u)
    }
}

extension Either: Equatable where T: Equatable, U: Equatable {}

public extension Either {
    func mapLeft<Z>(
        _ lf: (T) -> Z
    ) -> Either<Z, U> {
        switch self {
        case let .left(left):
            return .left(lf(left))
        case let .right(right):
            return .right(right)
        }
    }

    func mapRight<Z>(
        _ rf: (U) -> Z
    ) -> Either<T, Z> {
        switch self {
        case let .left(left):
            return .left(left)
        case let .right(right):
            return .right(rf(right))
        }
    }

    func bimap<T1, U1>(
        _ lf: (T) -> T1,
        _ rf: (U) -> U1
    ) -> Either<T1, U1> {
        switch self {
        case let .left(left):
            return .left(lf(left))
        case let .right(right):
            return .right(rf(right))
        }
    }
}

public extension Either {
    func fold<Z>(
        leftBy lf: (T) -> Z,
        rightBy rf: (U) -> Z
    ) -> Z {
        switch self {
        case let .left(left):
            return lf(left)
        case let .right(right):
            return rf(right)
        }
    }
}
