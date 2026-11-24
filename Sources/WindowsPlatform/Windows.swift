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
        _: SwiftlyCoreContext, from _: FilePath, version _: ToolchainVersion, verbose _: Bool
    ) async throws {
        throw Self.notSupportedYet("Installing toolchains")
    }

    public func extractSwiftlyAndInstall(_: SwiftlyCoreContext, from _: FilePath) async throws {
        throw Self.notSupportedYet("Installing swiftly")
    }

    public func uninstall(_: SwiftlyCoreContext, _: ToolchainVersion, verbose _: Bool) async throws {
        throw Self.notSupportedYet("Uninstalling toolchains")
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
        throw Self.notSupportedYet("Installing toolchains")
    }

    public func verifyToolchainSignature(
        _: SwiftlyCoreContext, toolchainFile _: ToolchainFile, archive _: FilePath, verbose _: Bool
    ) async throws {
        throw Self.notSupportedYet("Verifying toolchain signatures")
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

    // swiftly.exe isn't installed into its bin directory yet, and there are no proxies to run it;
    // both are a follow-up.
    public func installSwiftlyBin(_: SwiftlyCoreContext) async throws {}

    public func findSwiftlyBin(_: SwiftlyCoreContext) async throws -> FilePath? {
        nil
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
        return Set(self.installedToolchains().map(\.version))
    }

    public func findToolchainLocation(_ ctx: SwiftlyCoreContext, _ toolchain: ToolchainVersion) async throws -> FilePath {
        guard ctx.mockedHomeDir == nil else {
            return self.swiftlyToolchainsDir(ctx) / toolchain.identifier
        }
        guard let installed = self.installedToolchains().first(where: { $0.version == toolchain }) else {
            throw SwiftlyError(message: "Toolchain \(toolchain) isn't installed.")
        }
        return installed.root
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
        _: SwiftlyCoreContext, _ environment: Environment, _: ToolchainVersion, path _: String
    ) async throws -> Environment {
        environment
    }

    private static func notSupportedYet(_ operation: String) -> SwiftlyError {
        SwiftlyError(message: "\(operation) isn't supported on Windows yet.")
    }

    public static let currentPlatform: any Platform = Windows()
}
