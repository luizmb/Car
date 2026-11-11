import SwiftRex
import SwiftRexSwiftUI
import SwiftUI

/// Keeps a view store for a hand-written feature view, and hands it to `content`.
///
/// The `@Feature` macro does this for every feature with a `Content` (its generated `FeatureRoot`). The
/// features here write `view(store:environment:)` by hand because their views need more than the view
/// store — formatters, a camera preview — so they need the same owner spelled out once. The view store is
/// made once per view identity from the stage the router hands over; the views below it only receive it.
struct StoreOwner<Action: Sendable, State: Sendable, Content: View>: View {
    @OwnedStore var viewStore: ViewStore<Action, State>
    let content: (ViewStore<Action, State>) -> Content

    init(
        store: any StoreType<Action, State>,
        @ViewBuilder content: @escaping (ViewStore<Action, State>) -> Content
    ) {
        _viewStore = OwnedStore(wrappedValue: store.viewStore())
        self.content = content
    }

    var body: some View { content(viewStore) }
}
