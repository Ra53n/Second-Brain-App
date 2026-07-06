// swift-tools-version:5.9
import PackageDescription

// SPM-only executable (без .xcodeproj) — как в эталонном Manager Assistant.
// Внешних зависимостей пока нет: swift-markdown-ui добавит задача 03.
let package = Package(
    name: "SecondBrain",
    platforms: [
        // macOS 14+: Core Audio process tap для записи системного звука (см. ARCHITECTURE.md).
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "SecondBrain",
            path: "Sources/SecondBrain",
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "SecondBrainTests",
            dependencies: ["SecondBrain"],
            path: "Tests/SecondBrainTests"
        )
    ]
)
