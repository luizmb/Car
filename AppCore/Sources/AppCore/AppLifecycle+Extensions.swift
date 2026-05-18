import AppLifecycleMiddleware

extension AppLifecycleAction {
    public var start: Void? {
        get {
            guard case .start = self else { return nil }
            return ()
        }
    }

    public var isStart: Bool {
        self.start != nil
    }
}
