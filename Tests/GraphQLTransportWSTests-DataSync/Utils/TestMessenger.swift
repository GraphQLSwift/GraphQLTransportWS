import Foundation

@testable import GraphQLTransportWS_DataSync

/// Messenger for simple testing that doesn't require starting up a websocket server.
///
/// Note that this only retains a weak reference to 'other', so the client should retain references
/// or risk them being deinitialized early
class TestMessenger: Messenger {
    weak var other: TestMessenger?
    var onReceive: (String) -> Void = { _ in }
    let queue: DispatchQueue = .init(label: "Test messenger")

    init() {}

    func send<S>(_ message: S) where S: Collection, S.Element == Character {
        guard let other = other else {
            return
        }

        // Run the other message asyncronously to avoid nesting issues
        queue.async {
            other.onReceive(String(message))
        }
    }

    func onReceive(callback: @escaping (String) -> Void) {
        self.onReceive = callback
    }

    func error(_ message: String, code: Int) {
        self.send("\(code): \(message)")
    }

    func close() {
        // This is a testing no-op
    }
}
