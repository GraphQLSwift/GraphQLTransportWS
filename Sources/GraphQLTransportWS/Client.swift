// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation

/// Adds client-side [graphql-transport-ws protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md)
/// support, namely parsing and adding callbacks for each type of server respose.
class Client {
    let onMessage: (String) -> Void
    let onConnectionAck: (ConnectionAckResponse) -> Void
    let onNext: (NextResponse) -> Void
    let onError: (ErrorResponse) -> Void
    let onComplete: (CompleteResponse) -> Void
    
    let decoder = JSONDecoder()
    
    /// Create a new client.
    ///
    /// - Parameters:
    ///   - onMessage: callback run on receipt of any message
    ///   - onConnectionAck: callback run on receipt of a `connection_ack` message
    ///   - onNext: callback run on receipt of a `next` message
    ///   - onError: callback run on receipt of an `error` message
    ///   - onComplete: callback run on receipt of a `complete` message
    init(
        onMessage: @escaping (String) -> Void = { _ in () },
        onConnectionAck: @escaping (ConnectionAckResponse) -> Void = { _ in () },
        onNext: @escaping (NextResponse) -> Void = { _ in () },
        onError: @escaping (ErrorResponse) -> Void = { _ in () },
        onComplete: @escaping (CompleteResponse) -> Void = { _ in () }
    ) {
        self.onMessage = onMessage
        self.onConnectionAck = onConnectionAck
        self.onNext = onNext
        self.onError = onError
        self.onComplete = onComplete
    }
    
    func attach(to messenger: Messenger) {
        messenger.onRecieve { message in
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
}

extension Messenger {
    /// - Parameters:
    ///   - onMessage: callback run on receipt of any message
    ///   - onConnectionAck: callback run on receipt of a `connection_ack` message
    ///   - onNext: callback run on receipt of a `next` message
    ///   - onError: callback run on receipt of an `error` message
    ///   - onComplete: callback run on receipt of a `complete` message
    func graphQLTransportWSClient(
        onMessage: @escaping (String) -> Void = { _ in () },
        onConnectionAck: @escaping (ConnectionAckResponse) -> Void = { _ in () },
        onNext: @escaping (NextResponse) -> Void = { _ in () },
        onError: @escaping (ErrorResponse) -> Void = { _ in () },
        onComplete: @escaping (CompleteResponse) -> Void = { _ in () }
    ) {
        let decoder = JSONDecoder()
        
        self.onRecieve { message in
            onMessage(message)
            
            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }
            
            guard let json = message.data(using: .utf8) else {
                let error = GraphqlTransportWsError.invalidEncoding()
                self.error(error.message, code: error.code)
                return
            }
            
            let response: Response
            do {
                response = try decoder.decode(Response.self, from: json)
            }
            catch {
                let error = GraphqlTransportWsError.noType()
                self.error(error.message, code: error.code)
                return
            }
            
            switch response.type {
                case .connectionAck:
                    guard let connectionAckResponse = try? decoder.decode(ConnectionAckResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .connectionAck)
                        self.error(error.message, code: error.code)
                        return
                    }
                    onConnectionAck(connectionAckResponse)
                case .next:
                    guard let nextResponse = try? decoder.decode(NextResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .next)
                        self.error(error.message, code: error.code)
                        return
                    }
                    onNext(nextResponse)
                case .error:
                    guard let errorResponse = try? decoder.decode(ErrorResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .error)
                        self.error(error.message, code: error.code)
                        return
                    }
                    onError(errorResponse)
                case .complete:
                    guard let completeResponse = try? decoder.decode(CompleteResponse.self, from: json) else {
                        let error = GraphqlTransportWsError.invalidResponseFormat(messageType: .complete)
                        self.error(error.message, code: error.code)
                        return
                    }
                    onComplete(completeResponse)
                case .unknown:
                    let error = GraphqlTransportWsError.invalidType()
                    self.error(error.message, code: error.code)
            }
        }
    }
}
