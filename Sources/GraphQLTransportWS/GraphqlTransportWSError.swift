import GraphQL

struct GraphQLTransportWSError: Error {
    let message: String
    let code: ErrorCode

    init(_ message: String, code: ErrorCode) {
        self.message = message
        self.code = code
    }

    static func forbidden() -> Self {
        return self.init(
            "Forbidden",
            code: .forbidden
        )
    }

    static func notInitialized() -> Self {
        return self.init(
            "Connection not initialized",
            code: .unauthorized
        )
    }

    static func tooManyInitializations() -> Self {
        return self.init(
            "Too many initialisation requests",
            code: .tooManyRequests
        )
    }

    static func subscriberAlreadyExists(id: String) -> Self {
        return self.init(
            "Subscriber for \(id) already exists",
            code: .conflict
        )
    }

    static func invalidEncoding() -> Self {
        return self.init(
            "Message was not encoded in UTF8",
            code: .miscellaneous
        )
    }

    static func noType() -> Self {
        return self.init(
            "Message has no 'type' field",
            code: .miscellaneous
        )
    }

    static func invalidType() -> Self {
        return self.init(
            "Message 'type' value does not match supported types",
            code: .miscellaneous
        )
    }

    static func invalidRequestFormat(messageType: RequestMessageType) -> Self {
        return self.init(
            "Request message doesn't match '\(messageType.type.rawValue)' JSON format",
            code: .miscellaneous
        )
    }

    static func invalidResponseFormat(messageType: ResponseMessageType) -> Self {
        return self.init(
            "Response message doesn't match '\(messageType.type.rawValue)' JSON format",
            code: .miscellaneous
        )
    }

    static func internalAPIStreamIssue(errors: [GraphQLError]) -> Self {
        return self.init(
            "API Response did not result in a stream type, contained errors\n \(errors.map { $0.message }.joined(separator: "\n"))",
            code: .internalServerError
        )
    }
}

/// Error codes for miscellaneous issues
enum ErrorCode: Int, CustomStringConvertible, Sendable {
    /// Miscellaneous
    case miscellaneous = 4400
    case unauthorized = 4401
    case forbidden = 4403
    case conflict = 4409
    case tooManyRequests = 4429
    case internalServerError = 4500

    public var description: String {
        return "\(rawValue)"
    }
}
