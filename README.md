# GraphQLTransportWS-DataSync

This implements the [graphql-transport-ws WebSocket subprotocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md), with the additional capability to send `GraphQLRequests` from the Client to the Server over the same websocket to support the PassiveLogic DataSync spec.

It is mainly intended for server support, but there is a client implementation included for swift projects.

Features:
- Server implementation that implements defined protocol conversations
- Client and Server types that wrap messengers
- Codable Server and Client message structures
- Custom authentication support

## DataSync Additions
This DataSync fork allows for `Next` messages to be handled by the Server with a custom `onNext` callback exposed. The server will detect incoming `Next` frames that contain `subscribe` requests and reject them with an error to avoid nesting subscriptions, but will allow handling logic for `query` and `mutation` requests.

The Client implemeneted here now also supports sending `Next` messages to the server via adding an `Observable` object, which will automatically wrap and send `Next` frames as it updates.

### Example
*The client and the server has already gone through [successful connection initialisation.](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md#successful-connection-initialisation)*
1. *Client* generates a unique ID for the following operation
2. *Client* dispatches the `Subscribe` message with the generated ID through the `id` field and the requested operation passed through the `payload` field
*All future communication is linked through this unique ID*
3. *Server* executes the streaming GraphQL operation
4. *Server* checks if the generated ID is unique across active streaming subscriptions
    - If not unique, the server will close the socket with the event `4409: Subscriber for <generated-id> already exists`
    If unique, continue...
5. *Server* optionally checks if the operation is valid before starting executing it, e.g. checking permissions
    - If not valid, the server sends an `Error` message and deems the operation complete.
    If valid, continue...
6. *Server* & *Client* dispatch results over time with the `Next` message
    - *Server* & *Client* handle received `Next` messages with their respectively defined callbacks. All Context is assumed to be the same between the two and is established in step 3 when the subscription is created.
7. The operation completes as described in [the `graphql-transport-ws` protocol](https://github.com/enisdenjo/graphql-ws/blob/master/PROTOCOL.md#streaming-operation)

## Usage

To use this package, include it in your `Package.swift` dependencies:

```swift
.package(url: "git@gitlab.com:PassiveLogic/platform/GraphQLTransportWS.git", from: "<version>")
```

Then create a class to implement the `Messenger` protocol. Here's an example using
[`WebSocketKit`](https://github.com/vapor/websocket-kit):

```swift
import WebSocketKit
import GraphQLTransportWS

/// Messenger wrapper for WebSockets
class WebSocketMessenger: Messenger {
    private weak var websocket: WebSocket?
    private var onReceive: (String) -> Void = { _ in }
    
    init(websocket: WebSocket) {
        self.websocket = websocket
        websocket.onText { _, message in
            self.onReceive(message)
        }
    }
    
    func send<S>(_ message: S) where S: Collection, S.Element == Character {
        guard let websocket = websocket else { return }
        websocket.send(message)
    }
    
    func onReceive(callback: @escaping (String) -> Void) {
        self.onReceive = callback
    }
    
    func error(_ message: String, code: Int) {
        guard let websocket = websocket else { return }
        websocket.send("\(code): \(message)")
    }
    
    func close() {
        guard let websocket = websocket else { return }
        _ = websocket.close()
    }
}
```

Next create a `Server`, provide the messenger you just defined, and wrap the API `execute` and `subscribe` commands:

```swift
routes.webSocket(
    "graphqlSubscribe",
    onUpgrade: { request, websocket in
        let messenger = WebSocketMessenger(websocket: websocket)
        let server = GraphQLTransportWS.Server<EmptyInitPayload?>(
            messenger: messenger,
            onExecute: { graphQLRequest in
                api.execute(
                    request: graphQLRequest.query,
                    context: context,
                    on: self.eventLoop,
                    variables: graphQLRequest.variables,
                    operationName: graphQLRequest.operationName
                )
            },
            onSubscribe: { graphQLRequest in
                api.subscribe(
                    request: graphQLRequest.query,
                    context: context,
                    on: self.eventLoop,
                    variables: graphQLRequest.variables,
                    operationName: graphQLRequest.operationName
                )
            }
        )
    }
)
```

You can also Create a client and add an observable callback to send data back to the server:
```swift
let messenger = WebSocketMessenger(websocket: websocket)
let client = Client<EmptyInitPayload>(messenger: messenger)

// add an observable to the client that will automatically send `Next` frames to the server as it updates
client.addObservable(observable: 
    Observable.create { observer in
    // Some simple obsererver that fulfills every future with the same query. Your observer can be much more complex.
    observer.on(.next(loop.makeSucceededFuture(GraphQLRequest(
            query:
                """
                query {
                    hello
                }
                """
        ))))
        return Disposables.create()
    }
)
```

### Authentication

This package exposes authentication hooks on the `connection_init` message. To perform custom authentication,
provide a codable type to the Server init and define an `auth` callback on the server. For example:

```swift
struct UsernameAndPasswordInitPayload: Equatable & Codable {
    let username: String
    let password: String
}

let server = GraphQLTransportWS.Server<UsernameAndPasswordInitPayload>(
    messenger: messenger,
    onExecute: { ... },
    onSubscribe: { ... }
)
server.auth { payload in
    guard payload.username == "admin" else {
        throw Abort(.unauthorized)
    }
}
```

This example would require `connection_init` message from the client to look like this:

```json
{
    "type": "connection_init",
    "payload": {
        "username": "admin",
        "password": "supersafe"
    }
}
```

If the `payload` field is not required on your server, you may make Server's generic declaration optional like `Server<Payload?>`

## Memory Management

Memory ownership among the Server, Client, and Messenger may seem a little backwards. This is because the Swift/Vapor WebSocket 
implementation persists WebSocket objects long after their callback and they are expected to retain strong memory references to the 
objects required for responses. In order to align cleanly and avoid memory cycles, Server and Client are injected strongly into Messenger
callbacks, and only hold weak references to their Messenger. This means that Messenger objects (or their enclosing WebSocket) must
be persisted to have the connected Server or Client objects function. That is, if a Server's Messenger falls out of scope and deinitializes,
the Server will no longer respond to messages.
