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
        // Traduction de l'interface (textes français dans le code, traductions fournies par l'app hôte).
        .target(
            name: "BaobabL10n",
            path: "Sources/BaobabL10n",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Analyse et graphiques d'occupation du disque.
        .target(
            name: "DiskUsageKit",
            dependencies: ["BaobabL10n"],
            path: "Sources/DiskUsageKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Mise à jour automatique depuis les releases GitHub (signature Ed25519).
        .target(
            name: "UpdateKit",
            dependencies: ["BaobabL10n"],
            path: "Sources/UpdateKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "iBaobab",
            dependencies: ["DiskUsageKit", "UpdateKit", "BaobabL10n"],
            path: "Sources/iBaobab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
