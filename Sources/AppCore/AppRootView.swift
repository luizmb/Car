import AppDomain
import SwiftUI

/// A `NavigationStack` whose path is a store-backed binding.
/// Knows nothing about routes or feature construction — content is provided by the caller.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
public struct AppRootView<Content: View>: View {
    let path: Binding<[AppRoute]>
    @ViewBuilder let content: () -> Content

    public init(
        path: Binding<[AppRoute]>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.path = path
        self.content = content
    }

    public var body: some View {
        NavigationStack(path: path) {
            content()
        }
    }
}
