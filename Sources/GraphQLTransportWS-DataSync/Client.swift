import Foundation
import GraphQL
import GraphQLRxSwift
import NIO
import RxSwift

/// Client is an open-ended implementation of the client side of the protocol. It parses and adds callbacks for each type of server respose.
public class Client<InitPayload: Equatable & Codable> {
    // We keep this weak because we strongly inject this object into the messenger callback
    weak var messenger: Messenger?

    var onConnectionAck: (ConnectionAckResponse, Client) -> Void = { _, _ in }
    var onNext: (NextResponse, Client) -> Void = { _, _ in }
    var onError: (ErrorResponse, Client) -> Void = { _, _ in }
    var onComplete: (CompleteResponse, Client) -> Void = { _, _ in }
    var onMessage: (String, Client) -> Void = { _, _ in }

    let disposeBag = DisposeBag()
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
        messenger.onReceive { message in
            self.onMessage(message, self)

            // Detect and ignore error responses.
            if message.starts(with: "44") {
                // TODO: Determine what to do with returned error messages
                return
            }

            let json = Data(message.utf8)

            let response: Response
            do {
                response = try self.decoder.decode(Response.self, from: json)
            }
            catch {
                self.error(.noType())
                return
            }

            switch response.type {
                case .connectionAck:
                    guard let connectionAckResponse = try? self.decoder.decode(ConnectionAckResponse.self, from: json) else {
                        self.error(.invalidResponseFormat(messageType: .connectionAck))
                        return
                    }
                    self.onConnectionAck(connectionAckResponse, self)
                case .next:
                    guard let nextResponse = try? self.decoder.decode(NextResponse.self, from: json) else {
                        self.error(.invalidResponseFormat(messageType: .next))
                        return
                    }
                    self.onNext(nextResponse, self)
                case .error:
                    guard let errorResponse = try? self.decoder.decode(ErrorResponse.self, from: json) else {
                        self.error(.invalidResponseFormat(messageType: .error))
                        return
                    }
                    self.onError(errorResponse, self)
                case .complete:
                    guard let completeResponse = try? self.decoder.decode(CompleteResponse.self, from: json) else {
                        self.error(.invalidResponseFormat(messageType: .complete))
                        return
                    }
                    self.onComplete(completeResponse, self)
                case .unknown:
                    self.error(.invalidType())
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
    public func sendConnectionInit(payload: InitPayload) {
        guard let messenger = messenger else { return }
        messenger.send(
            ConnectionInitRequest(
                payload: payload
            ).toJSON(encoder)
        )
    }

    /// Send a `subscribe` request through the messenger
    public func sendSubscribe(payload: GraphQLRequest, id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            SubscribeRequest(
                payload: payload,
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send a `complete` request through the messenger
    public func sendStop(id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            CompleteRequest(
                id: id
            ).toJSON(encoder)
        )
    }

    /// Add an observable object for this client that will fire off `Next` messages to the server as updates happen.
    /// - Parameter observable: `Observable<EventLoopFuture<GraphQLRequest>>` to subscribe to for changes.
    public func addObservableSubscription(observable: Observable<EventLoopFuture<GraphQLResult>>) {
        observable.subscribe(
            onNext: { [weak self] resultFuture in
                guard let self = self else { return }
                resultFuture.whenSuccess { result in
                    self.sendNext(payload: result, id: UUID().uuidString)
                }
                resultFuture.whenFailure { error in
                    self.error(.graphQLError(error))
                }
            }
        ).disposed(by: disposeBag)
    }

    /// Send a `next` message through the messenger.
    /// - Parameters:
    ///   - payload: `GraphQLRequest` object for the server to handle
    ///   - id: id of the message
    private func sendNext(payload: GraphQLResult, id: String) {
        guard let messenger = messenger else { return }
        messenger.send(
            NextResponse(
                payload,
                id: id
            ).toJSON(encoder)
        )
    }

    /// Send an error through the messenger and close the connection
    private func error(_ error: GraphQLTransportWSError) {
        guard let messenger = messenger else { return }
        messenger.error(error.message, code: error.code.rawValue)
    }
}
