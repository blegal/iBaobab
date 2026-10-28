// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iBaobab",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "iBaobab", targets: ["iBaobab"]),
        // Bibliothèques partagées avec Enhanced File Manager.
        .library(name: "DiskUsageKit", targets: ["DiskUsageKit"]),
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
    ],
    targets: [
        // Analyse et graphiques d'occupation du disque.
        .target(
            name: "DiskUsageKit",
            path: "Sources/DiskUsageKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Mise à jour automatique depuis les releases GitHub (signature Ed25519).
        .target(
            name: "UpdateKit",
            path: "Sources/UpdateKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "iBaobab",
            dependencies: ["DiskUsageKit", "UpdateKit"],
            path: "Sources/iBaobab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
