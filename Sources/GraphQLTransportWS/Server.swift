// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import GraphQL
import GraphQLRxSwift
import NIO
import RxSwift

/// Adds server-side [graphql-transport-ws protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md)
/// support, namely parsing and adding callbacks for each type of client request.
class Server {
    let auth: (ConnectionInitRequest) throws -> Void
    let onExecute: (GraphQLRequest) -> EventLoopFuture<GraphQLResult>
    let onSubscribe: (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>
    let onExit: () -> Void
    let onMessage: (String) -> Void
    
    var initialized = false
    
    let disposeBag = DisposeBag()
    let encoder = GraphQLJSONEncoder()
    let decoder = JSONDecoder()
    
    init(
        auth: @escaping (ConnectionInitRequest) throws -> Void,
        onExecute: @escaping (GraphQLRequest) -> EventLoopFuture<GraphQLResult>,
        onSubscribe: @escaping (GraphQLRequest) -> EventLoopFuture<SubscriptionResult>,
        onExit: @escaping () -> Void,
        onMessage: @escaping (String) -> Void = { _ in () }
    ) {
        self.auth = auth
        self.onExecute = onExecute
        self.onSubscribe = onSubscribe
        self.onExit = onExit
        self.onMessage = onMessage
    }
    
    /// Attaches the responder to the provided Messenger in order to recieve and transmit messages
    /// - Parameter messenger: The Messenger to use for communication
    func attach(to messenger: Messenger) {
        messenger.onRecieve { message in
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
            subscribeFuture.whenSuccess { result in
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
                        guard let self = self else { return }
                        resultFuture.whenSuccess { result in
                            messenger.send(NextResponse(result, id: id).toJSON(self.encoder))
                        }
                        resultFuture.whenFailure { error in
                            messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
                        }
                    },
                    onError: { [weak self] error in
                        guard let self = self else { return }
                        messenger.send(ErrorResponse(error, id: id).toJSON(self.encoder))
                    },
                    onCompleted: { [weak self] in
                        guard let self = self else { return }
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
