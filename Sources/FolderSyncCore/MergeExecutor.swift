import Foundation

/// 合并执行引擎
///
/// - 预先统一创建全部目标父目录（避免并行创建同一目录的竞态）；
/// - 并行复制（最多 4 路），适合 SSD 上的海量小文件；
/// - 目标已存在时跳过并记录（分析后文件系统又发生变化的保护措施）；
/// - 每复制一个文件上报一次进度，由 UI 侧做节流聚合；
/// - 支持随时取消，返回已完成的部分结果。
public enum MergeExecutor {

    private struct ChunkResult: Sendable {
        var cancelled = false
        var skipped: [SkippedItem] = []
        var failures: [SkippedItem] = []
    }

    public static func execute(
        plan: [PlannedCopy],
        progress: (@Sendable (Int, Int, Int, Int64) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> MergeOutcome {
        // 进度回调参数：(已复制数, 已处理数, 计划总数, 已复制字节)
        let startedAt = Date()
        let total = plan.count
        guard total > 0 else {
            return MergeOutcome(copiedCount: 0, copiedBytes: 0, skipped: [],
                                failures: [], cancelled: false, elapsedSeconds: 0)
        }

        let fm = FileManager.default

        // 1. 统一创建目标目录（按路径长度升序，保证父目录先建）
        var parentDirs = Set<String>()
        parentDirs.reserveCapacity(total)
        for item in plan {
            parentDirs.insert(item.destinationURL.deletingLastPathComponent().path)
        }
        for dir in parentDirs.sorted(by: { $0.count < $1.count }) {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        // 2. 分块并行复制
        let tally = SynchronizedTally()
        let workers = min(4, total)
        let per = max(1, (total + workers - 1) / workers)
        var chunks: [[PlannedCopy]] = []
        var i = 0
        while i < total {
            chunks.append(Array(plan[i..<min(i + per, total)]))
            i += per
        }

        let results: [ChunkResult] = try await withThrowingTaskGroup(
            of: ChunkResult.self
        ) { group in
            for chunk in chunks {
                group.addTask {
                    var result = ChunkResult()
                    for item in chunk {
                        if isCancelled() || Task.isCancelled {
                            result.cancelled = true
                            break
                        }
                        let destPath = item.destinationURL.path
                        if fm.fileExists(atPath: destPath) {
                            result.skipped.append(SkippedItem(
                                relativePath: item.relativePath,
                                reason: "目标已存在同名文件"
                            ))
                            let p = tally.addProcessed()
                            progress?(tally.copiedCount, p, total, tally.bytes)
                        } else {
                            do {
                                try fm.copyItem(at: item.sourceURL, to: item.destinationURL)
                                tally.addBytes(item.size)
                                tally.addCopied()
                                let p = tally.addProcessed()
                                progress?(tally.copiedCount, p, total, tally.bytes)
                            } catch {
                                result.failures.append(SkippedItem(
                                    relativePath: item.relativePath,
                                    reason: error.localizedDescription
                                ))
                                let p = tally.addProcessed()
                                progress?(tally.copiedCount, p, total, tally.bytes)
                            }
                        }
                    }
                    return result
                }
            }
            var collected: [ChunkResult] = []
            collected.reserveCapacity(chunks.count)
            for try await r in group { collected.append(r) }
            return collected
        }

        // 3. 汇总
        var skipped: [SkippedItem] = []
        var failures: [SkippedItem] = []
        var cancelled = false
        for r in results {
            skipped.append(contentsOf: r.skipped)
            failures.append(contentsOf: r.failures)
            cancelled = cancelled || r.cancelled
        }
        skipped.sort { $0.relativePath < $1.relativePath }
        failures.sort { $0.relativePath < $1.relativePath }

        progress?(tally.copiedCount, tally.processedCount, total, tally.bytes)
        return MergeOutcome(
            copiedCount: tally.copiedCount,
            copiedBytes: tally.bytes,
            skipped: skipped,
            failures: failures,
            cancelled: cancelled,
            elapsedSeconds: Date().timeIntervalSince(startedAt)
        )
    }
}
