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
    private var executionTasks = [String: Task<Void, any Error>]()

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

    deinit {
        executionTasks.values.forEach { $0.cancel() }
    }

    /// Listen and react to the provided async sequence of client messages. This function will block until the stream is completed.
    /// - Parameter incoming: The client message sequence that the server should react to.
    public func listen<A: AsyncSequence & Sendable>(to incoming: A) async throws
    where A.Element == Data {
        for try await message in incoming {
            try await respond(to: message)
        }
    }

    private func respond(to message: Data) async throws {
        let request: Request
        do {
            request = try decoder.decode(Request.self, from: message)
        } catch {
            try await messenger.error(.noType())
            return
        }

        // handle incoming message
        switch request.type {
        case .connectionInit:
            let connectionInitRequest: ConnectionInitRequest<InitPayload>
            do {
                connectionInitRequest = try decoder.decode(
                    ConnectionInitRequest<InitPayload>.self,
                    from: message
                )
            } catch {
                try await messenger.error(.invalidRequestFormat(messageType: .connectionInit, error: error))
                return
            }
            try await onConnectionInit(connectionInitRequest, messenger)
        case .subscribe:
            let subscribeRequest: SubscribeRequest
            do {
                subscribeRequest = try decoder.decode(SubscribeRequest.self, from: message)
            } catch {
                try await messenger.error(.invalidRequestFormat(messageType: .subscribe, error: error))
                return
            }
            try await onSubscribe(subscribeRequest)
        case .complete:
            let completeRequest: CompleteRequest
            do {
                completeRequest = try decoder.decode(CompleteRequest.self, from: message)
            } catch {
                try await messenger.error(.invalidRequestFormat(messageType: .complete, error: error))
                return
            }
            try await onOperationComplete(completeRequest)
        default:
            try await messenger.error(.invalidType())
        }
    }

    private func onConnectionInit(
        _ connectionInitRequest: ConnectionInitRequest<InitPayload>,
        _: Messenger
    ) async throws {
        guard !initialized else {
            try await messenger.error(.tooManyInitializations())
            return
        }

        do {
            initResult = try await onInit(connectionInitRequest.payload)
        } catch {
            try await messenger.error(.forbidden())
            return
        }
        initialized = true
        try await sendConnectionAck()
        // TODO: Should we send the `ka` message?
    }

    private func onSubscribe(_ subscribeRequest: SubscribeRequest) async throws {
        guard initialized, let initResult else {
            try await messenger.error(.notInitialized())
            return
        }

        let id = subscribeRequest.id
        let graphQLRequest = subscribeRequest.payload

        let isStreaming: Bool
        do {
            isStreaming = try graphQLRequest.isSubscription()
        } catch {
            try await sendError(error, id: id)
            return
        }

        guard executionTasks[id] == nil else {
            try await messenger.error(.subscriberAlreadyExists(id: id))
            return
        }
        executionTasks[id] = Task {
            defer {
                executionTasks.removeValue(forKey: id)
            }

            if isStreaming {
                let stream: SubscriptionSequenceType
                do {
                    stream = try await onSubscribe(graphQLRequest, initResult)
                } catch {
                    try await sendError(error, id: id)
                    return
                }
                for try await event in stream {
                    try await self.sendNext(event, id: id)
                }
                executionTasks.removeValue(forKey: id)
            } else {
                let result: GraphQLResult
                do {
                    result = try await onExecute(graphQLRequest, initResult)
                } catch {
                    try await sendError(error, id: id)
                    return
                }
                try await sendNext(result, id: id)
            }
            try await sendComplete(id: id)
        }
    }

    private func onOperationComplete(_ completeRequest: CompleteRequest) async throws {
        guard initialized else {
            try await messenger.error(.notInitialized())
            return
        }

        let id = completeRequest.id
        if let task = executionTasks[id] {
            task.cancel()
            executionTasks.removeValue(forKey: id)
        }
        try await onOperationComplete(id)
    }

    /// Send a `connection_ack` response through the messenger
    private func sendConnectionAck(_ payload: [String: Map]? = nil) async throws {
        try await messenger.send(
            encoder.encode(
                ConnectionAckResponse(payload: payload)
            )
        )
    }

    /// Send a `next` response through the messenger
    private func sendNext(_ payload: GraphQLResult? = nil, id: String) async throws {
        try await messenger.send(
            encoder.encode(
                NextResponse(
                    payload: payload,
                    id: id
                )
            )
        )
    }

    /// Send a `complete` response through the messenger
    private func sendComplete(id: String) async throws {
        try await messenger.send(
            encoder.encode(
                CompleteResponse(
                    id: id
                )
            )
        )
        try await onOperationComplete(id)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ errors: [Error], id: String) async throws {
        try await messenger.send(
            encoder.encode(
                ErrorResponse(
                    errors,
                    id: id
                )
            )
        )
        try await onOperationError(id, errors)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ error: Error, id: String) async throws {
        try await sendError([error], id: id)
    }
}
