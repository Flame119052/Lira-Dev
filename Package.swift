// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lira",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LiraCore", targets: ["LiraCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0")
    ],
    targets: [
        .target(
            name: "LiraCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        // Test-only helper process used by CrashRecoveryTests: opens a ledger,
        // appends events in a loop, and reports progress on stdout so the test
        // can SIGKILL it mid-write at a known point. Never shipped.
        .executableTarget(
            name: "ledger-crash-probe",
            dependencies: ["LiraCore"]
        ),
        .testTarget(
            name: "LiraCoreTests",
            dependencies: [
                "LiraCore",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
