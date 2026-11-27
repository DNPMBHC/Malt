// SPDX-License-Identifier: GPL-3.0-or-later
// Multi-container list section with one-click switching and guarded in-app container deletion.

import Foundation
import SwiftUI
import WhiskyKit

/// Displays all registered managed `.utm` containers with active switching and safe deletion options.
@MainActor
struct ManagedContainerListSection: View {
    @ObservedObject var orchestrator: UnifiedRuntimeOrchestrator
    let isBusy: Bool
    let onFeedback: (String, Bool) -> Void
    let onChanged: () -> Void

    @State private var containers: [ManagedContainerItem] = []
    @State private var diskSizesGiB: [String: Double] = [:]
    @State private var pendingDeleteItem: ManagedContainerItem?
    @State private var pendingDeleteFromDisk = false
    @State private var showDeleteConfirm = false
    @State private var isMutating = false

    var body: some View {
        Group {
            if !containers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("已添加的受管容器（\(containers.count)）")
                        .font(.subheadline.weight(.medium))
                    VStack(spacing: 6) {
                        ForEach(containers) { item in
                            containerRow(item)
                        }
                    }
                    .padding(10)
                    .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .onAppear(perform: reloadContainers)
        .onChange(of: orchestrator.lastStatusMessage) { _, _ in reloadContainers() }
        .confirmationDialog(
            pendingDeleteFromDisk ? "彻底删除容器并释放磁盘空间？" : "从列表移除该容器？",
            isPresented: $showDeleteConfirm,
            presenting: pendingDeleteItem
        ) { item in
            Button(
                pendingDeleteFromDisk ? "确认删除磁盘文件（\(item.displayName)）" : "仅从列表移除（保留文件）",
                role: .destructive
            ) {
                performDelete(item: item, deleteFilesOnDisk: pendingDeleteFromDisk)
            }
            Button("取消", role: .cancel) { pendingDeleteItem = nil }
        } message: { item in
            if pendingDeleteFromDisk {
                Text("将把「\(item.displayName).utm」移至废纸篓或直接删除以释放空间；请确认该容器已完全关闭。")
            } else {
                Text("仅从 Malt 列表中移除「\(item.displayName)」，磁盘上的 .utm 容器文件将完整保留。")
            }
        }
    }

    private func containerRow(_ item: ManagedContainerItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.isActive ? "checkmark.circle.fill" : "shippingbox")
                .foregroundStyle(item.isActive ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if item.isActive {
                        Text("当前使用")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                Text(sizeSubtitle(for: item))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if !item.isActive {
                Button("切换使用") { selectContainer(item) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isBusy || isMutating)
            }
            Menu {
                Button("仅从列表移除（保留文件）") {
                    pendingDeleteItem = item
                    pendingDeleteFromDisk = false
                    showDeleteConfirm = true
                }
                Divider()
                Button("删除容器并释放磁盘空间…", role: .destructive) {
                    pendingDeleteItem = item
                    pendingDeleteFromDisk = true
                    showDeleteConfirm = true
                }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(isBusy || isMutating)
            .help("移除或删除此容器")
        }
    }

    private func sizeSubtitle(for item: ManagedContainerItem) -> String {
        if let sizeGiB = diskSizesGiB[item.bundlePath] {
            return String(format: "占用约 %.1f GiB · UUID %@", sizeGiB, String(item.vmIdentifier.prefix(8)))
        }
        return "正在计算占用空间… · UUID \(item.vmIdentifier.prefix(8))"
    }

    private func reloadContainers() {
        let loaded = orchestrator.listManagedContainers()
        containers = loaded
        let paths = loaded.map(\.bundlePath)
        Task.detached(priority: .utility) {
            var computed: [String: Double] = [:]
            for path in paths {
                computed[path] = Self.computeDirectoryGiB(at: path)
            }
            let snapshot = computed
            await MainActor.run { diskSizesGiB = snapshot }
        }
    }

    private func selectContainer(_ item: ManagedContainerItem) {
        isMutating = true
        do {
            _ = try orchestrator.selectManagedContainer(at: item.bundlePath)
            isMutating = false
            reloadContainers()
            onFeedback("已切换当前受管容器为「\(item.displayName)」。", false)
            onChanged()
        } catch {
            isMutating = false
            onFeedback(error.localizedDescription, true)
        }
    }

    private func performDelete(item: ManagedContainerItem, deleteFilesOnDisk: Bool) {
        isMutating = true
        Task {
            do {
                _ = try await orchestrator.deleteManagedContainer(
                    at: item.bundlePath, deleteFilesOnDisk: deleteFilesOnDisk
                )
                isMutating = false
                reloadContainers()
                let msg = deleteFilesOnDisk
                    ? "已删除容器「\(item.displayName)」并释放磁盘空间。"
                    : "已从列表移除容器「\(item.displayName)」（原文件保留）。"
                onFeedback(msg, false)
                onChanged()
            } catch {
                isMutating = false
                onFeedback(error.localizedDescription, true)
            }
        }
    }

    private nonisolated static func computeDirectoryGiB(at path: String) -> Double {
        let url = URL(filePath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey])
            if let allocated = values?.fileAllocatedSize, allocated > 0 {
                total += Int64(allocated)
            } else if let size = values?.fileSize {
                total += Int64(size)
            }
        }
        return Double(total) / 1_073_741_824.0
    }
}
