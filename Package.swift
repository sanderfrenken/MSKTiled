// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MSKTiled",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MSKTiled",
            targets: ["MSKTiled"]),
    ],
    dependencies: [
//        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.56.2")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "MSKTiled"//,
//            plugins: [.plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins")]
        ),
        .testTarget(
            name: "MSKTiledTests",
            dependencies: ["MSKTiled"]),
    ]
)
