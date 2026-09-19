// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "JSONLReader",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JSONLCore"),
        .executableTarget(name: "JSONLReader", dependencies: ["JSONLCore"]),
        // Quick Look preview extension. Built as a plain executable whose entry point is NSExtensionMain; install.sh wraps it as an .appex.
        .executableTarget(
            name: "JSONLQuickLook",
            dependencies: ["JSONLCore"],
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [
                .linkedFramework("Quartz"),
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"]),
            ]),
    ]
)
