
import Foundation

@testable import GraphQLTransportWS

/// Messenger for simple testing that doesn't require starting up a websocket server.
actor TestMessenger: Messenger {
    /// An async stream of the messages sent through this messenger.
    let stream: AsyncStream<String>
    private var continuation: AsyncStream<String>.Continuation

    init() {
        let (stream, continuation) = AsyncStream<String>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func send<S: Sendable>(_ message: S) async throws where S: Collection, S.Element == Character {
        continuation.yield(String(message))
    }

    func error(_ message: String, code: Int) async throws {
        continuation.yield("\(code): \(message)")
        continuation.finish()
    }

    func close() {
        continuation.finish()
    }
}
