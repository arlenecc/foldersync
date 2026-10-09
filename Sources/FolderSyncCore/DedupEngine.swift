import Foundation

/// 全局排重引擎
///
/// 核心策略（海量文件性能优化）：
/// 1. 先按文件大小分组——大小全局唯一的文件必然内容唯一，**完全跳过哈希**；
/// 2. 只有大小出现多次（跨两棵树合计 > 1）的文件才需要计算哈希；
/// 3. 相同内容的文件组中：主目录有同内容文件 → 副目录副本全部跳过；
///    否则从副目录中选取一个代表（相对路径字典序最小，保证确定性）计划复制。
/// 4. 主目录内部的重复文件不做删除（本工具是"合并"而非"清理"）。
public enum DedupEngine {

    public static func plan(
        primary: [FileInfo],
        secondary: [FileInfo],
        primaryRoot: URL,
        secondaryRoot: URL,
        hashProgress: (@Sendable (Int, Int) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> DedupResult {
        // 1. 按大小分组
        var primaryBySize: [Int64: [FileInfo]] = [:]
        var secondaryBySize: [Int64: [FileInfo]] = [:]
        primaryBySize.reserveCapacity(primary.count)
        secondaryBySize.reserveCapacity(secondary.count)
        for f in primary { primaryBySize[f.size, default: []].append(f) }
        for f in secondary { secondaryBySize[f.size, default: []].append(f) }

        // 2. 收集"大小有歧义"的文件（需要哈希比对）
        var needHash: [FileInfo] = []
        needHash.reserveCapacity(min(primary.count + secondary.count, 1 << 20))
        for f in primary
        where (primaryBySize[f.size]?.count ?? 0) + (secondaryBySize[f.size]?.count ?? 0) > 1 {
            needHash.append(f)
        }
        for f in secondary
        where (primaryBySize[f.size]?.count ?? 0) + (secondaryBySize[f.size]?.count ?? 0) > 1 {
            needHash.append(f)
        }

        let digests = try await HashEngine.hashes(
            for: needHash,
            progress: hashProgress,
            isCancelled: isCancelled
        )

        // 内容身份：已哈希的用摘要；大小全局唯一的直接用大小哨兵（无需哈希）
        func identity(of f: FileInfo) -> String {
            digests[f.url.path] ?? "size-unique|\(f.size)"
        }

        var primaryIdentities = Set<String>()
        primaryIdentities.reserveCapacity(primary.count)
        for f in primary { primaryIdentities.insert(identity(of: f)) }

        // 3. 副目录按内容身份分组，决定是否复制
        var secondaryByIdentity: [String: [FileInfo]] = [:]
        for f in secondary { secondaryByIdentity[identity(of: f), default: []].append(f) }

        var planned: [PlannedCopy] = []
        planned.reserveCapacity(secondaryByIdentity.count)
        var alreadyInPrimary = 0
        var withinSecondary = 0

        for (ident, group) in secondaryByIdentity {
            if primaryIdentities.contains(ident) {
                alreadyInPrimary += group.count
                continue
            }
            // 确定性选择代表：相对路径字典序最小
            let keeper = group.min { $0.relativePath < $1.relativePath }!
            withinSecondary += group.count - 1
            planned.append(PlannedCopy(
                relativePath: keeper.relativePath,
                sourceURL: keeper.url,
                destinationURL: primaryRoot.appendingPathComponent(keeper.relativePath),
                size: keeper.size
            ))
        }

        planned.sort { $0.relativePath < $1.relativePath }

        return DedupResult(
            primaryStats: TreeStats(
                fileCount: primary.count,
                totalSize: primary.reduce(Int64(0)) { $0 + $1.size }
            ),
            secondaryStats: TreeStats(
                fileCount: secondary.count,
                totalSize: secondary.reduce(Int64(0)) { $0 + $1.size }
            ),
            plannedCopies: planned,
            duplicatesAlreadyInPrimary: alreadyInPrimary,
            duplicatesWithinSecondary: withinSecondary
        )
    }
}
