import AppCore
import CombineRex
import SwiftUI

@main
struct CarApp: App {
    @StateObject var store = AppCore.Store().asObservableViewModel(initialState: .initialState)

    var body: some Scene {
        WindowGroup {
            MainView(store: store)
        }
    }
}
