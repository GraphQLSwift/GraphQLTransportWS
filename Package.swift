// swift-tools-version:5.4

import PackageDescription

let package = Package(
    name: "GraphQLTransportWS",
    products: [
        .library(
            name: "GraphQLTransportWS",
            targets: ["GraphQLTransportWS"]
        ),
    ],
    dependencies: [
        .package(name: "Graphiti", url: "https://github.com/GraphQLSwift/Graphiti.git", from: "1.0.0"),
        // TODO: Mainline when this PR is merged: https://github.com/GraphQLSwift/GraphQL/pull/97
        .package(name: "GraphQL", url: "https://github.com/NeedleInAJayStack/GraphQL.git", .branch("fix/GraphQLRequest")),
        .package(name: "GraphQLRxSwift", url: "https://github.com/GraphQLSwift/GraphQLRxSwift.git", from: "0.0.4"),
        .package(name: "RxSwift", url: "https://github.com/ReactiveX/RxSwift.git", from: "6.1.0"),
        .package(name: "swift-nio", url: "https://github.com/apple/swift-nio.git", .upToNextMinor(from: "2.33.0")),
    ],
    targets: [
        .target(
            name: "GraphQLTransportWS",
            dependencies: [
                .product(name: "Graphiti", package: "Graphiti"),
                .product(name: "GraphQLRxSwift", package: "GraphQLRxSwift"),
                .product(name: "GraphQL", package: "GraphQL"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "RxSwift", package: "RxSwift")
            ]),
        .testTarget(
            name: "GraphQLTransportWSTests",
            dependencies: ["GraphQLTransportWS"]
        ),
    ]
)
