# macOS 下载器

一个原生 Apple Silicon macOS 工具，用于下载 Apple 提供的完整 macOS 安装器，并把 `/Applications` 中的安装器写入 U 盘。

## 功能

- 启动时只加载内置下载列表、本地安装器和外接磁盘，避免自动触发系统软件更新扫描。
- 点击下载现代 macOS 时按需解析 Apple 官方软件更新目录，获取对应的 `InstallAssistant.pkg`。
- 现代 macOS 使用 Apple `InstallAssistant.pkg` 前台下载，显示百分比、已下载大小、总大小和实时速度。
- 前台下载完成后自动安装 pkg，把 macOS 安装器放入 `/Applications`，成功后删除临时 pkg。
- 内置 Apple 官方旧版 DMG 链接：Sierra、El Capitan、Yosemite、Mountain Lion、Lion。
- 扫描 `/Applications` 中带 `createinstallmedia` 的 macOS 安装器。
- 扫描外接磁盘卷，并通过安装器自带的 `createinstallmedia` 写入可引导 U 盘。
- 写入 U 盘时会请求管理员权限，并在执行前二次确认会抹掉目标卷。
- 包含自定义 macOS app 图标，可安装到“应用程序”并显示在启动台。

## 构建

```bash
./Scripts/build-arm64-app.sh
```

构建完成后会生成：

```text
build/MacOS下载器.app
```

也可以直接运行开发版：

```bash
swift run MacOSDownloader
```

## 注意

写入启动盘会删除目标 U 盘上的全部数据。旧版 DMG 下载完成后，需要打开 DMG 中的 PKG，让它把安装器安装到“应用程序”文件夹，然后再回到本工具刷新本地安装器。现代 macOS 下载会请求管理员权限安装 `InstallAssistant.pkg`。
