import AppKit
import FolderSyncCore
import Foundation

/// UI 侧进度回调节流器：高频回调（百万文件级）只按时间窗跳到主线程刷新，避免界面卡顿
private final class Pulse: @unchecked Sendable {
    private var last: CFAbsoluteTime = 0
    private let lock = NSLock()

    func allow(_ interval: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - last >= interval else { return false }
        last = now
        return true
    }
}

@MainActor
final class AppModel: ObservableObject {

    enum Phase: Equatable {
        case idle, scanning, hashing, analyzed, merging, finished, failed(String)

        var isBusy: Bool { self == .scanning || self == .hashing || self == .merging }
    }

    struct LogEntry: Identifiable, Equatable {
        let id: Int
        let text: String
        let isError: Bool
    }

    // MARK: - Published 状态

    @Published var primaryURL: URL?
    @Published var secondaryURL: URL?
    @Published var phase: Phase = .idle
    @Published var primaryStats: TreeStats?
    @Published var secondaryStats: TreeStats?
    /// 待合并文件数（排重结果，显示在“开始合并”按钮左侧）
    @Published var planCount = 0
    @Published var plannedBytes: Int64 = 0
    @Published var estimatedCount = 0
    @Published var estimatedSize: Int64 = 0
    /// 底部状态栏总进度（nil = 不确定进度）
    @Published var overallProgress: Double?
    @Published var statusText = "请选择主目录与副目录，然后点击“开始分析”。"
    @Published var logEntries: [LogEntry] = []

    private(set) var dedupResult: DedupResult?

    private var analysisTask: Task<Void, Never>?
    private var mergeTask: Task<Void, Never>?
    private var logCounter = 0
    private var lastMilestonePercent = 0
    /// 各树扫描里程碑日志的已记录文件数
    private var scanLogMilestones: [String: Int] = [:]
    /// 哈希阶段已记录的里程碑百分比
    private var hashLogMilestonePercent = 0
    private let maxLogEntries = 500

    // MARK: - 派生状态

    var directoryConflict: Bool {
        guard let p = primaryURL, let s = secondaryURL else { return false }
        // 解析符号链接后比较，识别 /tmp/x 与 /private/tmp/x 这类同一目录
        let pResolved = (p.path as NSString).resolvingSymlinksInPath
        let sResolved = (s.path as NSString).resolvingSymlinksInPath
        return pResolved == sResolved
    }

    var canStartAnalysis: Bool {
        primaryURL != nil && secondaryURL != nil && !phase.isBusy && !directoryConflict
    }

    var canStartMerge: Bool { phase == .analyzed }

    // MARK: - 日志

    private func log(_ text: String, isError: Bool = false) {
        logCounter += 1
        logEntries.append(LogEntry(id: logCounter, text: text, isError: isError))
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    private func clearLogs() {
        logEntries.removeAll()
    }

    // MARK: - 目录选择

    func chooseDirectory(isPrimary: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = isPrimary ? primaryURL : secondaryURL
        panel.message = isPrimary ? "选择主目录（合并目标，其目录结构优先）" : "选择副目录（来源）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if isPrimary { primaryURL = url } else { secondaryURL = url }
        if !phase.isBusy { resetResults() }
    }

    private func resetResults() {
        dedupResult = nil
        primaryStats = nil
        secondaryStats = nil
        planCount = 0
        plannedBytes = 0
        estimatedCount = 0
        estimatedSize = 0
        overallProgress = nil
        phase = .idle
        scanLogMilestones.removeAll()
        hashLogMilestonePercent = 0
        clearLogs()
        statusText = "请选择主目录与副目录，然后点击“开始分析”。"
    }

    // MARK: - 分析

    func startAnalysis() {
        guard canStartAnalysis, let p = primaryURL, let s = secondaryURL else { return }
        analysisTask?.cancel()
        analysisTask = Task { await runAnalysis(primary: p, secondary: s) }
    }

    private func runAnalysis(primary: URL, secondary: URL) async {
        resetResults()
        phase = .scanning
        statusText = "正在扫描…"
        log("—— 开始分析 ——")
        log("主目录: \(primary.path)")
        log("副目录: \(secondary.path)")

        do {
            // 1. 并发扫描两棵目录树
            let scanStarted = Date()
            let primaryPulse = Pulse()
            let secondaryPulse = Pulse()
            async let primaryFiles = ScanEngine.scan(root: primary, progress: { count in
                guard primaryPulse.allow(0.15) else { return }
                let c = count
                Task { @MainActor [weak self] in self?.scanTick(tree: "主目录", count: c) }
            })
            async let secondaryFiles = ScanEngine.scan(root: secondary, progress: { count in
                guard secondaryPulse.allow(0.15) else { return }
                let c = count
                Task { @MainActor [weak self] in self?.scanTick(tree: "副目录", count: c) }
            })
            let (pFiles, sFiles) = try await (primaryFiles, secondaryFiles)

            primaryStats = TreeStats(fileCount: pFiles.count,
                                     totalSize: pFiles.reduce(Int64(0)) { $0 + $1.size })
            secondaryStats = TreeStats(fileCount: sFiles.count,
                                       totalSize: sFiles.reduce(Int64(0)) { $0 + $1.size })
            log(String(
                format: "扫描完成（%.1f 秒）：主目录 %d 个文件 / %@，副目录 %d 个文件 / %@",
                Date().timeIntervalSince(scanStarted),
                pFiles.count, formatBytes(primaryStats?.totalSize ?? 0),
                sFiles.count, formatBytes(secondaryStats?.totalSize ?? 0)
            ))

            // 2. 全局排重（内部按需计算哈希）
            phase = .hashing
            overallProgress = 0
            statusText = "正在排重…"
            let hashPulse = Pulse()
            let result = try await DedupEngine.plan(
                primary: pFiles,
                secondary: sFiles,
                primaryRoot: primary,
                secondaryRoot: secondary,
                hashProgress: { done, total in
                    guard hashPulse.allow(0.15) else { return }
                    let d = done, t = total
                    Task { @MainActor [weak self] in self?.hashTick(done: d, total: t) }
                }
            )

            dedupResult = result
            planCount = result.plannedCopies.count
            plannedBytes = result.plannedBytes
            estimatedCount = result.estimatedMergedCount
            estimatedSize = result.estimatedMergedSize
            // 进度条清空待命：满格易被误解为"已合并完成"，合并阶段会重新从 0 开始
            overallProgress = nil
            phase = .analyzed
            statusText = planCount == 0
                ? "分析完成：副目录中没有需要合并的新文件。"
                : "分析完成：待合并 \(planCount) 个文件 / \(formatBytes(plannedBytes))。"
            log("排重完成：副目录与主目录内容重复 \(result.duplicatesAlreadyInPrimary) 个；副目录内部重复 \(result.duplicatesWithinSecondary) 个（仅保留一份）。")
            log("计划写入主目录 \(planCount) 个文件 / \(formatBytes(plannedBytes))。")
            log("预计合并后：\(estimatedCount) 个文件 / \(formatBytes(estimatedSize))。")
            for item in result.plannedCopies.prefix(50) {
                log("  待复制: \(item.relativePath)")
            }
            if planCount > 50 {
                log("  …（其余 \(planCount - 50) 条略，合并时全部处理）")
            }
        } catch is CancellationError {
            phase = .idle
            overallProgress = nil
            statusText = "分析已取消。"
            log("分析已取消。", isError: true)
        } catch {
            phase = .failed(error.localizedDescription)
            overallProgress = nil
            statusText = "分析失败：\(error.localizedDescription)"
            log("分析失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func scanTick(tree: String, count: Int) {
        guard phase == .scanning else { return }
        statusText = "正在扫描\(tree)… 已发现 \(count) 个文件"
        // 长扫描时给日志区一个活性心跳：每 5 万文件记录一次
        let last = scanLogMilestones[tree] ?? 0
        if count >= last + 50_000 {
            scanLogMilestones[tree] = count - count % 50_000
            log("已扫描\(tree) \(scanLogMilestones[tree]!) 个文件…")
        }
    }

    private func hashTick(done: Int, total: Int) {
        guard phase == .hashing else { return }
        overallProgress = total > 0 ? Double(done) / Double(total) : nil
        statusText = "正在计算哈希… \(done)/\(total)"
        let percent = total > 0 ? Int(Double(done) / Double(total) * 100) : 100
        if percent >= hashLogMilestonePercent + 25 {
            hashLogMilestonePercent = min(percent - percent % 25, 100)
            log("哈希进度 \(hashLogMilestonePercent)%（\(done)/\(total)）…")
        }
    }

    // MARK: - 合并

    func startMerge() {
        guard canStartMerge, let result = dedupResult else { return }
        mergeTask?.cancel()
        mergeTask = Task { await runMerge(result: result) }
    }

    private func runMerge(result: DedupResult) async {
        phase = .merging
        overallProgress = 0
        lastMilestonePercent = 0
        statusText = "正在合并…"
        log("—— 开始合并：共 \(result.plannedCopies.count) 个文件待写入主目录 ——")

        let pulse = Pulse()
        do {
            let outcome = try await MergeExecutor.execute(
                plan: result.plannedCopies,
                progress: { copied, processed, total, bytes in
                    guard pulse.allow(0.12) else { return }
                    let c = copied, p = processed, t = total, b = bytes
                    Task { @MainActor [weak self] in self?.mergeTick(copied: c, processed: p, total: t, bytes: b) }
                },
                isCancelled: { Task.isCancelled }
            )

            if outcome.cancelled {
                phase = .analyzed
                overallProgress = result.plannedCopies.isEmpty
                    ? 1
                    : Double(outcome.skipped.count + outcome.copiedCount + outcome.failures.count) / Double(result.plannedCopies.count)
                statusText = "合并已取消（已复制 \(outcome.copiedCount) 个文件）。"
                log("合并已取消：完成 \(outcome.copiedCount)/\(result.plannedCopies.count)。", isError: true)
            } else {
                phase = .finished
                overallProgress = 1
                statusText = "合并完成：成功 \(outcome.copiedCount)，跳过 \(outcome.skipped.count)，失败 \(outcome.failures.count)，耗时 \(String(format: "%.1f", outcome.elapsedSeconds)) 秒。"
                log("合并完成：成功复制 \(outcome.copiedCount) 个文件 / \(formatBytes(outcome.copiedBytes))，耗时 \(String(format: "%.1f", outcome.elapsedSeconds)) 秒。")
                for s in outcome.skipped.prefix(20) {
                    log("  跳过: \(s.relativePath)（\(s.reason)）", isError: true)
                }
                for f in outcome.failures.prefix(20) {
                    log("  失败: \(f.relativePath)（\(f.reason)）", isError: true)
                }
            }
        } catch is CancellationError {
            phase = .analyzed
            overallProgress = nil
            statusText = "合并已取消。"
            log("合并已取消。", isError: true)
        } catch {
            phase = .failed(error.localizedDescription)
            overallProgress = nil
            statusText = "合并失败：\(error.localizedDescription)"
            log("合并失败：\(error.localizedDescription)", isError: true)
        }
    }

    private func mergeTick(copied: Int, processed: Int, total: Int, bytes: Int64) {
        guard phase == .merging else { return }
        let fraction = total > 0 ? Double(processed) / Double(total) : 1
        overallProgress = min(fraction, 1)
        statusText = "正在合并… 已复制 \(copied)/\(total) 个文件（\(formatBytes(bytes))）"
        let percent = Int(fraction * 100)
        if percent >= lastMilestonePercent + 10 {
            lastMilestonePercent = percent - percent % 10
            log("进度 \(lastMilestonePercent)%：已处理 \(processed)/\(total)，已复制 \(copied) 个。")
        }
    }

    // MARK: - 取消

    func cancelAll() {
        analysisTask?.cancel()
        mergeTask?.cancel()
    }

    // MARK: - 工具

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
