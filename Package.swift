// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "FinderAI",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "FinderAICore", targets: ["FinderAICore"]),
        .library(name: "FinderAIApp", targets: ["FinderAIApp"]),
        .executable(name: "FinderAIWorkspace", targets: ["FinderAIWorkspace"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.4"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "48a471ab313e858258ab0b9b0bf2cea55a50cefb"
        )
    ],
    targets: [
        .target(
            name: "FinderAICore"
        ),
        .target(
            name: "FinderAIApp",
            dependencies: [
                "FinderAICore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/FinderAI"
        ),
        .executableTarget(
            name: "FinderAIWorkspace",
            dependencies: ["FinderAIApp"],
            path: "Sources/FinderAIWorkspaceMain"
        ),
        .testTarget(
            name: "FinderAICoreTests",
            dependencies: [
                "FinderAICore",
                .product(name: "Testing", package: "swift-testing"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        ),
        .testTarget(
            name: "FinderAIAppTests",
            dependencies: [
                "FinderAIApp",
                "FinderAICore",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
