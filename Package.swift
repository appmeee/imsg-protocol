// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppMeeeIMsgProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AppMeeeIMsgCore", targets: ["AppMeeeIMsgCore"]),
        .executable(name: "appmeee-imsg-protocol", targets: ["AppMeeeIMsgProtocol"]),
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3"),
        .package(url: "https://github.com/marmelroy/PhoneNumberKit.git", from: "4.2.5"),
    ],
    targets: [
        .target(
            name: "AppMeeeIMsgCore",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            linkerSettings: [
                .linkedFramework("ScriptingBridge"),
            ]
        ),
        .executableTarget(
            name: "AppMeeeIMsgProtocol",
            dependencies: [
                "AppMeeeIMsgCore",
            ]
        ),
        .testTarget(
            name: "AppMeeeIMsgCoreTests",
            dependencies: [
                "AppMeeeIMsgCore",
            ]
        ),
    ]
)
