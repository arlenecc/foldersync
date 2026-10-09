import Foundation
import Testing
@testable import FolderSyncCore

/// FolderSync 核心逻辑测试用例
///
/// 覆盖四大功能块：
/// 1. ScanEngine  —— 目录递归扫描（文件数量 / 大小 / 符号链接跳过 / 进度回调）
/// 2. HashEngine  —— 文件哈希唯一性判定
/// 3. DedupEngine —— 两个目录树之间的全局排重与合并计划
/// 4. MergeExecutor —— 合并执行（建目录 / 写入 / 跳过冲突 / 进度 / 取消）
@Suite("FolderSyncCore")
final class FolderSyncCoreTests {

    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    private var primaryDir: URL { root.appendingPathComponent("Primary") }
    private var secondaryDir: URL { root.appendingPathComponent("Secondary") }

    @discardableResult
    private func write(_ dir: URL, _ rel: String, _ content: Data) throws -> URL {
        let url = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url)
        return url
    }

    private func write(_ dir: URL, _ rel: String, _ text: String) throws -> URL {
        try write(dir, rel, Data(text.utf8))
    }

    private func scan(_ dir: URL) async throws -> [FileInfo] {
        try await ScanEngine.scan(root: dir)
    }

    private func makePlan(_ p: URL, _ s: URL) async throws -> DedupResult {
        let pf = try await scan(p)
        let sf = try await scan(s)
        return try await DedupEngine.plan(
            primary: pf, secondary: sf, primaryRoot: p, secondaryRoot: s
        )
    }

    private func readData(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    // MARK: - 1. ScanEngine 扫描

    @Test("扫描：递归统计文件数量与大小，空目录不计入")
    func scanCountsFilesRecursivelyWithSizes() async throws {
        try write(primaryDir, "a.txt", String(repeating: "a", count: 100))
        try write(primaryDir, "sub/b.txt", String(repeating: "b", count: 200))
        try write(primaryDir, "sub/deep/c.bin", Data(repeating: 0x7F, count: 300))
        try FileManager.default.createDirectory(
            at: primaryDir.appendingPathComponent("empty"), withIntermediateDirectories: true
        )

        let files = try await scan(primaryDir)

        #expect(files.count == 3)
        #expect(files.reduce(Int64(0)) { $0 + $1.size } == 600)
        let paths = Set(files.map(\.relativePath))
        #expect(paths == ["a.txt", "sub/b.txt", "sub/deep/c.bin"])
        for f in files {
            #expect(FileManager.default.fileExists(atPath: f.url.path))
            #expect(!f.relativePath.hasPrefix("/"))
        }
    }

    @Test("扫描：符号链接被跳过")
    func scanSkipsSymlinks() async throws {
        let real = try write(primaryDir, "real.txt", "hello")
        let link = primaryDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)

        let files = try await scan(primaryDir)

        #expect(files.count == 1)
        #expect(files.first?.relativePath == "real.txt")
    }

    @Test("扫描：空目录返回空列表")
    func scanEmptyDirectoryReturnsEmpty() async throws {
        try FileManager.default.createDirectory(at: primaryDir, withIntermediateDirectories: true)
        let files = try await scan(primaryDir)
        #expect(files.isEmpty)
    }

    @Test("扫描：进度回调最终值等于文件总数")
    func scanReportsProgressWithFinalCount() async throws {
        for i in 0..<10 {
            try write(primaryDir, "f\(i).txt", "x\(i)")
        }
        let box = IntBox()
        _ = try await ScanEngine.scan(root: primaryDir, progress: { box.append($0) })
        #expect(box.values.last == 10)
    }

    // MARK: - 2. HashEngine 哈希唯一性

    @Test("哈希：同内容不同路径 → 相同哈希")
    func sameContentDifferentPathsProduceSameHash() async throws {
        let f1 = try write(primaryDir, "x/one.txt", "identical content")
        let f2 = try write(secondaryDir, "y/two.txt", "identical content")

        let d1 = try HashEngine.digest(of: FileInfo(relativePath: "x/one.txt", url: f1, size: 17))
        let d2 = try HashEngine.digest(of: FileInfo(relativePath: "y/two.txt", url: f2, size: 17))

        #expect(d1 == d2)
        #expect(d1.count == 64) // SHA-256 hex
    }

    @Test("哈希：同大小不同内容 → 不同哈希")
    func differentContentSameSizeProduceDifferentHash() async throws {
        let f1 = try write(primaryDir, "a.bin", Data(repeating: 1, count: 64))
        let f2 = try write(secondaryDir, "b.bin", Data(repeating: 2, count: 64))

        let d1 = try HashEngine.digest(of: FileInfo(relativePath: "a.bin", url: f1, size: 64))
        let d2 = try HashEngine.digest(of: FileInfo(relativePath: "b.bin", url: f2, size: 64))

        #expect(d1 != d2)
    }

    @Test("哈希：大文件走分块读取路径，结果一致且能区分差异")
    func largeFileHashingUsesChunkedRead() async throws {
        let data = Data((0..<3 * 1024 * 1024).map { UInt8(truncatingIfNeeded: $0) })
        let f1 = try write(primaryDir, "big1.bin", data)
        let f2 = try write(secondaryDir, "big2.bin", data)

        let d1 = try HashEngine.digest(of: FileInfo(relativePath: "big1.bin", url: f1, size: Int64(data.count)))
        let d2 = try HashEngine.digest(of: FileInfo(relativePath: "big2.bin", url: f2, size: Int64(data.count)))
        #expect(d1 == d2)

        let f3 = try write(secondaryDir, "big3.bin", data + Data([0xFF]))
        let d3 = try HashEngine.digest(of: FileInfo(relativePath: "big3.bin", url: f3, size: Int64(data.count) + 1))
        #expect(d1 != d3)
    }

    // MARK: - 3. DedupEngine 全局排重与合并计划

    @Test("排重：两树内容相同的文件不复制")
    func fileIdenticalInBothTreesIsNotCopied() async throws {
        try write(primaryDir, "same.txt", "hello")
        try write(secondaryDir, "same.txt", "hello")
        try write(secondaryDir, "only.txt", "world")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.map(\.relativePath) == ["only.txt"])
        #expect(plan.duplicatesAlreadyInPrimary == 1)
        #expect(plan.duplicatesWithinSecondary == 0)
    }

    @Test("排重：副目录唯一文件计划写入主目录相同相对路径")
    func uniqueSecondaryFilePlannedAtSameRelativePath() async throws {
        try write(primaryDir, "p.txt", "P")
        try write(secondaryDir, "docs/readme.md", "R")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.count == 1)
        let copy = try #require(plan.plannedCopies.first)
        #expect(copy.relativePath == "docs/readme.md")
        #expect(copy.sourceURL.standardizedFileURL.path ==
                secondaryDir.appendingPathComponent("docs/readme.md").standardizedFileURL.path)
        #expect(copy.destinationURL.standardizedFileURL.path ==
                primaryDir.appendingPathComponent("docs/readme.md").standardizedFileURL.path)
        #expect(copy.size == 1)
    }

    @Test("排重：副目录内部重复只保留一份，代表路径确定（字典序最小）")
    func secondaryInternalDuplicatePlannedOnceWithDeterministicKeeper() async throws {
        try write(primaryDir, "p.txt", "P")
        try write(secondaryDir, "y/b.txt", "D")
        try write(secondaryDir, "x/a.txt", "D")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.count == 1)
        #expect(plan.plannedCopies.first?.relativePath == "x/a.txt")
        #expect(plan.duplicatesWithinSecondary == 1)
    }

    @Test("排重：同名不同内容按内容判定，计划复制")
    func sameNameDifferentContentIsPlanned() async throws {
        try write(primaryDir, "conf.txt", "old")
        try write(secondaryDir, "conf.txt", "new")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.count == 1)
        #expect(plan.plannedCopies.first?.relativePath == "conf.txt")
    }

    @Test("排重：仅主目录内部重复不影响计划、不被删除")
    func duplicateOnlyInPrimaryNothingPlanned() async throws {
        try write(primaryDir, "a.txt", "X")
        try write(primaryDir, "b/c.txt", "X")
        try write(secondaryDir, "other.txt", "Y")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.map(\.relativePath) == ["other.txt"])
    }

    @Test("排重：预估合并后统计（数量 / 空间）正确")
    func estimatedMergedStats() async throws {
        try write(primaryDir, "p1.txt", String(repeating: "1", count: 100))
        try write(primaryDir, "p2.txt", String(repeating: "2", count: 200))
        try write(secondaryDir, "dup.txt", String(repeating: "1", count: 100))   // 与主目录重复
        try write(secondaryDir, "u1.txt", String(repeating: "3", count: 300))    // 唯一
        try write(secondaryDir, "u2.txt", String(repeating: "3", count: 300))    // 副目录内部重复

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.primaryStats.fileCount == 2)
        #expect(plan.primaryStats.totalSize == 300)
        #expect(plan.secondaryStats.fileCount == 3)
        #expect(plan.secondaryStats.totalSize == 700)
        #expect(plan.plannedCopies.count == 1)
        #expect(plan.plannedBytes == 300)
        #expect(plan.duplicatesAlreadyInPrimary == 1)
        #expect(plan.duplicatesWithinSecondary == 1)
        #expect(plan.estimatedMergedCount == 3)      // 2 + 1
        #expect(plan.estimatedMergedSize == 600)     // 300 + 300
    }

    @Test("排重：空文件内容相同，参与排重")
    func emptyFilesAreDeduplicated() async throws {
        try write(primaryDir, "e1.txt", "")
        try write(secondaryDir, "e2.txt", "")
        try write(secondaryDir, "real.txt", "R")

        let plan = try await makePlan(primaryDir, secondaryDir)

        #expect(plan.plannedCopies.map(\.relativePath) == ["real.txt"])
        #expect(plan.duplicatesAlreadyInPrimary == 1)
    }

    // MARK: - 4. MergeExecutor 合并执行

    @Test("合并：自动创建缺失目录，二进制内容保真")
    func executeCreatesMissingDirectoriesAndPreservesContent() async throws {
        try write(primaryDir, "p.txt", "P")
        let binary = Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try write(secondaryDir, "deep/nested/dir/new.bin", binary)
        try write(secondaryDir, "top.txt", "T")

        let plan = try await makePlan(primaryDir, secondaryDir)
        #expect(plan.plannedCopies.count == 2)

        let outcome = try await MergeExecutor.execute(plan: plan.plannedCopies)

        #expect(!outcome.cancelled)
        #expect(outcome.copiedCount == 2)
        #expect(outcome.copiedBytes == Int64(binary.count + 1))
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.failures.isEmpty)
        #expect(try readData(primaryDir.appendingPathComponent("deep/nested/dir/new.bin")) == binary)
        #expect(try readData(primaryDir.appendingPathComponent("top.txt")) == Data("T".utf8))
    }

    @Test("合并：目标已存在同名文件时跳过，主目录文件保持不变")
    func executeSkipsExistingDestination() async throws {
        try write(primaryDir, "conf.txt", "old")
        try write(secondaryDir, "conf.txt", "new")

        let plan = try await makePlan(primaryDir, secondaryDir)
        let outcome = try await MergeExecutor.execute(plan: plan.plannedCopies)

        #expect(outcome.copiedCount == 0)
        #expect(outcome.skipped.count == 1)
        #expect(outcome.skipped.first?.relativePath == "conf.txt")
        #expect(try readData(primaryDir.appendingPathComponent("conf.txt")) == Data("old".utf8))
    }

    @Test("合并：进度回调最终值等于复制总数")
    func executeReportsProgress() async throws {
        try write(primaryDir, "p.txt", "P")
        for i in 0..<40 {
            try write(secondaryDir, "dir\(i % 4)/f\(i).txt", "content-\(i)")
        }
        let plan = try await makePlan(primaryDir, secondaryDir)

        let box = IntBox()
        let outcome = try await MergeExecutor.execute(plan: plan.plannedCopies) { copied, _, total, _ in
            box.append(copied)
            #expect(total == 40)
        }

        #expect(outcome.copiedCount == 40)
        #expect(box.values.last == 40)
    }

    @Test("合并：支持取消，返回已完成的部分结果")
    func executeSupportsCancellation() async throws {
        try write(primaryDir, "p.txt", "P")
        for i in 0..<50 {
            try write(secondaryDir, "f\(i).txt", "content-\(i)")
        }
        let plan = try await makePlan(primaryDir, secondaryDir)

        let box = IntBox()
        let outcome = try await MergeExecutor.execute(
            plan: plan.plannedCopies,
            progress: { copied, _, _, _ in box.append(copied) },
            isCancelled: { box.values.count >= 5 } // 复制 5 个后取消
        )

        #expect(outcome.cancelled)
        // 并行 worker 存在取消检查粒度：已完成检查的在途条目仍会复制完成
        #expect(outcome.copiedCount >= 5)
        #expect(outcome.copiedCount < 50)
    }

    // MARK: - 5. 端到端：扫描 → 排重 → 合并

    @Test("端到端：扫描 → 排重 → 合并，合并后实测统计与预估一致")
    func endToEndScanDedupMerge() async throws {
        // 主目录
        try write(primaryDir, "keep.txt", "K")
        try write(primaryDir, "dup.txt", "D1")
        try write(primaryDir, "photos/a.jpg", "A")
        // 副目录
        try write(secondaryDir, "dup.txt", "D1")          // 与主目录重复 → 跳过
        try write(secondaryDir, "dupe2.txt", "D1")        // 同上（也构成副目录内部重复）
        try write(secondaryDir, "notes/b.txt", "B")       // 唯一 → 复制
        try write(secondaryDir, "photos2/c.jpg", "C")     // 唯一 → 复制

        let plan = try await makePlan(primaryDir, secondaryDir)
        #expect(plan.plannedCopies.map(\.relativePath) == ["notes/b.txt", "photos2/c.jpg"])
        #expect(plan.duplicatesAlreadyInPrimary == 2)
        #expect(plan.estimatedMergedCount == 5)

        let outcome = try await MergeExecutor.execute(plan: plan.plannedCopies)
        #expect(outcome.copiedCount == 2)

        let fm = FileManager.default
        let expect: [String: String] = [
            "keep.txt": "K", "dup.txt": "D1", "photos/a.jpg": "A",
            "notes/b.txt": "B", "photos2/c.jpg": "C",
        ]
        for (rel, content) in expect {
            let url = primaryDir.appendingPathComponent(rel)
            #expect(fm.fileExists(atPath: url.path))
            #expect(try readData(url) == Data(content.utf8))
        }
        // 合并后主目录实际统计与预估一致
        let merged = try await scan(primaryDir)
        #expect(merged.count == plan.estimatedMergedCount)
        #expect(merged.reduce(Int64(0)) { $0 + $1.size } == plan.estimatedMergedSize)
    }
}

/// 线程安全的 Int 收集器，供进度回调断言使用
private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] {
        lock.lock(); defer { lock.unlock() }
        return _values
    }
    func append(_ v: Int) {
        lock.lock(); defer { lock.unlock() }
        _values.append(v)
    }
}
