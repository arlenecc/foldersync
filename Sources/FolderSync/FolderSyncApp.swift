import SwiftUI
import FolderSyncCore

// MARK: - App 入口

@main
struct FolderSyncApp: App {
    // 单例模型：避免 WindowGroup 内容闭包反复求值时新建实例导致状态丢失
    @StateObject private var model = AppModel()

    var body: some Scene {
        // Window（而非 WindowGroup）：工具类应用保持单窗口，避免多窗口共享/分裂状态的问题
        Window("目录同步合并工具", id: "main") {
            ContentView()
                .frame(minWidth: 1060, minHeight: 680)
                .environmentObject(model)
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)
    }
}

// MARK: - 主布局：上 1/3 配置区 + 下 2/3 处理过程区 + 底部状态栏

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ConfigSection()
                    .frame(height: geo.size.height / 3)
                    .frame(maxWidth: .infinity)
                Divider()
                ProcessSection()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                StatusBar()
                    .frame(height: 36)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - 配置区（上方 1/3，横向 100%）

private struct ConfigSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("目录配置")
                .font(.headline)

            DirectoryRow(
                label: "主目录",
                placeholder: "选择主目录（合并目标，目录结构优先保留）",
                url: model.primaryURL,
                isBusy: model.phase.isBusy
            ) {
                model.chooseDirectory(isPrimary: true)
            }

            DirectoryRow(
                label: "副目录",
                placeholder: "选择副目录（来源，排重后写入主目录）",
                url: model.secondaryURL,
                isBusy: model.phase.isBusy
            ) {
                model.chooseDirectory(isPrimary: false)
            }

            HStack(spacing: 12) {
                if model.directoryConflict {
                    Label("主目录与副目录不能相同", systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.callout)
                }
                Spacer()
                Button("取消") {
                    model.cancelAll()
                }
                .disabled(!model.phase.isBusy)
                Button {
                    model.startAnalysis()
                } label: {
                    Text(model.phase == .idle || model.phase.isBusy ? "开始分析" : "重新分析")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartAnalysis)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct DirectoryRow: View {
    let label: String
    let placeholder: String
    let url: URL?
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .frame(width: 48, alignment: .leading)
            Text(url?.path ?? placeholder)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .foregroundColor(url == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            Button("浏览…", action: action)
                .disabled(isBusy)
        }
    }
}

// MARK: - 处理过程区（下方 2/3）：统计条 + 日志

private struct ProcessSection: View {
    var body: some View {
        VStack(spacing: 0) {
            StatsStrip()
            Divider()
            LogView()
        }
    }
}

/// 排重结果统计（显示在“开始合并”按钮左侧）+ 开始合并按钮
private struct StatsStrip: View {
    @EnvironmentObject private var model: AppModel

    private var estimatedStats: TreeStats? {
        switch model.phase {
        case .analyzed, .merging, .finished:
            return TreeStats(fileCount: model.estimatedCount, totalSize: model.estimatedSize)
        default:
            return nil
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            StatBlock(title: "主目录", stats: model.primaryStats)
            Divider().frame(height: 40)
            StatBlock(title: "副目录", stats: model.secondaryStats)
            Divider().frame(height: 40)
            StatBlock(title: "合并后预估", stats: estimatedStats)
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                if model.phase == .analyzed || model.phase == .merging || model.phase == .finished {
                    Text("待合并 \(model.planCount) 个文件 / \(ByteCountFormatter.string(fromByteCount: model.plannedBytes, countStyle: .file))")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Button {
                    model.startMerge()
                } label: {
                    Label("开始合并", systemImage: "arrow.down.doc.fill")
                        .frame(minWidth: 112)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStartMerge)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct StatBlock: View {
    let title: String
    let stats: TreeStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            if let s = stats {
                Text("\(s.fileCount) 个文件")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(ByteCountFormatter.string(fromByteCount: s.totalSize, countStyle: .file))
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Text("—")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                Text("等待分析")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .frame(minWidth: 132, alignment: .leading)
    }
}

/// 处理过程日志（自动滚动到底部，容量截断防止海量文件时卡顿）
private struct LogView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if model.logEntries.isEmpty {
                        Text("处理过程日志将显示在这里。")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    ForEach(model.logEntries) { entry in
                        Text(entry.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(entry.isError ? .red : Color(nsColor: .labelColor))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                    }
                }
                .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.logEntries) { entries in
                if let last = entries.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - 底部状态栏：总体处理进度

private struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Text(phaseLabel)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 52, alignment: .leading)
            Group {
                if let p = model.overallProgress {
                    ProgressView(value: p)
                } else if model.phase.isBusy {
                    ProgressView()
                } else {
                    ProgressView(value: model.phase == .finished ? 1.0 : 0.0)
                        .tint(model.phase == .finished ? .green : .secondary)
                }
            }
            .frame(width: 300)
            Text(model.statusText)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var phaseLabel: String {
        switch model.phase {
        case .idle: return "就绪"
        case .scanning: return "扫描中"
        case .hashing: return "排重中"
        case .analyzed: return "待合并"
        case .merging: return "合并中"
        case .finished: return "完成"
        case .failed: return "失败"
        }
    }
}
