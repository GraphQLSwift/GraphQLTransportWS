import Foundation
import GraphQL

/// A general response. This object's type is used to triage to other, more specific response objects.
struct Response: Equatable, JsonEncodable {
    let type: ResponseMessageType
}

/// A websocket `connection_ack` response from the server to the client
public struct ConnectionAckResponse: Equatable, JsonEncodable {
    let type: ResponseMessageType
    public let payload: [String: Map]?

    init(_ payload: [String: Map]? = nil) {
        self.type = .connectionAck
        self.payload = payload
    }
}

/// A websocket `next` response from the server to the client
public struct NextResponse: Equatable, JsonEncodable {
    public enum UpdateType: String, JsonEncodable {
        case flatGraphDiff
        case recordUpdate
    }

    let type: ResponseMessageType
    public let payload: GraphQLResult?
    public let id: String

    /// An addition for datasync, optionally marking this next message as a set of FlatGraphDiffs or a record update. This allows for easier decoding. Optional to allow for the base protocol to still work as expected for Next messages.
    public let updateType: UpdateType?

    init(_ payload: GraphQLResult? = nil, id: String, updateType: UpdateType? = .flatGraphDiff) {
        self.type = .next
        self.payload = payload
        self.id = id
        self.updateType = updateType
    }
}

/// A websocket `complete` response from the server to the client
public struct CompleteResponse: Equatable, JsonEncodable {
    let type: ResponseMessageType
    public let id: String

    init(id: String) {
        self.type = .complete
        self.id = id
    }
}

/// A websocket `error` response from the server to the client
public struct ErrorResponse: Equatable, JsonEncodable {
    let type: ResponseMessageType
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
        self.type = .error
        self.payload = graphQLErrors
        self.id = id
    }
}

/// The supported websocket response message types from the server to the client
enum ResponseMessageType: String, Codable {
    case connectionAck = "connection_ack"
    case next
    case error
    case complete
    case unknown

    init(from decoder: Decoder) throws {
        guard let value = try? decoder.singleValueContainer().decode(String.self) else {
            self = .unknown
            return
        }
        self = ResponseMessageType(rawValue: value) ?? .unknown
    }
}

/// A websocket `error` response from the server to the client that indicates an issue with encoding
/// a response JSON
struct EncodingErrorResponse: Equatable, Codable, JsonEncodable {
    let type: ResponseMessageType
    let payload: [String: String]

    init(_ errorMessage: String) {
        self.type = .error
        self.payload = ["error": errorMessage]
    }
}
