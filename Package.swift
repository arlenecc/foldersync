// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FolderSync",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // 核心逻辑库：扫描 / 哈希 / 排重 / 合并执行（可独立测试）
        .target(name: "FolderSyncCore"),
        // SwiftUI 图形界面
        .executableTarget(
            name: "FolderSync",
            dependencies: ["FolderSyncCore"]
        ),
        // 核心逻辑测试
        .testTarget(
            name: "FolderSyncCoreTests",
            dependencies: ["FolderSyncCore"]
        ),
    ],
    // 保持 Swift 5 语言模式（宽松并发检查）
    swiftLanguageModes: [.v5]
)
