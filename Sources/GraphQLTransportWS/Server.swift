import Foundation
import GraphQL

/// Server implements the server-side portion of the protocol, allowing a few callbacks for customization.
///
/// By default, there are no authorization checks
public actor Server<
    InitPayload: Equatable & Codable & Sendable,
    InitPayloadResult: Sendable,
    SubscriptionSequenceType: AsyncSequence & Sendable
>
where
    SubscriptionSequenceType.Element == GraphQLResult
{
    let messenger: Messenger

    let onInit: (InitPayload) async throws -> InitPayloadResult
    let onExecute: (GraphQLRequest, InitPayloadResult) async throws -> GraphQLResult
    let onSubscribe: (GraphQLRequest, InitPayloadResult) async throws -> SubscriptionSequenceType
    let onOperationComplete: (String) async throws -> Void
    let onOperationError: (String, [Error]) async throws -> Void

    let decoder = JSONDecoder()
    let encoder = GraphQLJSONEncoder()

    private var initialized = false
    private var initResult: InitPayloadResult?
    private var subscriptionTasks = [String: Task<Void, any Error>]()

    /// Create a new server
    ///
    /// - Parameters:
    ///   - messenger: The messenger to bind the server to.
    ///   - onExecute: Callback run during `start` resolution for non-streaming queries. Typically this is `API.execute`.
    ///   - onSubscribe: Callback run during `start` resolution for streaming queries. Typically this is `API.subscribe`.
    ///   - onOperationComplete: Optional callback run when an operation completes
    ///   - onOperationError: Optional callback run when an operation errors
    public init(
        messenger: Messenger,
        onInit: @escaping (InitPayload) async throws -> InitPayloadResult,
        onExecute: @escaping (GraphQLRequest, InitPayloadResult) async throws -> GraphQLResult,
        onSubscribe:
            @escaping (GraphQLRequest, InitPayloadResult) async throws -> SubscriptionSequenceType,
        onOperationComplete: @escaping (String) async throws -> Void = { _ in },
        onOperationError: @escaping (String, [Error]) async throws -> Void = { _, _ in }
    ) {
        self.messenger = messenger
        self.onInit = onInit
        self.onExecute = onExecute
        self.onSubscribe = onSubscribe
        self.onOperationComplete = onOperationComplete
        self.onOperationError = onOperationError
    }

    /// Listen and react to the provided async sequence of client messages. This function will block until the stream is completed.
    /// - Parameter incoming: The client message sequence that the server should react to.
    public func listen<A: AsyncSequence & Sendable>(to incoming: A) async throws
    where A.Element == String {
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

            let request: Request
            do {
                request = try decoder.decode(Request.self, from: json)
            } catch {
                try await self.error(.noType())
                return
            }

            // handle incoming message
            switch request.type {
            case .connectionInit:
                guard
                    let connectionInitRequest = try? decoder.decode(
                        ConnectionInitRequest<InitPayload>.self,
                        from: json
                    )
                else {
                    try await error(.invalidRequestFormat(messageType: .connectionInit))
                    return
                }
                try await onConnectionInit(connectionInitRequest, messenger)
            case .subscribe:
                guard let subscribeRequest = try? decoder.decode(SubscribeRequest.self, from: json)
                else {
                    try await error(.invalidRequestFormat(messageType: .subscribe))
                    return
                }
                try await onSubscribe(subscribeRequest)
            case .complete:
                guard let completeRequest = try? decoder.decode(CompleteRequest.self, from: json)
                else {
                    try await error(.invalidRequestFormat(messageType: .complete))
                    return
                }
                try await onOperationComplete(completeRequest)
            default:
                try await error(.invalidType())
            }
        }
    }

    deinit {
        subscriptionTasks.values.forEach { $0.cancel() }
    }

    private func onConnectionInit(
        _ connectionInitRequest: ConnectionInitRequest<InitPayload>,
        _: Messenger
    ) async throws {
        guard !initialized else {
            try await error(.tooManyInitializations())
            return
        }

        do {
            initResult = try await onInit(connectionInitRequest.payload)
        } catch {
            try await self.error(.unauthorized())
            return
        }
        initialized = true
        try await sendConnectionAck()
        // TODO: Should we send the `ka` message?
    }

    private func onSubscribe(_ subscribeRequest: SubscribeRequest) async throws {
        guard initialized, let initResult else {
            try await error(.notInitialized())
            return
        }

        let id = subscribeRequest.id
        if subscriptionTasks[id] != nil {
            try await error(.subscriberAlreadyExists(id: id))
        }

        let graphQLRequest = subscribeRequest.payload

        var isStreaming = false
        do {
            isStreaming = try graphQLRequest.isSubscription()
        } catch {
            try await sendError(error, id: id)
            return
        }

        if isStreaming {
            subscriptionTasks[id] = Task {
                do {
                    let stream = try await onSubscribe(graphQLRequest, initResult)
                    for try await event in stream {
                        try Task.checkCancellation()
                        try await self.sendNext(event, id: id)
                    }
                } catch {
                    try await sendError(error, id: id)
                    subscriptionTasks.removeValue(forKey: id)
                    throw error
                }
                try await self.sendComplete(id: id)
                subscriptionTasks.removeValue(forKey: id)
            }
        } else {
            do {
                let result = try await onExecute(graphQLRequest, initResult)
                try await sendNext(result, id: id)
                try await sendComplete(id: id)
            } catch {
                try await sendError(error, id: id)
            }
        }
    }

    private func onOperationComplete(_ completeRequest: CompleteRequest) async throws {
        guard initialized else {
            try await error(.notInitialized())
            return
        }

        let id = completeRequest.id
        if let task = subscriptionTasks[id] {
            task.cancel()
            subscriptionTasks.removeValue(forKey: id)
        }
        try await onOperationComplete(id)
    }

    /// Send a `connection_ack` response through the messenger
    private func sendConnectionAck(_ payload: [String: Map]? = nil) async throws {
        try await messenger.send(
            ConnectionAckResponse(payload: payload).toJSON(encoder)
        )
    }

    /// Send a `next` response through the messenger
    private func sendNext(_ payload: GraphQLResult? = nil, id: String) async throws {
        try await messenger.send(
            NextResponse(
                payload: payload,
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send a `complete` response through the messenger
    private func sendComplete(id: String) async throws {
        try await messenger.send(
            CompleteResponse(
                id: id
            ).toJSON(encoder)
        )
        try await onOperationComplete(id)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ errors: [Error], id: String) async throws {
        try await messenger.send(
            ErrorResponse(
                errors,
                id: id
            ).toJSON(encoder)
        )
        try await onOperationError(id, errors)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ error: Error, id: String) async throws {
        try await sendError([error], id: id)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ errorMessage: String, id: String) async throws {
        try await sendError(GraphQLError(message: errorMessage), id: id)
    }

    /// Send an error through the messenger and close the connection
    private func error(_ error: GraphQLTransportWSError) async throws {
        try await messenger.error(error.message, code: error.code.rawValue)
    }
}
