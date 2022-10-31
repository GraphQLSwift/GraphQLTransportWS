import Foundation
import Graphiti
import GraphQL
import GraphQLRxSwift
import NIO
import RxSwift

var pubsub = PublishSubject<String>()

struct TestAPI: API {
    let resolver = TestResolver()
    let context = TestContext()

    // known valid
    // swiftlint:disable:next force_try
    let schema = try! Schema<TestResolver, TestContext> {
        Query {
            Field("hello", at: TestResolver.hello)
        }
        Subscription {
            SubscriptionField("hello", as: String.self, atSub: TestResolver.subscribeHello)
        }
    }
}

final class TestContext {
    func hello() -> String {
        "world"
    }
}

struct TestResolver {
    func hello(context: TestContext, arguments _: NoArguments) -> String {
        context.hello()
    }

    func subscribeHello(context _: TestContext, arguments _: NoArguments) -> EventStream<String> {
        pubsub.toEventStream()
    }
}

func testObservable(loop: EventLoop, sendAsSubscription: Bool = false) -> Observable<EventLoopFuture<GraphQLRequest>> {
    return Observable.create { observer in
        observer.on(.next(loop.makeSucceededFuture(GraphQLRequest(
            query:
            sendAsSubscription ?
                """
                subscription {
                    hello
                }
                """ :
                """
                query {
                    hello
                }
                """
        ))))
        return Disposables.create()
    }
}
