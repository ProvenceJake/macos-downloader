import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            AppBackground()
            VStack(spacing: 0) {
                HeaderView()
                Divider()
                    .opacity(0.45)
                HStack(spacing: 0) {
                    InstallerSidebar()
                        .frame(width: 350)
                    Divider()
                        .opacity(0.45)
                    DashboardView()
                }
            }
        }
        .foregroundStyle(.primary)
        .alert("确认抹掉目标卷", isPresented: $model.showEraseConfirmation) {
            Button("取消", role: .cancel) { }
            Button("抹掉并写入", role: .destructive) {
                Task { await model.writeBootableUSB() }
            }
        } message: {
            if let volume = model.selectedVolume {
                Text("“\(volume.eraseTargetDescription)”上的所有数据都会被删除。APFS 目标会先被格式化为 Mac OS Extended (Journaled)。写入时会打开终端，请在终端输入管理员密码，并允许访问移动磁盘。")
            } else {
                Text("目标外接磁盘上的所有数据都会被删除。")
            }
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.94, green: 0.98, blue: 0.98),
                Color(red: 0.99, green: 0.96, blue: 0.91)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct HeaderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.05, green: 0.45, blue: 0.62),
                                Color(red: 0.93, green: 0.52, blue: 0.22)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "externaldrive.badge.plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("macOS 下载器")
                    .font(.system(size: 24, weight: .semibold))
                Text(model.currentTask)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let progress = model.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 180)
            } else if model.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Button {
                Task { await model.refreshAll() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(model.isBusy)
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(.regularMaterial)
    }
}

private struct InstallerSidebar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("可下载系统")
                    .font(.headline)
                Spacer()
                Text("\(model.installers.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.installers) { installer in
                        InstallerRow(installer: installer, isSelected: model.selectedInstallerID == installer.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.selectedInstallerID = installer.id
                            }
                    }
                }
                .padding(.bottom, 10)
            }
        }
        .padding(18)
        .background(.thinMaterial)
    }
}

private struct InstallerRow: View {
    let installer: InstallerOption
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: installerIcon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isSelected ? .white : Color(red: 0.05, green: 0.45, blue: 0.62))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 6) {
                Text(installer.displayTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Text(installer.source.label)
                    if let sizeHint = installer.sizeHint {
                        Text(sizeHint)
                    }
                    if let build = installer.build {
                        Text(build)
                    }
                }
                .font(.caption)
                .foregroundStyle(isSelected ? .white.opacity(0.82) : .secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(red: 0.05, green: 0.45, blue: 0.62) : Color(nsColor: .controlBackgroundColor).opacity(0.72))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.clear : Color.black.opacity(0.07), lineWidth: 1)
        }
    }

    private var installerIcon: String {
        switch installer.source {
        case .softwareUpdate:
            return "link.circle.fill"
        case .installAssistantPackage:
            return "arrow.down.circle.fill"
        case .legacyDMG:
            return "shippingbox.fill"
        }
    }
}

private struct DashboardView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                DownloadPanel()
                USBWriterPanel()
            }
            LogPanel()
        }
        .padding(18)
    }
}

private struct DownloadPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel(title: "下载", systemImage: "arrow.down.to.line") {
            VStack(alignment: .leading, spacing: 14) {
                if let installer = model.selectedInstaller {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(installer.displayTitle)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(installer.note)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Text("未选择系统")
                        .foregroundStyle(.secondary)
                }

                if model.isDownloading || model.downloadProgress != nil {
                    DownloadMeter(progress: model.downloadProgress)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    if model.isDownloading {
                        Button(role: .destructive) {
                            model.cancelDownload()
                        } label: {
                            Label("取消下载", systemImage: "xmark.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await model.downloadSelectedInstaller() }
                        } label: {
                            Label(downloadButtonTitle, systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isBusy || model.selectedInstaller == nil)
                    }

                    Button {
                        model.openDownloadsFolder()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("打开下载文件夹")
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var downloadButtonTitle: String {
        guard let installer = model.selectedInstaller else { return "下载所选系统" }
        switch installer.source {
        case .legacyDMG:
            return "前台下载 DMG"
        case .softwareUpdate, .installAssistantPackage:
            return "前台下载并安装"
        }
    }
}

private struct DownloadMeter: View {
    let progress: DownloadProgressSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)

            HStack(spacing: 14) {
                MeterValue(title: "进度", value: progress?.percentText ?? "--")
                MeterValue(title: "已下载", value: progress?.downloadedText ?? "准备中")
                MeterValue(title: "总大小", value: progress?.totalText ?? "大小未知")
                MeterValue(title: "速度", value: progress?.speedText ?? "计算中")
            }

            Text(progress?.remainingText ?? "等待开始")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.05, green: 0.45, blue: 0.62).opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.05, green: 0.45, blue: 0.62).opacity(0.18), lineWidth: 1)
        }
    }
}

private struct MeterValue: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.callout, design: .monospaced).weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct USBWriterPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel(title: "写入 U 盘", systemImage: "externaldrive.connected.to.line.below") {
            VStack(alignment: .leading, spacing: 14) {
                Picker("安装器", selection: Binding(
                    get: { model.selectedLocalInstallerID ?? "" },
                    set: { model.selectedLocalInstallerID = $0.isEmpty ? nil : $0 }
                )) {
                    if model.localInstallers.isEmpty {
                        Text("未发现安装器").tag("")
                    } else {
                        ForEach(model.localInstallers) { installer in
                            Text(installer.displayTitle).tag(installer.id)
                        }
                    }
                }
                .labelsHidden()

                Picker("目标卷", selection: Binding(
                    get: { model.selectedVolumeID ?? "" },
                    set: { model.selectedVolumeID = $0.isEmpty ? nil : $0 }
                )) {
                    if model.usbVolumes.isEmpty {
                        Text("未发现 U 盘").tag("")
                    } else {
                        ForEach(model.usbVolumes) { volume in
                            Text("\(volume.displayTitle) · \(volume.sizeDescription) · \(volume.filesystemDescription)").tag(volume.id)
                        }
                    }
                }
                .labelsHidden()

                if let volume = model.selectedVolume {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color(red: 0.86, green: 0.43, blue: 0.12))
                        Text("将抹掉 \(volume.eraseTargetDescription)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text("插入 U 盘后刷新。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if model.isWritingUSB || model.writeProgress != nil {
                    WriteMeter(progress: model.writeProgress)
                }

                Spacer(minLength: 0)

                HStack(spacing: 10) {
                    Button {
                        model.requestWriteConfirmation()
                    } label: {
                        Label("写入启动盘", systemImage: "play.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.84, green: 0.34, blue: 0.18))
                    .disabled(model.isBusy || model.selectedLocalInstaller == nil || model.selectedVolume == nil)

                    Button {
                        model.scanLocalInstallers()
                        Task { await model.refreshUSBVolumes() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新安装器和 U 盘")
                    .buttonStyle(.bordered)

                    Button {
                        model.openApplicationsFolder()
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .help("打开应用程序文件夹")
                    .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct WriteMeter: View {
    let progress: WriteProgressSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: progress?.fraction ?? 0)
                .progressViewStyle(.linear)

            HStack(spacing: 14) {
                MeterValue(title: "阶段", value: progress?.phase ?? "准备")
                MeterValue(title: "进度", value: progress?.percentText ?? "--")
            }

            Text(progress?.detail ?? "等待开始")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(red: 0.84, green: 0.34, blue: 0.18).opacity(0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(red: 0.84, green: 0.34, blue: 0.18).opacity(0.18), lineWidth: 1)
        }
    }
}

private struct LogPanel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Panel(title: "任务日志", systemImage: "terminal") {
            VStack(spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            if model.logEntries.isEmpty {
                                Text("暂无日志")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                            } else {
                                ForEach(model.logEntries) { entry in
                                    LogRow(entry: entry)
                                        .id(entry.id)
                                }
                            }
                        }
                    }
                    .onChange(of: model.logEntries.count) { _, _ in
                        if let last = model.logEntries.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button {
                        model.clearLog()
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.logEntries.isEmpty)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(entry.message)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var icon: String {
        switch entry.level {
        case .info:
            return "circle"
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch entry.level {
        case .info:
            return .secondary
        case .success:
            return Color(red: 0.05, green: 0.52, blue: 0.34)
        case .warning:
            return Color(red: 0.86, green: 0.43, blue: 0.12)
        case .error:
            return Color(red: 0.75, green: 0.10, blue: 0.12)
        }
    }
}

private struct Panel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color(red: 0.05, green: 0.45, blue: 0.62))
                Text(title)
                    .font(.headline)
                Spacer()
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        }
    }
}
