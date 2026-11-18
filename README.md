<p align="center">
  <img src="Resources/AppIcon.png" width="120" height="120" alt="macOS Downloader app icon">
</p>
<h1 align="center">macOS Downloader</h1>
<p align="center"><strong>Official macOS installers, with download progress and a bootable USB writer.</strong><br>A native Apple Silicon app for finding, downloading, and preparing macOS installers.</p>
<p align="center">
  <img src="https://img.shields.io/badge/platform-Apple%20Silicon-0f766e?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/macOS-14%2B-334155?style=flat-square" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/build-from%20source-334155?style=flat-square" alt="Build from source">
</p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center">
  <a href="#build-from-source">Build from source</a> ·
  <a href="#before-writing-a-usb-drive">USB safety</a> ·
  <a href="https://github.com/ProvenceJake/macos-downloader/issues">Report an issue</a>
</p>

---

macOS Downloader reads Apple's software update catalog when it starts and when you refresh it. For the modern macOS families configured in the app, it resolves the available full `InstallAssistant.pkg` again when you begin a download. The app downloads in the foreground and shows bytes, speed, remaining time, and progress. It also offers direct Apple DMG links for selected older releases.

> [!IMPORTANT]
> This is an independent project, not an Apple product. The locally built app is ad-hoc signed and **not notarized**; there is no prebuilt release in this repository. Creating a bootable USB drive **erases the selected external disk**. Check the target carefully before confirming.

## What it does

| Installer catalog | Visual download | Bootable USB |
| --- | --- | --- |
| Lists the configured modern macOS families, resolves available full installers, and links to selected legacy DMGs. | Downloads `InstallAssistant.pkg` in the foreground with live progress and speed, then installs the downloaded package into `/Applications`. | Finds local installer apps and mounted external drives, then runs Apple's `createinstallmedia` and mirrors its output in the app. |

Modern installer availability depends on Apple's catalog and your Mac. A catalog entry is **not** a guarantee that the chosen macOS can be installed on a particular Mac. Check [Apple's macOS compatibility guidance](https://support.apple.com/en-us/102662) before downloading or writing media.

Legacy DMGs are download-only: open the downloaded DMG and run its PKG to place the installer in `/Applications`, then refresh the app. A compatible Mac is still required.

## Build from source

Requires an Apple Silicon Mac running macOS 14 or later, plus Xcode or the Xcode Command Line Tools with Swift.

```sh
git clone https://github.com/ProvenceJake/macos-downloader.git
cd macos-downloader
./Scripts/build-arm64-app.sh
```

The script produces an ad-hoc-signed arm64 app at `build/MacOS下载器.app`. Move it to `/Applications` to make it available from Launchpad. The app's interface is currently in Chinese; this repository has English and Chinese documentation.

## Before writing a USB drive

1. Download a full macOS installer and confirm its app is in `/Applications`.
2. Connect an external USB drive, select the installer and target drive, and review the erase confirmation. **All data on the target disk will be deleted.**
3. The app opens Terminal for Apple's `createinstallmedia`. Enter your administrator password there and allow Terminal to access removable volumes if macOS asks. Keep that Terminal window open until the command finishes.

An APFS target is first reformatted as Mac OS Extended (Journaled) because `createinstallmedia` cannot use APFS as bootable install media. The app shows formatting and write progress, but the installer command's successful completion is the final result. Do not eject the drive early.

## Scope and validation

The project includes smoke checks for catalog parsing, command exit codes, and progress-log handling. A local build and those checks do not certify every macOS installer, Mac model, or USB drive. No background download service or automatically scheduled disk write is installed.

When [reporting an issue](https://github.com/ProvenceJake/macos-downloader/issues), include your macOS version, Mac architecture, installer version, target drive format, and the relevant error. Remove serial numbers, private paths, and credentials from logs before posting.
