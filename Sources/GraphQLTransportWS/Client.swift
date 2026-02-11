import Foundation
import GraphQL

/// Client is an open-ended implementation of the client side of the protocol. It parses and adds callbacks for each type of server respose.
public class Client<InitPayload: Equatable & Codable>: @unchecked Sendable {
    let messenger: Messenger

    var onConnectionAck: (ConnectionAckResponse, Client) async throws -> Void = { _, _ in }
    var onNext: (NextResponse, Client) async throws -> Void = { _, _ in }
    var onError: (ErrorResponse, Client) async throws -> Void = { _, _ in }
    var onComplete: (CompleteResponse, Client) async throws -> Void = { _, _ in }
    var onMessage: (String, Client) async throws -> Void = { _, _ in }

    let encoder = GraphQLJSONEncoder()
    let decoder = JSONDecoder()

    /// Create a new client.
    ///
    /// - Parameters:
    ///   - messenger: The messenger to bind the client to.
    public init(
        messenger: Messenger
    ) {
        self.messenger = messenger
    }

    /// Listen and react to the provided async sequence of server messages. This function will block until the stream is completed.
    /// - Parameter incoming: The server message sequence that the client should react to.
    public func listen<A: AsyncSequence & Sendable>(to incoming: A) async throws -> Void where A.Element == String {
        for try await message in incoming {
            try await self.onMessage(message, self)

            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }

            guard let json = message.data(using: .utf8) else {
                try await self.error(.invalidEncoding())
                return
            }

            let response: Response
            do {
                response = try self.decoder.decode(Response.self, from: json)
            } catch {
                try await self.error(.noType())
                return
            }

            switch response.type {
            case .connectionAck:
                guard let connectionAckResponse = try? self.decoder.decode(ConnectionAckResponse.self, from: json) else {
                    try await self.error(.invalidResponseFormat(messageType: .connectionAck))
                    return
                }
                try await self.onConnectionAck(connectionAckResponse, self)
            case .next:
                guard let nextResponse = try? self.decoder.decode(NextResponse.self, from: json) else {
                    try await self.error(.invalidResponseFormat(messageType: .next))
                    return
                }
                try await self.onNext(nextResponse, self)
            case .error:
                guard let errorResponse = try? self.decoder.decode(ErrorResponse.self, from: json) else {
                    try await self.error(.invalidResponseFormat(messageType: .error))
                    return
                }
                try await self.onError(errorResponse, self)
            case .complete:
                guard let completeResponse = try? self.decoder.decode(CompleteResponse.self, from: json) else {
                    try await self.error(.invalidResponseFormat(messageType: .complete))
                    return
                }
                try await self.onComplete(completeResponse, self)
            default:
                try await self.error(.invalidType())
            }
        }
    }

    /// Define the callback run on receipt of a `connection_ack` message
    /// - Parameter callback: The callback to assign
    public func onConnectionAck(_ callback: @escaping (ConnectionAckResponse, Client) async throws -> Void) {
        onConnectionAck = callback
    }

    /// Define the callback run on receipt of a `next` message
    /// - Parameter callback: The callback to assign
    public func onNext(_ callback: @escaping (NextResponse, Client) async throws -> Void) {
        onNext = callback
    }

    /// Define the callback run on receipt of an `error` message
    /// - Parameter callback: The callback to assign
    public func onError(_ callback: @escaping (ErrorResponse, Client) async throws -> Void) {
        onError = callback
    }

    /// Define the callback run on receipt of a `complete` message
    /// - Parameter callback: The callback to assign
    public func onComplete(_ callback: @escaping (CompleteResponse, Client) async throws -> Void) {
        onComplete = callback
    }

    /// Define the callback run on receipt of any message
    /// - Parameter callback: The callback to assign
    public func onMessage(_ callback: @escaping (String, Client) async throws -> Void) {
        onMessage = callback
    }

    /// Send a `connection_init` request through the messenger
    public func sendConnectionInit(payload: InitPayload) async throws {
        try await messenger.send(
            ConnectionInitRequest(
                payload: payload
            ).toJSON(encoder)
        )
    }

    /// Send a `subscribe` request through the messenger
    public func sendStart(payload: GraphQLRequest, id: String) async throws {
        try await messenger.send(
            SubscribeRequest(
                payload: payload,
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send a `complete` request through the messenger
    public func sendStop(id: String) async throws {
        try await messenger.send(
            CompleteRequest(
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send an error through the messenger and close the connection
    private func error(_ error: GraphQLTransportWSError) async throws {
        try await messenger.error(error.message, code: error.code.rawValue)
    }
}
