// SPDX-License-Identifier: GPL-3.0-or-later
// Drag-and-drop virtual USB ISO transfer card and guest Chinese IME repair trigger.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskyKit

struct VirtualUSBTransferCard: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator

    @State private var isDropTargeted = false
    @State private var isBusy = false
    @State private var isRepairingIME = false
    @State private var activeReceipt: VirtualUSBTransferReceipt?
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        AppSection {
            VStack(alignment: .leading, spacing: 12) {
                headerRow
                dropZoneView
                if let message = statusMessage {
                    AppStatusLabel(
                        text: message,
                        systemImage: statusIsError ? "exclamationmark.triangle" : "checkmark.circle",
                        tint: statusIsError ? .orange : .green
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
                footerTipsAndRepairRow
            }
        }
    }

    private var headerRow: some View {
        AppAdaptiveRow {
            VStack(alignment: .leading, spacing: 4) {
                Text("模拟 USB 极速传文件（跨屏传输）").font(.headline)
                Text("将任意 .exe 安装包或文件夹拖入下方，1–2 秒打包为虚拟 USB 盘热插拔挂载到 Windows（MALT_USB 盘符），无需慢速串口或网络。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        } trailing: {
            HStack(spacing: 8) {
                Button("选择文件…", action: pickFiles)
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                if activeReceipt != nil {
                    Button("安全弹出", action: ejectVirtualUSB)
                        .buttonStyle(.bordered)
                        .disabled(isBusy)
                }
            }
        }
    }

    private var dropZoneView: some View {
        VStack(spacing: 6) {
            if isBusy {
                ProgressView().controlSize(.small)
                Text("正在打包并热挂载虚拟 USB 盘…").font(.caption).foregroundStyle(.secondary)
            } else if let receipt = activeReceipt {
                Label(
                    "已就绪：\(receipt.fileNames.joined(separator: "、"))（\(formatBytes(receipt.totalBytes))）",
                    systemImage: "externaldrive.fill.badge.checkmark"
                )
                .font(.subheadline.weight(.medium))
                Text(receipt.mountedLive
                     ? "已热插入运行中的容器，请直接在 Windows「此电脑」打开 MALT_USB 盘符高速拷贝或运行。"
                     : "镜像已准备就绪；若容器尚未启用可移动槽位，下次重新打开容器后即可在「此电脑」看到 MALT_USB。")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            } else {
                Label("拖入 .exe / .msi / .zip 或文件夹到此区域", systemImage: "square.and.arrow.down.on.square")
                    .font(.subheadline)
                    .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
                Text("本地块设备直读（500+ MB/s），用完可一键安全弹出清理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.10) : Color(nsColor: .textBackgroundColor).opacity(0.5),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(
                isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.6),
                style: StrokeStyle(lineWidth: 1, dash: [5, 4])
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    private var footerTipsAndRepairRow: some View {
        AppAdaptiveRow {
            Text("鼠标提示：请直接点击容器顶栏「捕获鼠标」使用低延迟 virtio 相对鼠标，勿在 USB 菜单抢占鼠标（macOS 内核会报 LIBUSB_ERROR_ACCESS）。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Button(action: repairChineseIME) {
                HStack(spacing: 6) {
                    if isRepairingIME { ProgressView().controlSize(.small) }
                    Text(isRepairingIME ? "正在安装中文词库…" : "修复中文输入法弹窗")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isRepairingIME)
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "极速传入容器"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            transferFiles(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let matching = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !matching.isEmpty else { return false }
        Task {
            var urls: [URL] = []
            for provider in matching {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                await MainActor.run { transferFiles(urls) }
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func transferFiles(_ urls: [URL]) {
        isBusy = true
        statusMessage = nil
        statusIsError = false
        Task {
            do {
                let receipt = try await orchestrator.mountFilesViaVirtualUSB(urls)
                await MainActor.run {
                    activeReceipt = receipt
                    statusIsError = false
                    statusMessage = receipt.mountedLive
                        ? "已通过模拟 USB 热挂载至容器（MALT_USB 盘符），可直接极速拷贝或运行。"
                        : "已打包为模拟 USB 镜像；重开容器后即可在 Windows「此电脑」直接访问 MALT_USB。"
                    isBusy = false
                }
            } catch {
                await MainActor.run {
                    statusIsError = true
                    statusMessage = error.localizedDescription
                    isBusy = false
                }
            }
        }
    }

    private func ejectVirtualUSB() {
        do {
            try orchestrator.ejectVirtualUSB()
            activeReceipt = nil
            statusIsError = false
            statusMessage = "已安全弹出并清理模拟 USB 传输镜像。"
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func repairChineseIME() {
        isRepairingIME = true
        statusMessage = nil
        statusIsError = false
        Task {
            do {
                let msg = try await orchestrator.repairGuestChineseIME()
                await MainActor.run {
                    statusIsError = false
                    statusMessage = msg
                    isRepairingIME = false
                }
            } catch {
                await MainActor.run {
                    statusIsError = true
                    statusMessage = error.localizedDescription
                    isRepairingIME = false
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct ContainerLowLevelEngineSection: View {
    @ObservedObject var preferences: UnifiedPreferencesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("DirectX 图形转译引擎").font(.subheadline)
                    Text("推荐原生 DXMT（文字最清晰稳定）；MetalFX 会全局超分桌面与 2D 界面文字，D3DMetal 部分游戏可能兼容卡顿。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Picker("DirectX 图形转译引擎", selection: $preferences.graphicsBackendRaw) {
                    ForEach(ContainerGraphicsBackend.allCases, id: \.rawValue) { backend in
                        Text(backend.displayName).tag(backend.rawValue)
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            AppAdaptiveRow {
                VStack(alignment: .leading, spacing: 4) {
                    Text("宿主机 Metal 呈现管线").font(.subheadline)
                    Text("Ring Mailbox 用独立 Blit 队列 + 3 槽环形缓冲解耦 VSync，零撕裂并快速释放 Guest 渲染围栏。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                Picker("宿主机 Metal 呈现管线", selection: $preferences.displayPresentModeRaw) {
                    ForEach(ContainerDisplayPresentMode.allCases, id: \.rawValue) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .labelsHidden().frame(width: 260)
            }
            AppToggleRow(
                title: "原始鼠标直采 Raw Input（零延迟、无 macOS 加速度）",
                detail: "经独立高优线程直传 GCMouse 原始增量 + 亚像素残差保留，触控板自动回退。",
                isOn: $preferences.enableRawMouseInput
            )
            AppToggleRow(
                title: "Apple Silicon 硬件 TSO 内存序（实验性 A/B）",
                detail: "启用 HVF tso=on；建议配合 FPS 遥测与默认模式做对照测试。需完全退出容器引擎后生效。",
                isOn: $preferences.enableHVFTSO
            )
            AppToggleRow(
                title: "启用 Neptune 微秒级热点剖面日志",
                detail: "每 5 秒记录 virglrenderer 热点与呈现管线 scanout/present/ack_us 到遥测目录。",
                isOn: $preferences.enableNeptuneProfiler
            )
        }
    }
}
