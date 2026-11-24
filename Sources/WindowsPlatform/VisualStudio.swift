import _StringProcessing
import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage
import WinSDK

/// Swift on Windows links programs against the Microsoft C runtime and the Windows SDK, which come
/// with Visual Studio or its Build Tools ("Desktop development with C++" or the individual components),
/// as with the swift.org installer. swiftly checks for them but doesn't install them.
enum VisualStudio {
    enum Status: Equatable {
        /// Visual Studio with the C++ tools for this architecture and a Windows SDK.
        case ready(installation: FilePath)
        /// Visual Studio is installed, but without the C++ tools or without a Windows SDK.
        case missingComponents(installation: FilePath, cppTools: Bool, windowsSDK: Bool)
        case notInstalled
    }

    static var cppToolsComponent: String {
#if arch(arm64)
        "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
#else
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
#endif
    }

    static var arch: String {
#if arch(arm64)
        "arm64"
#else
        "x64"
#endif
    }

    /// The components swift.org's instructions install, for both architectures. They're in the
    /// catalogs of Visual Studio 2022 (17.10 and later) and 2026.
    static let components = [
        "Microsoft.VisualStudio.Component.Windows11SDK.26100",
        "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "Microsoft.VisualStudio.Component.VC.Tools.ARM64",
    ]

    static func detect() async -> Status {
        // -prerelease: Visual Studio previews and Insiders count too.
        let any = await self.vswhere(["-latest", "-prerelease", "-products", "*", "-property", "installationPath"])
        guard let installation = any else {
            return .notInstalled
        }
        let withTools = await self.vswhere(["-latest", "-prerelease", "-products", "*", "-requires", self.cppToolsComponent, "-property", "installationPath"])
        let sdk = self.windowsSDKInstalled()
        if let withTools, sdk {
            return .ready(installation: withTools)
        }
        return .missingComponents(installation: withTools ?? installation, cppTools: withTools != nil, windowsSDK: sdk)
    }

    /// Runs vswhere (which the Visual Studio Installer installs) and returns its first output line.
    private static func vswhere(_ arguments: [String]) async -> FilePath? {
        guard let programFiles = ProcessInfo.processInfo.environment["ProgramFiles(x86)"] else {
            return nil
        }
        let vswhere = FilePath(programFiles) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        guard FileManager.default.fileExists(atPath: vswhere.string),
              let result = try? await run(.path(vswhere), arguments: Arguments(arguments + ["-utf8", "-nologo"]), output: .string(limit: 64 * 1024), error: .discarded),
              result.terminationStatus.isSuccess,
              let line = result.standardOutput.split(whereSeparator: \.isNewline).first, !line.isEmpty
        else {
            return nil
        }
        return FilePath(String(line).trimmingCharacters(in: .whitespaces))
    }

    /// Whether the newest Windows 10+ SDK, which clang uses, has the headers and import libraries
    /// for this architecture, both of the Windows API (um) and of the C runtime (ucrt).
    static func windowsSDKInstalled() -> Bool {
        let roots = [
            #"SOFTWARE\Microsoft\Windows Kits\Installed Roots"#,
            #"SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots"#,
        ].compactMap { key in (try? Win32.withKey(HKEY_LOCAL_MACHINE, key, writable: false) { try Win32.readString($0, "KitsRoot10") }) ?? nil }
        for root in roots.map({ FilePath(Win32.expandEnvironmentStrings($0.value)) }) {
            let versions = ((try? FileManager.default.contentsOfDirectory(atPath: (root / "Include").string)) ?? [])
                .filter { $0.hasPrefix("10.") && FileManager.default.fileExists(atPath: (root / "Include" / $0 / "um" / "windows.h").string) }
            guard let newest = versions.max(by: { self.versionComponents($0).lexicographicallyPrecedes(self.versionComponents($1)) }) else {
                continue
            }
            return self.sdkIsComplete(root: root, version: newest, arch: self.arch, exists: { FileManager.default.fileExists(atPath: $0.string) })
        }
        return false
    }

    /// Whether the SDK `version` at `root` has the files Swift needs for `arch`.
    static func sdkIsComplete(root: FilePath, version: String, arch: String, exists: (FilePath) -> Bool) -> Bool {
        [
            root / "Include" / version / "um" / "windows.h",
            root / "Include" / version / "ucrt" / "stdio.h",
            root / "Lib" / version / "um" / arch / "kernel32.lib",
            root / "Lib" / version / "ucrt" / arch / "ucrt.lib",
        ].allSatisfy(exists)
    }

    static func versionComponents(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0) ?? 0 }
    }

    /// What to run to get the missing pieces, for swiftly's post-install script; nil when ready.
    static func instructions(for status: Status) -> String? {
        let adds = self.components.map { "--add \($0)" }.joined(separator: " ")
        switch status {
        case .ready:
            return nil
        case .notInstalled:
            // Visual Studio 2022 on purpose: the STL of Visual Studio 2026 (14.50 and later) needs
            // clang 22, newer than current toolchains' (error STL1000).
            return """
            # Swift needs Visual Studio with the C++ tools and a Windows SDK to build programs.
            # Install Visual Studio Community (see whether its license terms cover you):
            winget install --id Microsoft.VisualStudio.2022.Community --exact --force --custom "\(adds)" --source winget
            # Or only the Build Tools, without the IDE (they need a Visual Studio license too):
            # winget install --id Microsoft.VisualStudio.2022.BuildTools --exact --force --custom "\(adds)" --source winget
            """
        case let .missingComponents(installation, cppTools, windowsSDK):
            let missing = [cppTools ? nil : "the C++ tools", windowsSDK ? nil : "a Windows SDK"].compactMap { $0 }.joined(separator: " and ")
            return """
            # Visual Studio at \(installation) doesn't have \(missing), which Swift needs to build programs.
            # Add the "Desktop development with C++" workload in the Visual Studio Installer, or these components:
            & "${env:ProgramFiles(x86)}\\Microsoft Visual Studio\\Installer\\setup.exe" modify --installPath "\(installation)" \(adds)
            """
        }
    }

    // MARK: The STL and the toolchain's clang

    /// The clang major version the default MSVC toolset's STL requires (`yvals_core.h`), if known.
    static func requiredClangMajor(installation: FilePath) -> Int? {
        let defaultFile = installation / "VC" / "Auxiliary" / "Build" / "Microsoft.VCToolsVersion.default.txt"
        guard let version = (try? String(contentsOfFile: defaultFile.string, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines),
              let header = try? String(contentsOfFile: (installation / "VC" / "Tools" / "MSVC" / version / "include" / "yvals_core.h").string, encoding: .utf8)
        else {
            return nil
        }
        return self.requiredClangMajor(yvalsCore: header)
    }

    /// Reads the check `#if __clang_major__ < N` ... STL1000 in yvals_core.h.
    static func requiredClangMajor(yvalsCore header: String) -> Int? {
        header.firstMatch(of: #/__clang_major__\s*<\s*(\d+)/#).flatMap { Int($0.output.1) }
    }

    /// The major version of the clang in a toolchain's bin directory.
    static func clangMajor(bin: FilePath) async -> Int? {
        guard let result = try? await run(.path(bin / "clang.exe"), arguments: ["--version"], output: .string(limit: 64 * 1024), error: .discarded) else {
            return nil
        }
        return result.standardOutput.firstMatch(of: #/clang version (\d+)/#).flatMap { Int($0.output.1) }
    }
}
