import Foundation
import GraphQL

/// A general response. This object's type is used to triage to other, more specific response objects.
public struct Response: Equatable, JsonEncodable {
    public let type: ResponseMessageType
}

/// A websocket `connection_ack` response from the server to the client
public struct ConnectionAckResponse: Equatable, JsonEncodable {
    public let type: ResponseMessageType = .connectionAck
    public let payload: [String: Map]?

    public init(payload: [String: Map]? = nil) {
        self.payload = payload
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(ResponseMessageType.self, forKey: .type) != .connectionAck {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(ResponseMessageType.connectionAck.type)`"
            ))
        }
        payload = try container.decodeIfPresent([String: Map].self, forKey: .payload)
    }
}

/// A websocket `next` response from the server to the client
public struct NextResponse: Equatable, JsonEncodable {
    public let type: ResponseMessageType = .next
    public let payload: GraphQLResult?
    public let id: String

    public init(payload: GraphQLResult?, id: String) {
        self.payload = payload
        self.id = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(ResponseMessageType.self, forKey: .type) != .next {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(ResponseMessageType.next.type)`"
            ))
        }
        payload = try container.decodeIfPresent(GraphQLResult.self, forKey: .payload)
        id = try container.decode(String.self, forKey: .id)
    }
}

/// A websocket `complete` response from the server to the client
public struct CompleteResponse: Equatable, JsonEncodable {
    public let type: ResponseMessageType = .complete
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(ResponseMessageType.self, forKey: .type) != .complete {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(ResponseMessageType.complete.type)`"
            ))
        }
        id = try container.decode(String.self, forKey: .id)
    }
}

/// A websocket `error` response from the server to the client
public struct ErrorResponse: Equatable, JsonEncodable {
    public let type: ResponseMessageType = .error
    public let payload: [GraphQLError]
    public let id: String

    init(_ errors: [Error], id: String) {
        let graphQLErrors = errors.map { error -> GraphQLError in
            switch error {
            case let graphQLError as GraphQLError:
                return graphQLError
            default:
                return GraphQLError(error)
            }
        }
        payload = graphQLErrors
        self.id = id
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Self.CodingKeys.self)
        if try container.decode(ResponseMessageType.self, forKey: .type) != .error {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "type must be `\(ResponseMessageType.error.type)`"
            ))
        }
        payload = try container.decode([GraphQLError].self, forKey: .payload)
        id = try container.decode(String.self, forKey: .id)
    }
}

/// The supported websocket response message types from the server to the client
public struct ResponseMessageType: Equatable, Codable, Sendable {
    // This is implemented as a struct with only public static properties, backed by an internal enum
    // in order to grow the list of accepted response types in a non-breaking way.

    let type: ResponseType

    init(type: ResponseType) {
        self.type = type
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        type = try container.decode(ResponseType.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(type)
    }

    public static let connectionAck: Self = .init(type: .connectionAck)
    public static let next: Self = .init(type: .next)
    public static let complete: Self = .init(type: .complete)
    public static let error: Self = .init(type: .error)

    enum ResponseType: String, Codable {
        case connectionAck = "connection_ack"
        case next
        case complete
        case error
    }
}

/// A websocket `error` response from the server to the client that indicates an issue with encoding
/// a response JSON
struct EncodingErrorResponse: Equatable, Codable, JsonEncodable {
    let type: ResponseMessageType
    let payload: [String: String]

    init(_ errorMessage: String) {
        type = .error
        payload = ["error": errorMessage]
    }
}
