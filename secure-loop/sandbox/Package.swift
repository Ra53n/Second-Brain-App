// swift-tools-version:5.9
// Скелет sandbox-пакета Дня 14: сюда харнес кладёт генерённый код (в копии out/work/).
import PackageDescription

let package = Package(
    name: "Sandbox",
    platforms: [.macOS(.v14)],
    targets: [.target(name: "Sandbox", path: "Sources/Sandbox")]
)
