import Foundation

/// 目录树扫描引擎
///
/// 使用 FileManager.enumerator 单次遍历完成全树枚举（带资源预取），
/// 海量文件下保持低开销；符号链接一律跳过，避免重复与环。
public enum ScanEngine {

    /// 递归扫描 root 下的所有普通文件
    /// - Parameters:
    ///   - root: 根目录
    ///   - progress: 进度回调（参数为当前已发现的文件数），约每 512 个文件回调一次
    ///   - isCancelled: 外部取消检查
    public static func scan(
        root: URL,
        progress: (@Sendable (Int) -> Void)? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> [FileInfo] {
        try enumerate(root: root, progress: progress, isCancelled: isCancelled)
    }

    /// 同步枚举主体（避免在异步上下文迭代 NSEnumerator）
    private static func enumerate(
        root: URL,
        progress: (@Sendable (Int) -> Void)?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [FileInfo] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            throw ScanError.cannotEnumerate(root)
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true } // 单个条目出错时跳过并继续
        ) else {
            throw ScanError.cannotEnumerate(root)
        }

        let rootPath = root.standardizedFileURL.path
        let keySet = Set(keys) // 循环外构建，避免海量文件时每文件一次小分配
        var files: [FileInfo] = []
        files.reserveCapacity(256)
        var count = 0

        for case let url as URL in enumerator {
            if count & 0x1FF == 0 { // 每 512 个文件检查一次取消
                try Task.checkCancellation()
                if isCancelled() { throw CancellationError() }
            }
            guard let v = try? url.resourceValues(forKeys: keySet) else { continue }
            if v.isSymbolicLink == true { continue }
            guard v.isRegularFile == true else { continue }
            let size = Int64(v.fileSize ?? 0)
            files.append(FileInfo(
                relativePath: relativePath(of: url, rootPath: rootPath),
                url: url,
                size: size
            ))
            count += 1
            if count % 512 == 0 { progress?(count) }
        }

        progress?(count)
        return files
    }

    /// 计算相对根目录的路径（"/" 分隔）
    private static func relativePath(of url: URL, rootPath: String) -> String {
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath), full.count > rootPath.count else {
            return full
        }
        var rel = String(full.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }
}
