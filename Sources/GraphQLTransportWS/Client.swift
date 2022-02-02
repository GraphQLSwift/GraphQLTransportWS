// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import GraphQL

/// Adds client-side [graphql-transport-ws protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md)
/// support, namely parsing and adding callbacks for each type of server respose.
class Client {
    let messenger: Messenger
    
    let onMessage: (String) -> Void
    let onConnectionAck: (ConnectionAckResponse) -> Void
    let onNext: (NextResponse) -> Void
    let onError: (ErrorResponse) -> Void
    let onComplete: (CompleteResponse) -> Void
    
    let encoder = GraphQLJSONEncoder()
    let decoder = JSONDecoder()
    
    /// Create a new client.
    ///
    /// - Parameters:
    ///   - onConnectionAck: callback run on receipt of a `connection_ack` message
    ///   - onNext: callback run on receipt of a `next` message
    ///   - onError: callback run on receipt of an `error` message
    ///   - onComplete: callback run on receipt of a `complete` message
    ///   - onMessage: callback run on receipt of any message   
    init(
        messenger: Messenger,
        onConnectionAck: @escaping (ConnectionAckResponse) -> Void = { _ in () },
        onNext: @escaping (NextResponse) -> Void = { _ in () },
        onError: @escaping (ErrorResponse) -> Void = { _ in () },
        onComplete: @escaping (CompleteResponse) -> Void = { _ in () },
        onMessage: @escaping (String) -> Void = { _ in () }
    ) {
        self.messenger = messenger
        self.onMessage = onMessage
        self.onConnectionAck = onConnectionAck
        self.onNext = onNext
        self.onError = onError
        self.onComplete = onComplete
        
        self.messenger.onRecieve { [weak self] message in
            guard let self = self else { return }
            
            self.onMessage(message)
            
            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }
            
            guard let json = message.data(using: .utf8) else {
                let error = GraphqlTransportWsError.invalidEncoding()
                messenger.error(error.message, code: error.code)
                return
            }
            
            let response: Response
            do {
                response = try self.decoder.decode(Response.self, from: json)
            }
            catch {
                let error = GraphqlTransportWsError.noType()
                messenger.error(error.message, code: error.code)
                return
            }
            
            switch response.type {
                case .connectionAck:
                    guard let connectionAckResponse = try? self.decoder.decode(ConnectionAckResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .connectionAck)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onConnectionAck(connectionAckResponse)
                case .next:
                    guard let nextResponse = try? self.decoder.decode(NextResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .next)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onNext(nextResponse)
                case .error:
                    guard let errorResponse = try? self.decoder.decode(ErrorResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .error)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onError(errorResponse)
                case .complete:
                    guard let completeResponse = try? self.decoder.decode(CompleteResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .complete)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onComplete(completeResponse)
                case .unknown:
                    let error = GraphqlTransportWsError.invalidType()
                    messenger.error(error.message, code: error.code)
            }
        }
    }
    
    /// Send a `connection_init` request through the messenger
    func sendConnectionInit(payload: ConnectionInitAuth?) {
        messenger.send(
            ConnectionInitRequest(
                payload: payload
            ).toJSON(encoder)
        )
    }
    
    /// Send a `subscribe` request through the messenger
    func sendStart(payload: GraphQLRequest, id: String) {
        messenger.send(
            SubscribeRequest(
                payload: payload,
                id: id
            ).toJSON(encoder)
        )
    }
    
    /// Send a `complete` request through the messenger
    func sendStop(id: String) {
        messenger.send(
            CompleteRequest(
                id: id
            ).toJSON(encoder)
        )
    }
}
