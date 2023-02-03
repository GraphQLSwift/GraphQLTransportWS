// Copyright (c) 2022 PassiveLogic, Inc.

import Foundation
import GraphQL
import GraphQLRxSwift
import NIO
import RxSwift

/// Server implements the server-side portion of the protocol, allowing a few callbacks for customization.
///
/// By default, there are no authorization checks
public class Server<InitPayload: Equatable & Codable> {
    // We keep this weak because we strongly inject this object into the messenger callback
    weak var messenger: Messenger?

    let onExecute: (GraphQLRequest) -> EventLoopFuture<GraphQLResult>
    let onSubscribe: (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>
    var auth: (InitPayload) throws -> EventLoopFuture<Void>

    var onExit: () -> Void = {}
    var onOperationComplete: (String) -> Void = { _ in }
    var onOperationError: (String, [Error]) -> Void = { _, _ in }
    var onMessage: (String) -> Void = { _ in }
    var onNext: (NextResponse, Server) -> EventLoopFuture<Void>

    var initialized = false

    let disposeBag = DisposeBag()
    let encoder = GraphQLJSONEncoder()
    let decoder = JSONDecoder()

    /// Create a new server
    ///
    /// - Parameters:
    ///   - messenger: The messenger to bind the server to.
    ///   - onExecute: Callback run during `subscribe` resolution for non-streaming queries. Typically this is `API.execute`.
    ///   - onSubscribe: Callback run during `subscribe` resolution for streaming queries. Typically this is `API.subscribe`.
    ///   - eventLoop: EventLoop on which to perform server operations.
    public init(
        messenger: Messenger,
        onExecute: @escaping (GraphQLRequest) -> EventLoopFuture<GraphQLResult>,
        onSubscribe: @escaping (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>,
        eventLoop: EventLoop
    ) {
        self.messenger = messenger
        self.onExecute = onExecute
        self.onSubscribe = onSubscribe
        self.auth = { _ in eventLoop.makeSucceededVoidFuture() }
        self.onNext = { _, _ in eventLoop.makeSucceededVoidFuture() }

        messenger.onReceive { message in
            self.onMessage(message)

            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }

            let data = Data(message.utf8)

            let request: Request
            do {
                request = try self.decoder.decode(Request.self, from: data)
            }
            catch {
                self.error(.noType())
                return
            }

            // handle incoming message
            switch request.type {
                case .connectionInit:
                    guard let connectionInitRequest = try? self.decoder.decode(ConnectionInitRequest<InitPayload>.self, from: data) else {
                        self.error(.invalidRequestFormat(messageType: .connectionInit))
                        return
                    }
                    self.onConnectionInit(connectionInitRequest)
                case .subscribe:
                    guard let subscribeRequest = try? self.decoder.decode(SubscribeRequest.self, from: data) else {
                        self.error(.invalidRequestFormat(messageType: .subscribe))
                        return
                    }
                    self.onSubscribe(subscribeRequest)
                case .complete:
                    guard let completeRequest = try? self.decoder.decode(CompleteRequest.self, from: data) else {
                        self.error(.invalidRequestFormat(messageType: .complete))
                        return
                    }
                    self.onOperationComplete(completeRequest.id)
                case .unknown:
                    self.error(.invalidType())
                // Addition for Datasync: Servers may now receive "next" responses from clients
                case .next:
                    guard self.initialized else {
                        self.error(.notInitialized())
                        return
                    }
                    guard let nextMessage = try? self.decoder.decode(NextResponse.self, from: data) else {
                        self.error(.invalidRequestFormat(messageType: .next))
                        return
                    }
                    self.onNext(nextMessage, self).whenComplete { result in
                        switch result {
                            case .success():
                                return
                            case let .failure(error):
                                self.sendError(error, id: nextMessage.id)
                        }
                    }
            }
        }
    }

    /// Define the callback run during `connection_init` resolution that allows authorization using the `payload`.
    /// Throw or fail the future to indicate that authorization has failed.
    ///  - Parameter callback: The callback to assign
    public func auth(_ callback: @escaping (InitPayload) throws -> EventLoopFuture<Void>) {
        self.auth = callback
    }

    /// Define the callback run when the communication is shut down, either by the client or server
    /// - Parameter callback: The callback to assign
    public func onExit(_ callback: @escaping () -> Void) {
        self.onExit = callback
    }

    /// Define the callback run on receipt of any message
    /// - Parameter callback: The callback to assign
    public func onMessage(_ callback: @escaping (String) -> Void) {
        self.onMessage = callback
    }

    /// Define the callback run on the completion a full operation (query/mutation, end of subscription)
    /// - Parameter callback: The callback to assign,  taking a string parameter for the ID of the operation
    public func onOperationComplete(_ callback: @escaping (String) -> Void) {
        self.onOperationComplete = callback
    }

    /// Define the callback to run on error of any full operation (failed query, interrupted subscription)
    /// - Parameter callback: The callback to assign, taking a string parameter for the ID of the operation
    public func onOperationError(_ callback: @escaping (String, [Error]) -> Void) {
        self.onOperationError = callback
    }

    /// Define the callback run on receipt of a `next` message
    ///
    /// This is the main addition for the DataSync extension for this spec - the server
    /// can now define custom handling for frames containing `GraphQLResult`
    /// objects sent by the client.
    /// - Parameter callback: The callback to assign
    public func onNext(_ callback: @escaping (NextResponse, Server) -> EventLoopFuture<Void>) {
        self.onNext = callback
    }

    private func onConnectionInit(_ connectionInitRequest: ConnectionInitRequest<InitPayload>) {
        guard !initialized else {
            self.error(.tooManyInitializations())
            return
        }

        do {
            let authResult = try self.auth(connectionInitRequest.payload)
            authResult.whenSuccess {
                self.initialized = true
                self.sendConnectionAck()
            }
            authResult.whenFailure { _ in
                self.error(.unauthorized())
            }
        }
        catch {
            self.error(.unauthorized())
            return
        }
    }

    private func onSubscribe(_ subscribeRequest: SubscribeRequest) {
        guard initialized else {
            self.error(.notInitialized())
            return
        }

        let id = subscribeRequest.id
        let graphQLRequest = subscribeRequest.payload

        var isStreaming = false
        do {
            isStreaming = try graphQLRequest.isSubscription()
        }
        catch {
            self.sendError(error, id: id)
            return
        }

        if isStreaming {
            let subscribeFuture = onSubscribe(graphQLRequest)
            subscribeFuture.whenSuccess { [weak self] result in
                guard let self = self else { return }
                guard let streamOpt = result.stream else {
                    // API issue - subscribe resolver isn't stream
                    self.sendError(result.errors, id: id)
                    return
                }

                // known safe cast
                // swiftlint:disable:next force_cast
                let stream = streamOpt as! ObservableSubscriptionEventStream
                let observable = stream.observable

                observable.subscribe(
                    onNext: { [weak self] resultFuture in
                        guard let self = self else { return }
                        resultFuture.whenSuccess { result in
                            self.sendNext(result, id: id)
                        }
                        resultFuture.whenFailure { error in
                            self.sendError(error, id: id)
                        }
                    },
                    onError: { [weak self] error in
                        guard let self = self else { return }
                        self.sendError(error, id: id)
                    },
                    onCompleted: { [weak self] in
                        guard let self = self else { return }
                        self.sendComplete(id: id)
                    }
                ).disposed(by: self.disposeBag)
            }
            subscribeFuture.whenFailure { error in
                self.sendError(error, id: id)
            }
        }
        else {
            let executeFuture = onExecute(graphQLRequest)
            executeFuture.whenSuccess { result in
                self.sendNext(result, id: id)
                self.sendComplete(id: id)
                self.messenger?.close()
            }
            executeFuture.whenFailure { error in
                self.sendError(error, id: id)
                self.sendComplete(id: id)
                self.messenger?.close()
            }
        }
    }

    /// Send a `connection_ack` response through the messenger
    private func sendConnectionAck(_ payload: [String: Map]? = nil) {
        guard let messenger = messenger else { return }
        messenger.send(
            ConnectionAckResponse(payload).toJSON(encoder)
        )
    }

    /// Send a `next` response through the messenger
    private func sendNext(_ payload: GraphQLResult? = nil, id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            NextResponse(
                payload,
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send a `complete` response through the messenger
    private func sendComplete(id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            CompleteResponse(
                id: id
            ).toJSON(encoder)
        )
        self.onOperationComplete(id)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ errors: [Error], id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            ErrorResponse(
                errors,
                id: id
            ).toJSON(encoder)
        )
        self.onOperationError(id, errors)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ error: Error, id: String) {
        self.sendError([error], id: id)
    }

    /// Send an `error` response through the messenger
    private func sendError(_ errorMessage: String, id: String) {
        self.sendError(GraphQLError(message: errorMessage), id: id)
    }

    /// Send an error through the messenger
    private func error(_ error: GraphQLTransportWSError) {
        guard let messenger = messenger else { return }
        messenger.error(error.message, code: error.code.rawValue)
    }
}
