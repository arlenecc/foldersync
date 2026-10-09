import CryptoKit
import Foundation

/// 文件内容哈希引擎
///
/// 性能策略（针对海量文件）：
/// - 小文件（≤1MiB）整读一次直接计算；
/// - 大文件以 1MiB 为块增量计算 SHA-256，常量内存；
/// - 多线程 TaskGroup 并行，worker 数 = CPU 核心数；
/// - 文件分块处理，避免单个巨型数组调度不均。
enum HashEngine {

    private static let chunkSize = 1 << 20 // 1 MiB
    private static let oneShotLimit = 1 << 20

    /// 计算单个文件的 SHA-256（十六进制小写）
    static func digest(of file: FileInfo) throws -> String {
        if file.size <= oneShotLimit {
            let data = try Data(contentsOf: file.url)
            return SHA256.hash(data: data).hexString
        }
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var hasher = SHA256()
        // 每 1MiB 检查一次取消，超大文件（百 GB 级）也能及时中断
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// 并行计算一组文件的哈希
    /// - Returns: 以文件绝对路径为键、十六进制摘要为值的字典
    static func hashes(
        for files: [FileInfo],
        progress: (@Sendable (Int, Int) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [String: String] {
        guard !files.isEmpty else { return [:] }

        let total = files.count
        let counter = SynchronizedCounter()
        let workers = max(1, min(ProcessInfo.processInfo.activeProcessorCount, total))
        let batchCount = min(total, workers * 4)
        let per = max(1, (total + batchCount - 1) / batchCount)

        var chunks: [[FileInfo]] = []
        chunks.reserveCapacity(batchCount)
        var index = 0
        while index < total {
            chunks.append(Array(files[index..<min(index + per, total)]))
            index += per
        }

        // 直接累积到最终字典，避免"部分结果数组 + 合并副本"造成的双倍峰值内存
        var result: [String: String] = [:]
        result.reserveCapacity(total)

        try await withThrowingTaskGroup(of: [String: String].self) { group in
            for chunk in chunks {
                group.addTask {
                    var out: [String: String] = [:]
                    out.reserveCapacity(chunk.count)
                    for f in chunk {
                        try Task.checkCancellation()
                        if isCancelled() { throw CancellationError() }
                        out[f.url.path] = try digest(of: f)
                        let done = counter.increment()
                        if done % 64 == 0 || done == total { progress?(done, total) }
                    }
                    return out
                }
            }
            for try await part in group { result.merge(part) { _, new in new } }
        }

        progress?(total, total)
        return result
    }
}

extension SHA256.Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
