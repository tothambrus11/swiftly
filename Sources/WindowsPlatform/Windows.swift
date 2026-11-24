import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage
import WinSDK

typealias fs = SwiftlyCore.FileSystem

/// `Platform` implementation for Windows systems.
public struct Windows: Platform {
    public init() {}

    public var defaultSwiftlyHomeDir: FilePath {
        // Foundation's application support directory on Windows is the Local AppData folder,
        // the one %LOCALAPPDATA% normally points to.
        let localAppData = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first.map { FilePath($0.path) } ?? fs.home / "AppData" / "Local"
        return localAppData / "swiftly"
    }

    public func swiftlyBinDir(_ ctx: SwiftlyCoreContext) -> FilePath {
        ctx.mockedHomeDir.map { $0 / "bin" }
            ?? ProcessInfo.processInfo.environment["SWIFTLY_BIN_DIR"].map { FilePath($0) }
            ?? self.defaultSwiftlyHomeDir / "bin"
    }

    public func swiftlyToolchainsDir(_ ctx: SwiftlyCoreContext) -> FilePath {
        ctx.mockedHomeDir.map { $0 / "toolchains" }
            ?? ProcessInfo.processInfo.environment["SWIFTLY_TOOLCHAINS_DIR"].map { FilePath($0) }
            ?? self.defaultSwiftlyHomeDir / "toolchains"
    }

    public func escapePathForShell(_ path: FilePath) -> String {
        // Double quotes work for both cmd and PowerShell, and neither allows them inside a path.
        "\"\(path.string)\""
    }

    public var systemAdministrator: String {
        "an administrator"
    }

    public var toolchainFileExtension: String {
        "exe"
    }

    /// Installs a toolchain into its own directory, `<toolchains>\<name>`, side by side with the others,
    /// from the swift.org installer, without running it (see `WindowsToolchain`).
    ///
    /// It's unpacked in a staging directory on the same volume and moved into place at the end, so
    /// a failed install leaves an existing toolchain of the same version alone.
    public func install(
        _ ctx: SwiftlyCoreContext, from tmpFile: FilePath, version: ToolchainVersion, verbose: Bool
    ) async throws {
        guard try await fs.exists(atPath: tmpFile) else {
            throw SwiftlyError(message: "\(tmpFile) doesn't exist")
        }
        let toolchainsDir = self.swiftlyToolchainsDir(ctx)
        try await fs.mkdir(.parents, atPath: toolchainsDir)

        await ctx.message("Extracting toolchain...")
        defer { WindowsToolchain.removeStagingAreaIfEmpty(in: toolchainsDir) }
        // Previous toolchains that an earlier install couldn't delete yet, unless one would be
        // the only copy of its version (if putting it back failed).
        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: toolchainsDir.string)) ?? [] where Self.isLeftover(leftover) {
            let base = leftover.replacing(#/\.swiftly-[0-9a-fA-F]{8}\.old$/#, with: "")
            if FileManager.default.fileExists(atPath: (toolchainsDir / base).string) {
                try? FileManager.default.removeItem(atPath: (toolchainsDir / leftover).string)
            }
        }
        let staging = try WindowsToolchain.makeStagingDirectory(in: toolchainsDir)
        defer { try? FileManager.default.removeItem(atPath: staging.string) }
        let unpacked = try await WindowsToolchain.unpack(ctx, tmpFile, staging: staging, verbose: verbose)
        guard let unpackedLayout = WindowsToolchainLayout.read(unpacked) else {
            throw SwiftlyError(message: "The installer for \(version) didn't contain a complete toolchain.")
        }
        try unpackedLayout.recordPython()

        let toolchainDir = toolchainsDir / version.name
        // The old toolchain goes aside next to the toolchains, not into the staging directory,
        // which the next install empties.
        try await Self.swap(ctx, unpacked, into: toolchainDir, aside: Windows.leftoverName(for: toolchainDir, stamp: Self.newStamp(), kind: "old"))

        if ctx.mockedHomeDir == nil, case let .ready(installation) = await VisualStudio.detect(),
           let installed = WindowsToolchainLayout.read(toolchainDir)
        {
            await self.warnAboutSTL(ctx, installation: installation, bin: installed.bin)
        }
    }

    /// The MSVC STL refuses older clangs (error STL1000), as the Visual Studio 2026 STL does with the
    /// clang of current toolchains. That breaks C++ in packages, so say so.
    private func warnAboutSTL(_ ctx: SwiftlyCoreContext, installation: FilePath, bin: FilePath) async {
        guard let required = VisualStudio.requiredClangMajor(installation: installation),
              let clang = await VisualStudio.clangMajor(bin: bin), clang < required
        else {
            return
        }
        await ctx.message("""
        Warning: the default MSVC toolset of Visual Studio at \(installation) requires clang \(required) or later \
        for C++, and this toolchain has clang \(clang): C++ code (including C++ interoperability) fails with \
        error STL1000. Install an older MSVC toolset (such as 14.44) with the Visual Studio Installer and \
        select it, or define _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH at your own risk.
        """)
    }

    public func extractSwiftlyAndInstall(_: SwiftlyCoreContext, from _: FilePath) async throws {
        throw Self.notSupportedYet("Installing swiftly")
    }

    /// How long uninstall waits for a toolchain that's in use (tests make it short).
    nonisolated(unsafe) static var uninstallRenameBudget: TimeInterval = 60

    /// Renames the toolchain's directory aside first, which fails at once and changes nothing if a
    /// program from it is running, and deletes it then.
    public func uninstall(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion, verbose _: Bool) async throws {
        let toolchainsDir = self.swiftlyToolchainsDir(ctx)
        let toolchainDir = toolchainsDir / toolchain.name
        guard try await fs.exists(atPath: toolchainDir) else {
            return
        }
        let area = WindowsToolchain.stagingArea(in: toolchainsDir)
        try FileManager.default.createDirectory(atPath: area.string, withIntermediateDirectories: true)
        let trash = area / "\(toolchain.name).swiftly-\(Self.newStamp()).old"
        do {
            try await Self.rename(ctx, toolchainDir, to: trash, budget: Self.uninstallRenameBudget)
        } catch {
            throw ToolchainNotRemovedError(message: "\(toolchain) is in use, probably by a program from it that's running; close it and try again. (\(error))")
        }
        // Whatever can't be deleted now goes with the next install's cleanup.
        try? FileManager.default.removeItem(atPath: trash.string)
        WindowsToolchain.removeStagingAreaIfEmpty(in: toolchainsDir)
    }

    /// Makes `new` the directory `destination`: renames the old one aside to `aside`, renames the
    /// new one in, and deletes the old one. If the new one can't be renamed in, the old one goes back.
    static func swap(_ ctx: SwiftlyCoreContext, _ new: FilePath, into destination: FilePath, aside: FilePath) async throws {
        let replacing = FileManager.default.fileExists(atPath: destination.string)
        if replacing {
            try await Self.rename(ctx, destination, to: aside)
        }
        do {
            try await Self.rename(ctx, new, to: destination)
        } catch {
            if replacing {
                do {
                    try await Self.rename(ctx, aside, to: destination)
                } catch let restore {
                    await ctx.message("Warning: couldn't put the previous toolchain back from \(aside) (\(restore)); rename it to \(destination) to use it.")
                }
            }
            throw error
        }
        if replacing {
            try? FileManager.default.removeItem(atPath: aside.string)
        }
    }

    /// Renames a file or directory within its volume, waiting up to `budget` seconds while another
    /// program (a virus scanner looking at new files, typically) has something in it open.
    static func rename(_ ctx: SwiftlyCoreContext, _ source: FilePath, to destination: FilePath, budget: TimeInterval = 60) async throws {
        let start = Date()
        var lastReport: Date?
        var attempt = 0
        while true {
            attempt += 1
            do {
                return try Win32.move(source, to: destination)
            } catch let error as Win32.Failure where Win32.inUse.contains(error.code) && Date().timeIntervalSince(start) < budget {
                if lastReport.map({ Date().timeIntervalSince($0) >= 15 }) ?? true {
                    let reason = error.code == DWORD(ERROR_ACCESS_DENIED)
                        ? "access is denied, which usually means that a program has a file in it open"
                        : "another program has it open"
                    await ctx.message("Waiting to rename \(source): \(reason)...")
                    lastReport = Date()
                }
                try await Task.sleep(for: .milliseconds(min(200 * attempt, 2000)))
            }
        }
    }

    public func externallyInstalledToolchainNote(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion) async -> String? {
        guard ctx.mockedHomeDir == nil,
              !FileManager.default.fileExists(atPath: (self.swiftlyToolchainsDir(ctx) / toolchain.name).string),
              self.installedToolchains().contains(where: { $0.version == toolchain })
        else {
            return nil
        }
        return "\(toolchain) was installed with the swift.org installer, not swiftly; uninstall it from Settings > Apps > Installed apps."
    }

    public func getExecutableName() -> String {
        "swiftly-\(cpuArch)-unknown-windows-msvc.exe"
    }

    public func verifySwiftlySystemPrerequisites() async throws {
        // Nothing beyond Windows itself is needed to run swiftly.
    }

    /// Toolchains link programs against the Microsoft C runtime and the Windows SDK of Visual Studio
    /// (or its Build Tools). Without them the toolchain still installs, and the post-install script
    /// says how to get them. Nothing is downloaded here.
    public func verifySystemPrerequisitesForInstall(
        _ ctx: SwiftlyCoreContext, platformName _: String, version _: ToolchainVersion,
        requireSignatureValidation: Bool
    ) async throws -> String? {
        // Before anything is downloaded: signatures can't be verified yet (see verifyToolchainSignature).
        if requireSignatureValidation, !ctx.installsTestToolchains {
            throw SwiftlyError(message: "Verifying the signatures of Windows toolchains isn't supported yet; pass --no-verify to install without verifying.")
        }
        guard ctx.mockedHomeDir == nil else {
            return nil
        }
#if !arch(arm64)
        if Win32.machineIsARM64 {
            await ctx.message("Note: this is the x64 swiftly on an ARM64 machine, so it installs x64 toolchains, which run emulated. The ARM64 swiftly installs native ones.")
        }
#endif
        return VisualStudio.instructions(for: await VisualStudio.detect())
    }

    public func verifyToolchainSignature(
        _ ctx: SwiftlyCoreContext, toolchainFile _: ToolchainFile, archive _: FilePath, verbose _: Bool
    ) async throws {
        // Tests' own toolchain archives aren't signed.
        guard !ctx.installsTestToolchains else {
            return
        }
        // The swift.org Windows installers carry Authenticode signatures rather than PGP ones;
        // checking them comes in a follow-up. Until then, installing needs an explicit --no-verify.
        throw SwiftlyError(message: "Verifying the signatures of Windows toolchains isn't supported yet; pass --no-verify to install without verifying.")
    }

    /// Swift 6.2 and later: older installers have another layout (sdk.windows.<arch>.msi rather
    /// than windows.msi), which swiftly doesn't unpack.
    public func unsupportedToolchainReason(_ ctx: SwiftlyCoreContext, _ version: ToolchainVersion) -> String? {
        guard !ctx.installsTestToolchains else {
            return nil
        }
        let release: (major: Int, minor: Int)
        switch version {
        case let .stable(stable):
            release = (stable.major, stable.minor)
        case let .snapshot(snapshot):
            guard case let .release(major, minor, _) = snapshot.branch else {
                return nil
            }
            release = (major, minor)
        case .xcode:
            return "Xcode toolchains are for macOS."
        }
        guard release >= (6, 2) else {
            return "swiftly installs Swift 6.2 and later on Windows."
        }
        return nil
    }

    public func verifySwiftlySignature(
        _: SwiftlyCoreContext, archiveDownloadURL _: URL, archive _: FilePath, verbose _: Bool
    ) async throws {
        throw Self.notSupportedYet("Verifying swiftly signatures")
    }

    public func detectPlatform(
        _: SwiftlyCoreContext, disableConfirmation _: Bool, platform _: String?
    ) async throws -> PlatformDefinition {
        .windows10
    }

    /// swift.org names the Windows download directory like the file, and uses "-arm64":
    /// `swift-6.4.3-release/windows10-arm64/swift-6.4.3-RELEASE/swift-6.4.3-RELEASE-windows10-arm64.exe`.
    public func toolchainDownloadPlatform(_ platform: PlatformDefinition) -> (directory: String, file: String) {
#if arch(arm64)
        (platform.nameFull + "-arm64", platform.nameFull + "-arm64")
#else
        (platform.nameFull, platform.nameFull)
#endif
    }

    /// There's no shell profile on Windows: new sessions get their environment from the registry.
    public var sessionEnvironment: (any SessionEnvironment)? {
        UserEnvironment()
    }

    public func getShell() async throws -> String {
        ProcessInfo.processInfo.environment["ComSpec"] ?? "cmd.exe"
    }

    public func discoverInstalledToolchains(_ ctx: SwiftlyCoreContext) async throws -> Set<ToolchainVersion>? {
        // Tests keep mocked toolchains in a mocked home and mustn't see what this machine has installed.
        guard ctx.mockedHomeDir == nil else {
            return nil
        }
        return Set(self.swiftlyToolchains(ctx).map(\.version) + self.installedToolchains().map(\.version))
    }

    public func findToolchainLocation(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion) async throws -> FilePath {
        let toolchainDir = self.swiftlyToolchainsDir(ctx) / toolchain.name
        if let layout = WindowsToolchainLayout.read(toolchainDir) {
            return layout.toolchain
        }
        if ctx.mockedHomeDir == nil, let installed = self.installedToolchains().first(where: { $0.version == toolchain }) {
            return installed.root
        }
        // Not installed (yet): where `usrin` would be in the layout.
        return toolchainDir / "Toolchains" / toolchain.name
    }

    /// The toolchains swiftly installed: one directory per version in the toolchains directory.
    private func swiftlyToolchains(_ ctx: SwiftlyCoreContext) -> [(version: ToolchainVersion, layout: WindowsToolchainLayout)] {
        let toolchainsDir = self.swiftlyToolchainsDir(ctx)
        return ((try? FileManager.default.contentsOfDirectory(atPath: toolchainsDir.string)) ?? []).compactMap { name in
            guard let version = try? ToolchainVersion(parsing: name), let layout = WindowsToolchainLayout.read(toolchainsDir / name) else {
                return nil
            }
            return (version, layout)
        }
    }

    /// The Swift versions Windows Installer has a toolchain registered for, with each toolchain's root.
    /// Versions that don't parse as a `ToolchainVersion` are left out.
    private func installedToolchains() -> [(version: ToolchainVersion, root: FilePath)] {
        MsiEnumeration.installed.compactMap { swift in
            guard let root = swift.toolchain, let version = try? ToolchainVersion(parsing: swift.version) else {
                return nil
            }
            return (version, root)
        }
    }

    public func findToolchainBinDir(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion) async throws -> FilePath {
        try await self.findToolchainLocation(ctx, toolchain) / "usr" / "bin"
    }

    public func updateEnvironmentWithToolchain(
        _ ctx: SwiftlyCoreContext, _ environment: Environment, _ toolchain: ToolchainVersion, path: String
    ) async throws -> Environment {
        // Besides the toolchain, programs need the Swift runtime DLLs on the Path, and the compiler
        // needs SDKROOT to find the Windows platform SDK. Nothing else: no Visual Studio variables,
        // which the toolchain finds on its own.
        let runtimeBin: FilePath?
        let sdk: FilePath?
        var python: FilePath?
        if let layout = WindowsToolchainLayout.read(self.swiftlyToolchainsDir(ctx) / toolchain.name) {
            runtimeBin = layout.runtimeBin
            sdk = layout.sdk
            python = layout.python
        } else if ctx.mockedHomeDir == nil,
                  let installed = MsiEnumeration.installed.first(where: { (try? ToolchainVersion(parsing: $0.version)) == toolchain })
        {
            runtimeBin = installed.runtime
            sdk = installed.sdks.first { $0.lastComponent?.string == "Windows.sdk" }
        } else {
            return environment
        }

        var updates: [Environment.Key: String] = [:]
        if let runtimeBin {
            updates["Path"] = Self.insertingAfterFirst(runtimeBin, into: path)
        }
        // lldb loads Python from Path.
        if let python, let current = updates["Path"] {
            updates["Path"] = current + ";" + python.string
        }
        if let sdk {
            updates["SDKROOT"] = sdk.string + "\\"
        }
        return environment.updating(updates)
    }

    /// Puts `directory` second in a `;`-separated search path, right after the toolchain.
    static func insertingAfterFirst(_ directory: FilePath, into path: String) -> String {
        var entries = path.split(separator: ";").map(String.init)
        entries.removeAll { FilePath($0) == directory }
        entries.insert(directory.string, at: min(1, entries.count))
        return entries.joined(separator: ";")
    }

    private static func notSupportedYet(_ operation: String) -> SwiftlyError {
        SwiftlyError(message: "\(operation) isn't supported on Windows yet.")
    }

    public static let currentPlatform: any Platform = Windows()
}
