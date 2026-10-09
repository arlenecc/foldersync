import Foundation

// MARK: - 数据模型

/// 单个文件的信息
public struct FileInfo: Sendable, Hashable {
    /// 相对根目录的路径，以 "/" 分隔
    public let relativePath: String
    /// 绝对路径
    public let url: URL
    /// 逻辑大小（字节）
    public let size: Int64

    public init(relativePath: String, url: URL, size: Int64) {
        self.relativePath = relativePath
        self.url = url
        self.size = size
    }
}

/// 一棵目录树的统计信息
public struct TreeStats: Sendable, Equatable {
    public let fileCount: Int
    public let totalSize: Int64

    public init(fileCount: Int, totalSize: Int64) {
        self.fileCount = fileCount
        self.totalSize = totalSize
    }
}

/// 一条待复制的合并计划项
public struct PlannedCopy: Sendable, Hashable {
    /// 相对路径（副目录与主目录中的目标路径相同）
    public let relativePath: String
    public let sourceURL: URL
    public let destinationURL: URL
    public let size: Int64

    public init(relativePath: String, sourceURL: URL, destinationURL: URL, size: Int64) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.size = size
    }
}

/// 全局排重结果（分析阶段的输出）
public struct DedupResult: Sendable {
    public let primaryStats: TreeStats
    public let secondaryStats: TreeStats
    /// 排重后需要写入主目录的文件（全局唯一、且主目录中不存在该内容）
    public let plannedCopies: [PlannedCopy]
    /// 副目录中因内容已存在于主目录而被跳过的文件数
    public let duplicatesAlreadyInPrimary: Int
    /// 副目录内部重复（同一内容多份，仅保留一份）的文件数
    public let duplicatesWithinSecondary: Int

    init(primaryStats: TreeStats,
         secondaryStats: TreeStats,
         plannedCopies: [PlannedCopy],
         duplicatesAlreadyInPrimary: Int,
         duplicatesWithinSecondary: Int) {
        self.primaryStats = primaryStats
        self.secondaryStats = secondaryStats
        self.plannedCopies = plannedCopies
        self.duplicatesAlreadyInPrimary = duplicatesAlreadyInPrimary
        self.duplicatesWithinSecondary = duplicatesWithinSecondary
    }

    /// 预计合并后的文件总数（主目录全部保留 + 新增唯一文件）
    public var estimatedMergedCount: Int {
        primaryStats.fileCount + plannedCopies.count
    }

    /// 预计合并后的总占用空间
    public var estimatedMergedSize: Int64 {
        primaryStats.totalSize + plannedBytes
    }

    /// 待复制文件的总体积
    public var plannedBytes: Int64 {
        plannedCopies.reduce(Int64(0)) { $0 + $1.size }
    }
}

/// 合并执行中跳过/失败的条目
public struct SkippedItem: Sendable {
    public let relativePath: String
    public let reason: String

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

/// 合并执行结果
public struct MergeOutcome: Sendable {
    public let copiedCount: Int
    public let copiedBytes: Int64
    public let skipped: [SkippedItem]
    public let failures: [SkippedItem]
    public let cancelled: Bool
    public let elapsedSeconds: TimeInterval
}

public enum ScanError: Error, CustomStringConvertible {
    case cannotEnumerate(URL)

    public var description: String {
        switch self {
        case .cannotEnumerate(let url):
            return "无法遍历目录：\(url.path)"
        }
    }
}

// MARK: - 同步原语（内部使用）

/// 线程安全计数器
final class SynchronizedCounter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// 线程安全字节数累计器
final class SynchronizedTally: @unchecked Sendable {
    private var copied = 0        // 实际复制成功的文件数
    private var processed = 0     // 已处理（复制+跳过+失败）的文件数
    private var _bytes: Int64 = 0
    private let lock = NSLock()

    func addCopied() -> Int {
        lock.lock(); defer { lock.unlock() }
        copied += 1
        return copied
    }

    func addProcessed() -> Int {
        lock.lock(); defer { lock.unlock() }
        processed += 1
        return processed
    }

    func addBytes(_ b: Int64) {
        lock.lock(); defer { lock.unlock() }
        _bytes += b
    }

    var bytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _bytes
    }

    var copiedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return copied
    }

    var processedCount: Int {
        lock.lock(); defer { lock.unlock() }
        return processed
    }
}
