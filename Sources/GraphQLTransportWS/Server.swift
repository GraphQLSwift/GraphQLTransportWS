// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import GraphQL
import GraphQLRxSwift
import NIO
import RxSwift

/// Server implements the server-side portion of the protocol, allowing a few callbacks for customization.
public class Server {
    // We keep this weak because we strongly inject this object into the messenger callback
    weak var messenger: Messenger?
    
    let onExecute: (GraphQLRequest) -> EventLoopFuture<GraphQLResult>
    let onSubscribe: (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>
    
    var auth: (ConnectionInitRequest) throws -> Void = { _ in }
    var onExit: () -> Void = { }
    var onMessage: (String) -> Void = { _ in }
    
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
    ///   - onExit: Callback run when the communication is shut down, either by the client or server
    ///   - onMessage: callback run on receipt of any message
    public init(
        messenger: Messenger,
        onExecute: @escaping (GraphQLRequest) -> EventLoopFuture<GraphQLResult>,
        onSubscribe: @escaping (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>
    ) {
        self.messenger = messenger
        self.onExecute = onExecute
        self.onSubscribe = onSubscribe
        
        messenger.onRecieve { message in
            guard let messenger = self.messenger else { return }
            
            self.onMessage(message)
            
            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }
            
            guard let data = message.data(using: .utf8) else {
                let error = GraphqlTransportWsError.invalidEncoding()
                messenger.error(error.message, code: error.code)
                return
            }
            
            let request: Request
            do {
                request = try self.decoder.decode(Request.self, from: data)
            }
            catch {
                let error = GraphqlTransportWsError.noType()
                messenger.error(error.message, code: error.code)
                return
            }
            
            switch request.type {
                case .connectionInit:
                    guard let connectionInitRequest = try? self.decoder.decode(ConnectionInitRequest.self, from: data) else {
                        let error = GraphqlTransportWsError.invalidRequestFormat(messageType: .connectionInit)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onConnectionInit(connectionInitRequest, messenger)
                case .subscribe:
                    guard let subscribeRequest = try? self.decoder.decode(SubscribeRequest.self, from: data) else {
                        let error = GraphqlTransportWsError.invalidRequestFormat(messageType: .subscribe)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onSubscribe(subscribeRequest, messenger)
                case .complete:
                    guard let completeRequest = try? self.decoder.decode(CompleteRequest.self, from: data) else {
                        let error = GraphqlTransportWsError.invalidRequestFormat(messageType: .complete)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onComplete(completeRequest, messenger)
                case .unknown:
                    let error = GraphqlTransportWsError.invalidType()
                    messenger.error(error.message, code: error.code)
            }
        }
        
        // Clean up any uncompleted subscriptions
        // TODO: Re-enable this
        //        messenger.onClose {
        //            _ = self.context?.cleanupSubscription()
        //        }
    }
    
    /// Define the callback run during `connection_init` resolution that allows authorization using the `payload`.
    /// Throw to indicate that authorization has failed.    /// - Parameter callback: The callback to assign
    public func auth(_ callback: @escaping (ConnectionInitRequest) throws -> Void) {
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
    
    private func onConnectionInit(_ connectionInitRequest: ConnectionInitRequest, _ messenger: Messenger) {
        guard !initialized else {
            let error = GraphqlTransportWsError.tooManyInitializations()
            messenger.error(error.message, code: error.code)
            return
        }
        
        do {
            try self.auth(connectionInitRequest)
        }
        catch {
            let error = GraphqlTransportWsError.unauthorized()
            messenger.error(error.message, code: error.code)
            return
        }
        initialized = true
        messenger.send(
            ConnectionAckResponse().toJSON(encoder)
        )
    }
    
    private func onSubscribe(_ subscribeRequest: SubscribeRequest, _ messenger: Messenger) {
        guard initialized else {
            let error = GraphqlTransportWsError.notInitialized()
            messenger.error(error.message, code: error.code)
            return
        }
        
        let id = subscribeRequest.id
        let graphQLRequest = subscribeRequest.payload
        
        var isStreaming = false
        do {
            isStreaming = try graphQLRequest.isSubscription()
        }
        catch {
            messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
            return
        }
        
        if isStreaming {
            let subscribeFuture = onSubscribe(graphQLRequest)
            subscribeFuture.whenSuccess { [weak self] result in
                guard let self = self, let messenger = self.messenger else { return }
                guard let streamOpt = result.stream else {
                    // API issue - subscribe resolver isn't stream
                    let error = GraphqlTransportWsError.internalAPIStreamIssue()
                    messenger.error(error.message, code: error.code)
                    return
                }
                let stream = streamOpt as! ObservableSubscriptionEventStream
                let observable = stream.observable
                
                observable.subscribe(
                    onNext: { [weak self] resultFuture in
                        guard let self = self, let messenger = self.messenger else { return }
                        resultFuture.whenSuccess { result in
                            messenger.send(NextResponse(result, id: id).toJSON(self.encoder))
                        }
                        resultFuture.whenFailure { error in
                            messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
                        }
                    },
                    onError: { [weak self] error in
                        guard let self = self, let messenger = self.messenger else { return }
                        messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
                    },
                    onCompleted: { [weak self] in
                        guard let self = self, let messenger = self.messenger else { return }
                        messenger.send(CompleteResponse(id: id).toJSON(self.encoder))
                        _ = messenger.close()
                    }
                ).disposed(by: self.disposeBag)
            }
            subscribeFuture.whenFailure { error in
                let error = GraphqlTransportWsError.graphQLError(error)
                _ = messenger.error(error.message, code: error.code)
            }
        }
        else {
            let executeFuture = onExecute(graphQLRequest)
            executeFuture.whenSuccess { result in
                messenger.send(NextResponse(result, id: id).toJSON(self.encoder))
                messenger.send(CompleteResponse(id: id).toJSON(self.encoder))
            }
            executeFuture.whenFailure { error in
                messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
                messenger.send(CompleteResponse(id: id).toJSON(self.encoder))
            }
        }
    }
    
    private func onComplete(_: CompleteRequest, _ messenger: Messenger) {
        guard initialized else {
            let error = GraphqlTransportWsError.notInitialized()
            messenger.error(error.message, code: error.code)
            return
        }
        onExit()
    }
}
