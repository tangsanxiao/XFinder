// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "XFinder",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "XFinder", targets: ["XFinder"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.8.0")
    ],
    targets: [
        .executableTarget(
            name: "XFinder",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ],
            path: "Sources/XFinder"
        ),
        .testTarget(
            name: "XFinderTests",
            dependencies: ["XFinder"],
            path: "Tests/XFinderTests"
        )
    ]
)
