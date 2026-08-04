import Foundation

/// Appends every dispatched action to a JSONL file.
///
/// Crude on purpose. In a Redux app every observation already passes through the store as an
/// action, so dumping actions captures GPS, road info, Indimate, Cardo, CHIGEE and tyre readings in
/// one stroke, in true interleaved order, with no per-source plumbing. That is worth far more on a
/// first ride than a well-typed schema would be.
///
/// Actions are recorded via `String(describing:)` rather than `Codable`. That is a deliberate
/// trade: no conformances to write, nothing to keep in step as types change, and the output is
/// still perfectly parseable offline. When the real recorder lands it will replace this wholesale.
///
/// Written with `O_APPEND` and flushed per line: the app spends whole journeys backgrounded and can
/// be killed at any moment, so buffering would risk losing exactly the ride you cared about.
final class ActionLogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private var _url: URL?

    var url: URL? { lock.withLock { _url } }

    init() {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = directory.appendingPathComponent("ride-\(stamp).jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        lock.withLock {
            _url = file
            handle = try? FileHandle(forWritingTo: file)
        }
    }

    func append(_ action: String) {
        let line: [String: Any] = [
            "t": ISO8601DateFormatter().string(from: Date()),
            "a": action
        ]
        guard
            let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return }
        lock.withLock {
            handle?.write(Data((text + "\n").utf8))
        }
    }
}
