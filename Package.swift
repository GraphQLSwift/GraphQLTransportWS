// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "GraphQLTransportWS",
    platforms: [.macOS(.v10_15)],
    products: [
        .library(
            name: "GraphQLTransportWS",
            targets: ["GraphQLTransportWS"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/GraphQLSwift/Graphiti.git", from: "3.0.0"),
        .package(url: "https://github.com/GraphQLSwift/GraphQL.git", from: "4.0.0"),
    ],
    targets: [
        .target(
            name: "GraphQLTransportWS",
            dependencies: [
                .product(name: "Graphiti", package: "Graphiti"),
                .product(name: "GraphQL", package: "GraphQL"),
            ]
        ),
        .testTarget(
            name: "GraphQLTransportWSTests",
            dependencies: ["GraphQLTransportWS"]
        ),
    ],
    swiftLanguageVersions: [.v5, .version("6")]
)
