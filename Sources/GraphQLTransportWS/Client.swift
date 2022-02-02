// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import GraphQL

/// Client is an open-ended implementation of the client side of the protocol. It parses and adds callbacks for each type of server respose.
public class Client {
    let messenger: Messenger
    
    var onConnectionAck: (ConnectionAckResponse, Client) -> Void = { _, _ in }
    var onNext: (NextResponse, Client) -> Void = { _, _ in }
    var onError: (ErrorResponse, Client) -> Void = { _, _ in }
    var onComplete: (CompleteResponse, Client) -> Void = { _, _ in }
    var onMessage: (String, Client) -> Void = { _, _ in }
    
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
        self.messenger.onRecieve { [weak self] message in
            guard let self = self else { return }
            
            self.onMessage(message, self)
            
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
                    self.onConnectionAck(connectionAckResponse, self)
                case .next:
                    guard let nextResponse = try? self.decoder.decode(NextResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .next)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onNext(nextResponse, self)
                case .error:
                    guard let errorResponse = try? self.decoder.decode(ErrorResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .error)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onError(errorResponse, self)
                case .complete:
                    guard let completeResponse = try? self.decoder.decode(CompleteResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .complete)
                        messenger.error(error.message, code: error.code)
                        return
                    }
                    self.onComplete(completeResponse, self)
                case .unknown:
                    let error = GraphqlTransportWsError.invalidType()
                    messenger.error(error.message, code: error.code)
            }
        }
    }
    
    /// Define the callback run on receipt of a `connection_ack` message
    /// - Parameter callback: The callback to assign
    public func onConnectionAck(_ callback: @escaping (ConnectionAckResponse, Client) -> Void) {
        self.onConnectionAck = callback
    }
    
    /// Define the callback run on receipt of a `next` message
    /// - Parameter callback: The callback to assign
    public func onNext(_ callback: @escaping (NextResponse, Client) -> Void) {
        self.onNext = callback
    }
    
    /// Define the callback run on receipt of an `error` message
    /// - Parameter callback: The callback to assign
    public func onError(_ callback: @escaping (ErrorResponse, Client) -> Void) {
        self.onError = callback
    }
    
    /// Define the callback run on receipt of a `complete` message
    /// - Parameter callback: The callback to assign
    public func onComplete(_ callback: @escaping (CompleteResponse, Client) -> Void) {
        self.onComplete = callback
    }
    
    /// Define the callback run on receipt of any message
    /// - Parameter callback: The callback to assign
    public func onMessage(_ callback: @escaping (String, Client) -> Void) {
        self.onMessage = callback
    }
    
    /// Send a `connection_init` request through the messenger
    public func sendConnectionInit(payload: ConnectionInitAuth?) {
        messenger.send(
            ConnectionInitRequest(
                payload: payload
            ).toJSON(encoder)
        )
    }
    
    /// Send a `subscribe` request through the messenger
    public func sendStart(payload: GraphQLRequest, id: String) {
        messenger.send(
            SubscribeRequest(
                payload: payload,
                id: id
            ).toJSON(encoder)
        )
    }
    
    /// Send a `complete` request through the messenger
    public func sendStop(id: String) {
        messenger.send(
            CompleteRequest(
                id: id
            ).toJSON(encoder)
        )
    }
}
