import SwiftRex

// Stores are declarative: production code follows `stateStream` and views read through a view store.
// A test wants the state at one moment, and the stream hands that back synchronously on subscribing —
// dropping the token straight away ends the subscription again.
@MainActor
extension StoreType {
    var currentState: State { stateStream.subscribe(onChange: { _ in }).current }
}
