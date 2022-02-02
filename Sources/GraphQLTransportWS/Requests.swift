// Copyright (c) 2021 PassiveLogic, Inc.

import Foundation
import GraphQL

/// We also require that an 'authToken' field is provided in the 'payload' during the connection
/// init message. For example:
/// ```
/// {
///     "type": 'connection_init',
///     "payload": {
///         "authToken": "eyJhbGciOiJIUz..."
///     }
/// }
/// ```

/// A general request. This object's type is used to triage to other, more specific request objects.
public struct Request: Equatable, JsonEncodable {
    let type: RequestMessageType
}

/// A websocket `connection_init` request from the client to the server
public struct ConnectionInitRequest: Equatable, JsonEncodable {
    var type = RequestMessageType.connectionInit
    public let payload: ConnectionInitAuth?
}

// TODO: Make this structure user-defined
/// Authorization format for a websocket `connection_init` request from the client to the server
public struct ConnectionInitAuth: Equatable, JsonEncodable {
    public let authToken: String
}

/// A websocket `subscribe` request from the client to the server
struct SubscribeRequest: Equatable, JsonEncodable {
    var type = RequestMessageType.subscribe
    let payload: GraphQLRequest
    let id: String
}

/// A websocket `complete` request from the client to the server
struct CompleteRequest: Equatable, JsonEncodable {
    var type = RequestMessageType.complete
    let id: String
}

/// The supported websocket request message types from the client to the server
enum RequestMessageType: String, Codable {
    case connectionInit = "connection_init"
    case subscribe
    case complete
    case unknown
    
    public init(from decoder: Decoder) throws {
        guard let value = try? decoder.singleValueContainer().decode(String.self) else {
            self = .unknown
            return
        }
        self = RequestMessageType(rawValue: value) ?? .unknown
    }
}
