// swift-tools-version:5.9
import PackageDescription

// SPM-only executable (без .xcodeproj) — как в эталонном Manager Assistant.
let package = Package(
    name: "SecondBrain",
    platforms: [
        // macOS 14+: Core Audio process tap для записи системного звука (см. ARCHITECTURE.md).
        .macOS(.v14)
    ],
    dependencies: [
        // Рендер markdown в превью редактора (задача 03); та же версия, что в MA.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.0.0"),
        // Локальная транскрипция Whisper на CoreML (задача 10).
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "SecondBrain",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/SecondBrain",
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "SecondBrainTests",
            dependencies: ["SecondBrain"],
            path: "Tests/SecondBrainTests",
            resources: [
                // JSON/SSE-фикстуры реальных ответов облачных API (задача 08).
                .copy("Fixtures")
            ]
        )
    ]
)
