import Foundation
import GraphQL
import NIO
import RxSwift
import XCTest

@testable import GraphQLTransportWS_DataSync

final class GraphqlTransportWSTests: XCTestCase {
    var clientMessenger: TestMessenger!
    var serverMessenger: TestMessenger!
    var server: Server<TokenInitPayload>!
    var eventLoop: EventLoop!

    override func setUp() {
        // Point the client and server at each other
        clientMessenger = TestMessenger()
        serverMessenger = TestMessenger()
        clientMessenger.other = serverMessenger
        serverMessenger.other = clientMessenger
        pubsub = PublishSubject<String>()

        eventLoop = MultiThreadedEventLoopGroup(numberOfThreads: 1).next()
        let api = TestAPI()
        let context = TestContext()

        server = Server<TokenInitPayload>(
            messenger: serverMessenger,
            onExecute: { graphQLRequest in
                api.execute(
                    request: graphQLRequest.query,
                    context: context,
                    on: self.eventLoop
                )
            },
            onSubscribe: { graphQLRequest in
                api.subscribe(
                    request: graphQLRequest.query,
                    context: context,
                    on: self.eventLoop
                )
            },
            eventLoop: self.eventLoop
        )
    }

    /// Tests that trying to run methods before `connection_init` is not allowed
    func testInitialize() throws {
        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onMessage { message, _ in
            messages.append(message)
            completeExpectation.fulfill()
        }

        client.sendSubscribe(
            payload: GraphQLRequest(
                query: """
                query {
                    hello
                }
                """
            ),
            id: UUID().uuidString
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages,
            ["\(ErrorCode.notInitialized): Connection not initialized"]
        )
    }

    /// Tests that throwing in the authorization callback forces an unauthorized error
    func testAuthWithThrow() throws {
        server.auth { _ in
            throw TestError.couldBeAnything
        }

        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onMessage { message, _ in
            messages.append(message)
            completeExpectation.fulfill()
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages,
            ["\(ErrorCode.unauthorized): Unauthorized"]
        )
    }

    /// Tests that failing a future in the authorization callback forces an unauthorized error
    func testAuthWithFailedFuture() throws {
        server.auth { _ in
            self.eventLoop.makeFailedFuture(TestError.couldBeAnything)
        }

        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onMessage { message, _ in
            messages.append(message)
            completeExpectation.fulfill()
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages,
            ["\(ErrorCode.unauthorized): Unauthorized"]
        )
    }

    /// Tests a single-op conversation
    func testSingleOp() throws {
        let id = UUID().description

        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onConnectionAck { _, client in
            client.sendSubscribe(
                payload: GraphQLRequest(
                    query: """
                    query {
                        hello
                    }
                    """
                ),
                id: id
            )
        }
        client.onError { _, _ in
            completeExpectation.fulfill()
        }
        client.onComplete { _, _ in
            completeExpectation.fulfill()
        }
        client.onMessage { message, _ in
            messages.append(message)
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages.count,
            3, // 1 connection_ack, 1 next, 1 complete
            "Messages: \(messages.description)"
        )
    }

    /// Tests a streaming conversation from server to client
    func testStreamingServerClient() throws {
        let id = UUID().uuidString

        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        var dataIndex = 1
        let dataIndexMax = 3

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onConnectionAck { _, client in
            client.sendSubscribe(
                payload: GraphQLRequest(
                    query: """
                    subscription {
                        hello
                    }
                    """
                ),
                id: id
            )

            // Short sleep to allow for server to register subscription
            usleep(3000)

            pubsub.onNext("hello \(dataIndex)")
        }

        client.onNext { _, _ in
            dataIndex += 1
            if dataIndex <= dataIndexMax {
                pubsub.onNext("hello \(dataIndex)")
            }
            else {
                pubsub.onCompleted()
            }
        }
        client.onError { _, _ in
            completeExpectation.fulfill()
        }
        client.onComplete { _, _ in
            completeExpectation.fulfill()
        }
        client.onMessage { message, _ in
            messages.append(message)
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages.count,
            5, // 1 connection_ack, 3 next, 1 complete
            "Messages: \(messages.description)"
        )
    }

    /// Tests a streaming conversation where the client sends data to the server
    func testStreamingClientServer() throws {
        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onConnectionAck { _, client in
            client.addObservableSubscription(observable: testObservable(loop: self.eventLoop))
        }

        client.onError { _, _ in
            completeExpectation.fulfill()
        }

        server.onMessage { message in
            messages.append(message)
        }
        server.onNext { _, _ in
            completeExpectation.fulfill()
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages.count,
            2, // 1 connection_init, 1 next
            "Messages: \(messages.description)"
        )
    }

    /// Test a conversation where both ends are sending data at the same time
    func testBiderectionalStreaming() throws {
        let id = UUID().uuidString

        var clientMessages = [String]()
        var serverMessages = [String]()

        let clientCompleteExpectation = XCTestExpectation()
        let serverCompleteExpectation = XCTestExpectation()

        var dataIndex = 1
        let dataIndexMax = 3

        let client = Client<TokenInitPayload>(messenger: clientMessenger)
        client.onConnectionAck { _, client in
            client.sendSubscribe(
                payload: GraphQLRequest(
                    query: """
                    subscription {
                        hello
                    }
                    """
                ),
                id: id
            )

            // Short sleep to allow for server to register subscription
            usleep(3000)

            pubsub.onNext("hello \(dataIndex)")

            // Once the subscription has begun send a `next` frame from the client as well
            client.addObservableSubscription(observable: testObservable(loop: self.eventLoop))
        }

        client.onNext { _, _ in
            dataIndex += 1
            if dataIndex <= dataIndexMax {
                pubsub.onNext("hello \(dataIndex)")
            }
            else {
                pubsub.onCompleted()
            }
        }
        client.onError { _, _ in
            clientCompleteExpectation.fulfill()
        }
        client.onComplete { _, _ in
            clientCompleteExpectation.fulfill()
        }
        client.onMessage { message, _ in
            clientMessages.append(message)
        }

        server.onNext { _, _ in
            serverCompleteExpectation.fulfill()
        }
        server.onMessage { message in
            serverMessages.append(message)
        }

        client.sendConnectionInit(
            payload: TokenInitPayload(
                authToken: ""
            )
        )

        wait(for: [clientCompleteExpectation, serverCompleteExpectation], timeout: 2)
        XCTAssertEqual(
            clientMessages.count,
            5, // 1 connection_ack, 3 next, 1 complete
            "Client Messages: \(clientMessages.description)"
        )

        XCTAssertEqual(
            serverMessages.count,
            3, // 1 connection_init, 1 subscribe, 1 next
            "Server Messages: \(serverMessages.description)"
        )
    }

    func testNextUninitialized() throws {
        var messages = [String]()
        let completeExpectation = XCTestExpectation()

        let client = Client<TokenInitPayload>(messenger: clientMessenger)

        client.onMessage { message, _ in
            messages.append(message)
            completeExpectation.fulfill()
        }

        client.addObservableSubscription(observable: testObservable(loop: self.eventLoop))

        wait(for: [completeExpectation], timeout: 2)
        XCTAssertEqual(
            messages.count,
            1, // 1 error
            "Messages: \(messages.description)"
        )
        XCTAssertTrue(try XCTUnwrap(messages.last).contains(ErrorCode.notInitialized.rawValue.description))
    }

    enum TestError: Error {
        case couldBeAnything
    }
}
