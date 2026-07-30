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
            // Модульные правила для кодовых агентов (задача 44): лежат рядом с кодом,
            // чтобы подхватываться автоматически, но ресурсами сборки не являются.
            exclude: [
                "Chat/CLAUDE.md",
                "Meetings/CLAUDE.md",
                "RAG/CLAUDE.md",
                "LLM/CLAUDE.md",
                "Tools/CLAUDE.md",
                "Editor/CLAUDE.md",
                "Audio/CLAUDE.md",
                "Vault/CLAUDE.md",
                "GitSync/CLAUDE.md",
                "Pipelines/CLAUDE.md",
                "LocalRuntime/CLAUDE.md",
                "MCP/CLAUDE.md",
                "FineTune/CLAUDE.md"
            ],
            resources: [
                .copy("Resources/AppIcon.icns")
            ]
        ),
        .testTarget(
            name: "SecondBrainTests",
            dependencies: ["SecondBrain"],
            path: "Tests/SecondBrainTests",
            // Правила написания тестов для агентов — не ресурс сборки (задача 44).
            exclude: ["CLAUDE.md"],
            resources: [
                // JSON/SSE-фикстуры реальных ответов облачных API (задача 08).
                .copy("Fixtures")
            ]
        )
    ]
)
