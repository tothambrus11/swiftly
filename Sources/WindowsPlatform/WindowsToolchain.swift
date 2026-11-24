import _StringProcessing
import CMsi
import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// Where the pieces of a toolchain installed by swiftly live.
///
/// swiftly keeps the swift.org installer's layout, one per version, side by side:
///
/// ```
/// <swiftly home>\toolchains\6.4.3\
///   Toolchains\6.4.3+Asserts\usr\bin     swift.exe, clang.exe, ...
///   Runtimes\6.4.3\usr\bin               swiftCore.dll, Foundation.dll, ...
///   Platforms\6.4.3\Windows.platform\Developer\SDKs\Windows.sdk
/// ```
struct WindowsToolchainLayout {
    /// The `toolchains\<version>` directory.
    var root: FilePath
    /// The toolchain, which holds `usr\bin\swift.exe`.
    var toolchain: FilePath
    /// The directory with the Swift runtime DLLs.
    var runtimeBin: FilePath
    /// The Windows SDK, what `SDKROOT` points at.
    var sdk: FilePath

    var bin: FilePath { self.toolchain / "usr" / "bin" }

    /// Reads the layout of the toolchain in `root`, or returns nil if there isn't a complete one.
    static func read(_ root: FilePath) -> Self? {
        func onlyChild(_ dir: FilePath) -> FilePath? {
            guard let children = try? FileManager.default.contentsOfDirectory(atPath: dir.string), children.count == 1 else {
                return nil
            }
            return dir / children[0]
        }
        guard let toolchain = onlyChild(root / "Toolchains"),
              let runtime = onlyChild(root / "Runtimes"),
              let platform = onlyChild(root / "Platforms")
        else {
            return nil
        }
        let sdk = platform / "Windows.platform" / "Developer" / "SDKs" / "Windows.sdk"
        guard FileManager.default.fileExists(atPath: (toolchain / "usr" / "bin" / "swift.exe").string),
              FileManager.default.fileExists(atPath: sdk.string)
        else {
            return nil
        }
        return Self(root: root, toolchain: toolchain, runtimeBin: runtime / "usr" / "bin", sdk: sdk)
    }
}

/// Installs a toolchain from the swift.org Windows installer without running it: the installer's
/// MSIs are unpacked with administrative installs, which copy their files to a directory and change
/// nothing else on the system (no registry entries, no Path changes, no administrator rights).
enum WindowsToolchain {
    /// The MSI packages of the installer that make up a toolchain swiftly installs.
    struct PackageSelection: Equatable {
        /// The compiler, SwiftPM and the Windows SDK, unpacked into one directory.
        var toolchain: [String]
        /// The runtime DLLs for this machine's architecture.
        var runtime: String
        /// Packages that may have side-by-side assemblies the toolchain's tools need, in the order
        /// to look in.
        var assemblyDonors: [String]
    }

    /// Picks the packages to install from the installer's packages.
    ///
    /// Like the installer by default, this prefers the asserts build of the toolchain. The debugger
    /// (dbg), Python, the IDE support (ide) and the Android SDK are left out; `cli` needs a few of the
    /// side-by-side assemblies `ide` ships, which `assemblyDonors` provides.
    static func selectPackages(_ ids: [String], arch: String) throws -> PackageSelection {
        let available = Set(ids.map { $0.lowercased() })
        func pick(_ candidates: String...) -> String? {
            candidates.first { available.contains($0) }
        }
        var toolchain: [String] = []
        for component in ["bld", "cli"] {
            guard let id = pick("\(component).asserts.msi", "\(component).msi") else {
                throw SwiftlyError(message: "The installer has no \(component) package.")
            }
            toolchain.append(id)
        }
        guard let sdk = pick("windows.msi") else {
            throw SwiftlyError(message: "The installer has no Windows SDK package.")
        }
        toolchain.append(sdk)
        guard let runtime = pick("rtl.\(arch).msi", "rtl.msi") else {
            throw SwiftlyError(message: "The installer has no runtime package for \(arch).")
        }
        let donors = [pick("ide.asserts.msi", "ide.msi"), pick("dbg.asserts.msi", "dbg.msi")].compactMap { $0 }
        return PackageSelection(toolchain: toolchain, runtime: runtime, assemblyDonors: donors)
    }

    /// The architecture name the installer's runtime packages use.
    static var runtimeArch: String {
#if arch(arm64)
        "arm64"
#else
        "amd64"
#endif
    }

    /// Unpacks the installer `bundle` into `destination` (a `toolchains\<version>` directory).
    static func install(_ ctx: SwiftlyCoreContext, bundle: FilePath, to destination: FilePath, verbose: Bool) async throws {
        let work = try self.shortTemporaryDirectory(near: destination.removingLastComponent())
        try await fs.mkdir(.parents, atPath: work)
        try await fs.withTemporary(files: work) {
            var selection: PackageSelection?
            let (_, msis) = try await BurnBundle.extract(bundle, into: work / "b", select: { manifest in
                let picked = try self.selectPackages(manifest.packages.map(\.id), arch: self.runtimeArch)
                selection = picked
                return picked.toolchain + [picked.runtime] + picked.assemblyDonors
            }, verbose: verbose)
            guard let selection else {
                throw SwiftlyError(message: "No packages were selected from the installer.")
            }
            func msi(_ id: String) throws -> FilePath {
                guard let path = msis[id] ?? msis.first(where: { $0.key.lowercased() == id })?.value else {
                    throw SwiftlyError(message: "The installer's \(id) package is missing.")
                }
                return path
            }

            // Per-user packages land in <TARGETDIR>\LocalApp\Programs\Swift, the toolchain's usual
            // home. TARGETDIR is short: deep paths in an administrative install fail with error 1603.
            let target = work / "t"
            for id in selection.toolchain {
                await ctx.message("Unpacking \(id)...")
                try self.administrativeInstall(msi(id), to: target, log: work / "\(id).log")
            }
            let swiftRoot = target / "LocalApp" / "Programs" / "Swift"
            guard let platform = try? FileManager.default.contentsOfDirectory(atPath: (swiftRoot / "Platforms").string).first else {
                throw SwiftlyError(message: "The installer's Windows SDK package didn't contain a platform.")
            }

            // The runtime package's files land directly in TARGETDIR; give them their usual home.
            await ctx.message("Unpacking \(selection.runtime)...")
            let runtimeTarget = work / "r"
            try self.administrativeInstall(msi(selection.runtime), to: runtimeTarget, log: work / "rtl.log")
            let perUserRuntimes = runtimeTarget / "LocalApp" / "Programs" / "Swift" / "Runtimes"
            if try await fs.exists(atPath: perUserRuntimes) {
                try await fs.mkdir(.parents, atPath: swiftRoot / "Runtimes")
                for runtime in try await fs.ls(atPath: perUserRuntimes) {
                    try await fs.move(atPath: perUserRuntimes / runtime, toPath: swiftRoot / "Runtimes" / runtime)
                }
                try await fs.remove(atPath: runtimeTarget / "LocalApp")
            }
            let looseFiles = try await fs.ls(atPath: runtimeTarget).filter { !$0.lowercased().hasSuffix(".msi") }
            if !looseFiles.isEmpty {
                let runtimeBin = swiftRoot / "Runtimes" / platform / "usr" / "bin"
                try await fs.mkdir(.parents, atPath: runtimeBin)
                for file in looseFiles {
                    try await fs.move(atPath: runtimeTarget / file, toPath: runtimeBin / file)
                }
            }

            guard let toolchainName = try? FileManager.default.contentsOfDirectory(atPath: (swiftRoot / "Toolchains").string).first else {
                throw SwiftlyError(message: "The installer's toolchain package didn't contain a toolchain.")
            }
            let bin = swiftRoot / "Toolchains" / toolchainName / "usr" / "bin"
            try await self.addMissingAssemblies(ctx, bin: bin, donors: selection.assemblyDonors.map(msi), work: work)
            // The unpacked installer payloads take up more than a gigabyte and aren't needed anymore.
            try await fs.remove(atPath: work / "b")
            try self.linkDuplicates(in: swiftRoot)

            try await fs.move(atPath: swiftRoot, toPath: destination)
        }
    }

    /// A new directory with a short path to unpack into, next to `preferred` when that is short
    /// enough and in the temporary directory otherwise.
    static func shortTemporaryDirectory(near preferred: FilePath) throws -> FilePath {
        let name = "s" + UUID().uuidString.prefix(6).lowercased()
        if preferred.string.count <= 48 {
            return preferred / name
        }
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let length = GetTempPathW(DWORD(buffer.count), &buffer)
        guard length > 0 else {
            throw Win32.error("GetTempPathW")
        }
        let temp = FilePath(String(decoding: buffer[..<Int(length)], as: UTF16.self))
        return temp / name
    }

    /// Unpacks an MSI with an administrative install (`msiexec /a`), through the Windows Installer API.
    static func administrativeInstall(_ msi: FilePath, to target: FilePath, log: FilePath) throws {
        _ = MsiSetInternalUI(INSTALLUILEVEL_NONE, nil)
        let logMode = DWORD(INSTALLLOGMODE_FATALEXIT.rawValue | INSTALLLOGMODE_ERROR.rawValue | INSTALLLOGMODE_WARNING.rawValue | INSTALLLOGMODE_INFO.rawValue)
        _ = log.string.withCString(encodedAs: UTF16.self) { MsiEnableLogW(logMode, $0, 0) }
        defer { _ = MsiEnableLogW(0, nil, 0) }

        let commandLine = "ACTION=ADMIN TARGETDIR=\"\(target.string)\""
        let status = msi.string.withCString(encodedAs: UTF16.self) { msiW in
            commandLine.withCString(encodedAs: UTF16.self) { MsiInstallProductW(msiW, $0) }
        }
        guard status == UINT(ERROR_SUCCESS) else {
            let details = self.readLog(log)
                .split(whereSeparator: \.isNewline)
                .filter { $0.contains("Error") || $0.contains("error") || $0.contains("Return value 3") }
                .suffix(10)
                .joined(separator: "\n")
            throw SwiftlyError(message: "Unpacking \(msi.lastComponent?.string ?? msi.string) failed with Windows Installer error \(status).\n\(details)")
        }
        // An administrative image keeps a copy of the package at its root.
        for file in (try? FileManager.default.contentsOfDirectory(atPath: target.string)) ?? [] where file.lowercased().hasSuffix(".msi") {
            try? FileManager.default.removeItem(atPath: (target / file).string)
        }
    }

    /// Windows Installer writes its logs as UTF-16 with a byte order mark, or in the ANSI code page.
    private static func readLog(_ log: FilePath) -> String {
        guard let data = FileManager.default.contents(atPath: log.string) else {
            return ""
        }
        if data.starts(with: [0xFF, 0xFE]) {
            let units = stride(from: 2, to: data.count - 1, by: 2).map { UInt16(data[data.startIndex + $0]) | UInt16(data[data.startIndex + $0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The private side-by-side assemblies (`<name>\<name>.dll` next to the executable) the
    /// executables in `bin` depend on but that aren't there.
    static func missingAssemblies(in bin: FilePath) throws -> Set<String> {
        var missing: Set<String> = []
        for file in try FileManager.default.contentsOfDirectory(atPath: bin.string) where file.lowercased().hasSuffix(".exe") {
            guard let manifest = Win32.embeddedManifest(of: bin / file) else {
                continue
            }
            for name in self.dependentAssemblies(inManifest: manifest)
                where !name.hasPrefix("Microsoft.") && !FileManager.default.fileExists(atPath: (bin / name).string)
            {
                missing.insert(name)
            }
        }
        return missing
    }

    /// The names of the assemblies an application manifest depends on.
    static func dependentAssemblies(inManifest manifest: String) -> [String] {
        manifest.matches(of: #/<dependentAssembly>.*?<assemblyIdentity\s[^>]*?name="([^"]+)"/#.dotMatchesNewlines()).map { String($0.output.1) }
    }

    /// Copies the side-by-side assemblies the toolchain's tools need but its packages don't include
    /// from the donor packages. (The installer ships FoundationXML and swiftRegexBuilder for
    /// swift-build.exe only in the IDE support package; without them SwiftPM fails with error 14001.)
    private static func addMissingAssemblies(_ ctx: SwiftlyCoreContext, bin: FilePath, donors: [FilePath], work: FilePath) async throws {
        var missing = try self.missingAssemblies(in: bin)
        for (index, donor) in donors.enumerated() where !missing.isEmpty {
            await ctx.message("Unpacking \(missing.sorted().joined(separator: ", ")) from \(donor.lastComponent?.string ?? "")...")
            let target = work / "x\(index)"
            try self.administrativeInstall(donor, to: target, log: work / "donor\(index).log")
            let toolchains = target / "LocalApp" / "Programs" / "Swift" / "Toolchains"
            for toolchain in (try? FileManager.default.contentsOfDirectory(atPath: toolchains.string)) ?? [] {
                let donorBin = toolchains / toolchain / "usr" / "bin"
                for name in missing where FileManager.default.fileExists(atPath: (donorBin / name).string) {
                    try FileManager.default.copyItem(atPath: (donorBin / name).string, toPath: (bin / name).string)
                }
            }
            try? FileManager.default.removeItem(atPath: target.string)
            missing = try self.missingAssemblies(in: bin)
        }
        if !missing.isEmpty {
            await ctx.message("Warning: the toolchain is missing the side-by-side assemblies \(missing.sorted().joined(separator: ", ")).")
        }
    }

    /// Replaces identical copies of large files with hard links to one of them. The installer ships
    /// the same binary under many names (clang, clang++, clang-cl; lld-link, ld.lld; swift-frontend,
    /// swift-symbolgraph-extract, ...), which saves about a gigabyte per toolchain.
    static func linkDuplicates(in root: FilePath) throws {
        var bySize: [Int: [FilePath]] = [:]
        guard let enumerator = FileManager.default.enumerator(atPath: root.string) else {
            return
        }
        while let relative = enumerator.nextObject() as? String {
            let path = root / relative
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path.string),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.intValue, size >= 1024 * 1024
            else {
                continue
            }
            bySize[size, default: []].append(path)
        }
        for (_, files) in bySize where files.count > 1 {
            var byHash: [String: FilePath] = [:]
            for file in files {
                let digest = try Win32.hash(.sha256, file: file)
                guard let original = byHash[digest] else {
                    byHash[digest] = file
                    continue
                }
                try FileManager.default.removeItem(atPath: file.string)
                try Win32.createHardLink(at: file, to: original)
            }
        }
    }
}
