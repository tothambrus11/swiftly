import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage

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

    public var toolchainFileExtension: String {
        "exe"
    }

    public func install(
        _ ctx: SwiftlyCoreContext, from tmpFile: FilePath, version: ToolchainVersion, verbose: Bool
    ) async throws {
        guard try await fs.exists(atPath: tmpFile) else {
            throw SwiftlyError(message: "\(tmpFile) doesn't exist")
        }

        let toolchainsDir = self.swiftlyToolchainsDir(ctx)
        if !(try await fs.exists(atPath: toolchainsDir)) {
            try await fs.mkdir(.parents, atPath: toolchainsDir)
        }

        let toolchainDir = toolchainsDir / version.name
        if try await fs.exists(atPath: toolchainDir) {
            try await fs.remove(atPath: toolchainDir)
        }

        await ctx.message("Extracting toolchain...")
        try await WindowsToolchain.install(ctx, bundle: tmpFile, to: toolchainDir, verbose: verbose)

        guard let layout = WindowsToolchainLayout.read(toolchainDir) else {
            throw SwiftlyError(message: "The installer for \(version) didn't contain a complete toolchain.")
        }
        _ = layout
    }

    public func extractSwiftlyAndInstall(_: SwiftlyCoreContext, from _: FilePath) async throws {
        throw Self.notSupportedYet("Installing swiftly")
    }

    public func uninstall(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion, verbose _: Bool) async throws {
        let toolchainDir = self.swiftlyToolchainsDir(ctx) / toolchain.name
        if try await fs.exists(atPath: toolchainDir) {
            try await fs.remove(atPath: toolchainDir)
            return
        }
        if self.installedToolchains().contains(where: { $0.version == toolchain }) {
            throw SwiftlyError(message: """
            \(toolchain) was installed with the swift.org installer, not with swiftly. Uninstall it \
            from Settings > Apps > Installed apps.
            """)
        }
    }

    public func getExecutableName() -> String {
        "swiftly-\(cpuArch)-unknown-windows-msvc.exe"
    }

    public func verifySwiftlySystemPrerequisites() async throws {
        // Nothing beyond Windows itself is needed to run swiftly.
    }

    public func verifySystemPrerequisitesForInstall(
        _: SwiftlyCoreContext, platformName _: String, version _: ToolchainVersion,
        requireSignatureValidation _: Bool
    ) async throws -> String? {
        // Linking programs needs Visual Studio with the C++ tools and a Windows SDK, as with the
        // swift.org installer.
        nil
    }

    /// The subject of the certificate swift.org signs its Windows installers with.
    static let toolchainSigner = "Apple Inc."

    public func verifyToolchainSignature(
        _ ctx: SwiftlyCoreContext, toolchainFile _: ToolchainFile, archive: FilePath, verbose: Bool
    ) async throws {
        // swift.org doesn't publish PGP signatures for its Windows installers. They carry
        // Authenticode signatures instead, which Windows itself checks.
        if verbose {
            await ctx.message("Verifying the toolchain's Authenticode signature...")
        }
        try Authenticode.verify(archive, signer: Self.toolchainSigner)
    }

    public func verifySwiftlySignature(
        _: SwiftlyCoreContext, archiveDownloadURL _: URL, archive _: FilePath, verbose _: Bool
    ) async throws {
        throw Self.notSupportedYet("Verifying swiftly signatures")
    }

    public func detectPlatform(
        _: SwiftlyCoreContext, disableConfirmation _: Bool, platform _: String?
    ) async throws -> PlatformDefinition {
        PlatformDefinition(name: "win10", nameFull: "windows10", namePretty: "Windows 10")
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
        guard ctx.mockedHomeDir == nil else {
            return self.swiftlyToolchainsDir(ctx) / toolchain.identifier
        }
        if let layout = WindowsToolchainLayout.read(self.swiftlyToolchainsDir(ctx) / toolchain.name) {
            return layout.toolchain
        }
        guard let installed = self.installedToolchains().first(where: { $0.version == toolchain }) else {
            throw SwiftlyError(message: "Toolchain \(toolchain) isn't installed.")
        }
        return installed.root
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
        // which the toolchain finds on its own (or, with swiftly's sysroot, doesn't need).
        let runtimeBin: FilePath?
        let sdk: FilePath?
        if ctx.mockedHomeDir == nil, let layout = WindowsToolchainLayout.read(self.swiftlyToolchainsDir(ctx) / toolchain.name) {
            runtimeBin = layout.runtimeBin
            sdk = layout.sdk
        } else if let installed = MsiEnumeration.installed.first(where: { (try? ToolchainVersion(parsing: $0.version)) == toolchain }) {
            runtimeBin = installed.runtime
            sdk = installed.sdks.first { $0.lastComponent?.string == "Windows.sdk" }
        } else {
            return environment
        }

        var updates: [Environment.Key: String] = [:]
        if let runtimeBin {
            updates["Path"] = Self.insertingAfterFirst(runtimeBin, into: path)
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
