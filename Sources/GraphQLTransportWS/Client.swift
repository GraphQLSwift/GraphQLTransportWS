import Foundation
import GraphQL

/// Client is an open-ended implementation of the client side of the protocol. It parses and adds callbacks for each type of server respose.
public actor Client<InitPayload: Equatable & Codable> {
    let messenger: Messenger

    let onConnectionAck: (ConnectionAckResponse, Client) async throws -> Void
    let onNext: (NextResponse, Client) async throws -> Void
    let onError: (ErrorResponse, Client) async throws -> Void
    let onComplete: (CompleteResponse, Client) async throws -> Void

    let encoder = GraphQLJSONEncoder()
    let decoder = JSONDecoder()

    /// Create a new client.
    ///
    /// - Parameters:
    ///   - messenger: The messenger to bind the client to.
    public init(
        messenger: Messenger,
        onConnectionAck: @escaping (ConnectionAckResponse, Client) async throws -> Void = { _, _ in },
        onNext: @escaping (NextResponse, Client) async throws -> Void = { _, _ in },
        onError: @escaping (ErrorResponse, Client) async throws -> Void = { _, _ in },
        onComplete: @escaping (CompleteResponse, Client) async throws -> Void = { _, _ in }
    ) {
        self.messenger = messenger
        self.onConnectionAck = onConnectionAck
        self.onNext = onNext
        self.onError = onError
        self.onComplete = onComplete
    }

    /// Listen and react to the provided async sequence of server messages. This function will block until the stream is completed.
    /// - Parameter incoming: The server message sequence that the client should react to.
    public func listen<A: AsyncSequence & Sendable>(to incoming: A) async throws -> Void where A.Element == String {
        for try await message in incoming {
            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }

            guard let json = message.data(using: .utf8) else {
                try await error(.invalidEncoding())
                return
            }

            let response: Response
            do {
                response = try decoder.decode(Response.self, from: json)
            } catch {
                try await self.error(.noType())
                return
            }

            switch response.type {
            case .connectionAck:
                guard let connectionAckResponse = try? decoder.decode(ConnectionAckResponse.self, from: json) else {
                    try await error(.invalidResponseFormat(messageType: .connectionAck))
                    return
                }
                try await onConnectionAck(connectionAckResponse, self)
            case .next:
                guard let nextResponse = try? decoder.decode(NextResponse.self, from: json) else {
                    try await error(.invalidResponseFormat(messageType: .next))
                    return
                }
                try await onNext(nextResponse, self)
            case .error:
                guard let errorResponse = try? decoder.decode(ErrorResponse.self, from: json) else {
                    try await error(.invalidResponseFormat(messageType: .error))
                    return
                }
                try await onError(errorResponse, self)
            case .complete:
                guard let completeResponse = try? decoder.decode(CompleteResponse.self, from: json) else {
                    try await error(.invalidResponseFormat(messageType: .complete))
                    return
                }
                try await onComplete(completeResponse, self)
            default:
                try await error(.invalidType())
            }
        }
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
