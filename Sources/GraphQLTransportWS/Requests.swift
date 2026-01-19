import Foundation
import GraphQL

/// A general request. This object's type is used to triage to other, more specific request objects.
public struct Request: Equatable, JsonEncodable {
    public let type: RequestMessageType
}

/// A websocket `connection_init` request from the client to the server
public struct ConnectionInitRequest<InitPayload: Codable & Equatable>: Equatable, JsonEncodable {
    public let type: RequestMessageType = .connectionInit
    public let payload: InitPayload

    public init(payload: InitPayload) {
        self.payload = payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(RequestMessageType.self, forKey: .type) != .connectionInit {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(RequestMessageType.connectionInit.type)`"
            ))
        }
        payload = try container.decode(InitPayload.self, forKey: .payload)
    }
}

/// A websocket `subscribe` request from the client to the server
public struct SubscribeRequest: Equatable, JsonEncodable {
    public let type = RequestMessageType.subscribe
    public let payload: GraphQLRequest
    public let id: String

    public init(payload: GraphQLRequest, id: String) {
        self.payload = payload
        self.id = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(RequestMessageType.self, forKey: .type) != .subscribe {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(RequestMessageType.subscribe.type)`"
            ))
        }
        payload = try container.decode(GraphQLRequest.self, forKey: .payload)
        id = try container.decode(String.self, forKey: .id)
    }
}

/// A websocket `complete` request from the client to the server
public struct CompleteRequest: Equatable, JsonEncodable {
    public let type = RequestMessageType.complete
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(RequestMessageType.self, forKey: .type) != .complete {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(RequestMessageType.complete.type)`"
            ))
        }
        id = try container.decode(String.self, forKey: .id)
    }
}

/// The supported websocket request message types from the client to the server
public struct RequestMessageType: Equatable, Codable, Sendable {
    // This is implemented as a struct with only public static properties, backed by an internal enum
    // in order to grow the list of accepted request types in a non-breaking way.

    let type: RequestType

    init(type: RequestType) {
        self.type = type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        type = try container.decode(RequestType.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(type)
    }

    public static let connectionInit: Self = .init(type: .connectionInit)
    public static let subscribe: Self = .init(type: .subscribe)
    public static let complete: Self = .init(type: .complete)

    enum RequestType: String, Codable {
        case connectionInit = "connection_init"
        case subscribe
        case complete
    }
}
