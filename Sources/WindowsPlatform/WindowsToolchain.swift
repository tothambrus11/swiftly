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
/// <toolchains>\6.4.3\
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

    /// Where `recordPython` writes the Python directory, relative to the root.
    static let pythonRecord = "swiftly-python.txt"

    /// The directory with the Python DLL that lldb loads, as recorded at install time (so that
    /// proxies don't search for it on every run).
    var python: FilePath? {
        guard let relative = try? String(contentsOfFile: (self.root / Self.pythonRecord).string, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !relative.isEmpty
        else {
            return nil
        }
        return self.root / relative
    }

    /// Finds the Python directory and records it (see `python`).
    func recordPython() throws {
        guard let found = self.findPython(), found.starts(with: self.root) else {
            return
        }
        let relative = found.components.dropFirst(self.root.components.count).map(\.string).joined(separator: "\\")
        try Data(relative.utf8).write(to: self.root / Self.pythonRecord)
    }

    /// The directory with the Python DLL that lldb loads (python3*.dll), which the installer's
    /// Python package puts next to the toolchains, if it's there.
    func findPython() -> FilePath? {
        let skip: Set<String> = ["toolchains", "platforms", "runtimes"]
        var level = [self.root]
        for _ in 0..<3 {
            var next: [FilePath] = []
            for dir in level {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: dir.string)) ?? []
                if dir != self.root, children.contains(where: { $0.lowercased().hasPrefix("python3") && $0.lowercased().hasSuffix(".dll") }) {
                    return dir
                }
                next += children.filter { !(dir == self.root && skip.contains($0.lowercased())) }.map { dir / $0 }.filter {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: $0.string, isDirectory: &isDirectory) && isDirectory.boolValue
                }
            }
            level = next
        }
        return nil
    }

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
        guard FileManager.default.fileExists(atPath: (toolchain / "usr" / "bin").string),
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
        /// The other packages the installer installs by default: the IDE support (sourcekit-lsp,
        /// clangd), the debugger (lldb, lldb-dap), Python for lldb and, in snapshots, the
        /// toolchain's private runtime (prt).
        var others: [String] = []
    }

    /// Packages swiftly leaves out although they match the installer's conditions: the Android SDK
    /// (swiftly installs Swift for Windows).
    static let optionalPackagePrefixes = ["android"]

    /// The variables swiftly sets differently from the bundle's defaults: no Android SDK.
    static func overriddenVariables(_ variables: [String: String]) -> [String: String] {
        var variables = variables
        for name in variables.keys where name.lowercased().contains("android") {
            variables[name] = "0"
        }
        return variables
    }

    /// The packages the installer would install on this machine: those whose `InstallCondition`
    /// holds with the bundle's variable defaults (and swiftly's overrides, and the machine type,
    /// Burn's `NativeMachine`), selected as `selectPackages(_:arch:)` does.
    static func selectPackages(_ manifest: BurnManifest, arch: String) throws -> PackageSelection {
        var variables = self.overriddenVariables(manifest.variables)
        var numeric = manifest.numericVariables
        if variables["NativeMachine"] == nil {
            variables["NativeMachine"] = arch == "arm64" ? "43620" : "34404"
            numeric.insert("NativeMachine")
        }
        // The optional packages are left out before their conditions are looked at, so that one
        // swiftly can't evaluate doesn't stop an install it isn't part of.
        let candidates = manifest.packages.filter { package in
            !self.optionalPackagePrefixes.contains { package.id.lowercased().hasPrefix($0) }
        }
        let installed = try candidates.filter { package in
            try package.installCondition.map { try BurnCondition.evaluate($0, variables: variables, numeric: numeric) } ?? true
        }
        return try self.selectPackages(installed.map(\.id), arch: arch)
    }

    /// Picks the packages to install from those the installer installs (compared
    /// case-insensitively; the result is lowercased): all of them except the optional ones, other
    /// architectures' runtimes and, where both are there, the no-asserts toolchain (the
    /// installer prefers the asserts one too).
    static func selectPackages(_ ids: [String], arch: String) throws -> PackageSelection {
        let available = ids.map { $0.lowercased() }.filter { $0.hasSuffix(".msi") }
        let set = Set(available)
        func pick(_ candidates: String...) -> String? {
            candidates.first { set.contains($0) }
        }
        func component(_ id: String) -> String {
            String(id.prefix { $0 != "." })
        }
        var toolchain: [String] = []
        for name in ["bld", "cli"] {
            guard let id = pick("\(name).asserts.msi", "\(name).msi") else {
                throw SwiftlyError(message: "The installer has no \(name) package.")
            }
            toolchain.append(id)
        }
        guard let sdk = pick("windows.msi") else {
            throw SwiftlyError(message: "The installer has no Windows SDK package (windows.msi); swiftly installs Swift 6.2 and later on Windows.")
        }
        toolchain.append(sdk)
        guard let runtime = pick("rtl.\(arch).msi", "rtl.msi") else {
            throw SwiftlyError(message: "The installer has no runtime package for \(arch).")
        }
        let others = available.filter { id in
            let name = component(id)
            return !toolchain.contains(id) && name != "rtl" && name != "bld" && name != "cli"
                && !self.optionalPackagePrefixes.contains { name.hasPrefix($0) }
                && !(id.contains(".noasserts.") && set.contains(id.replacingOccurrences(of: ".noasserts.", with: ".asserts.")))
        }
        return PackageSelection(toolchain: toolchain, runtime: runtime, others: others)
    }

    /// The architecture name the installer's runtime packages use.
    static var runtimeArch: String {
#if arch(arm64)
        "arm64"
#else
        "amd64"
#endif
    }

    // MARK: Staging

    /// The directory a toolchain is unpacked in before it's moved into `toolchainsDir`, on the same
    /// volume, with as short a path as possible: deep paths in administrative installs fail with
    /// Windows Installer error 1603. Left-overs of interrupted installs are removed.
    static func makeStagingDirectory(in toolchainsDir: FilePath) throws -> FilePath {
        let area = self.stagingArea(in: toolchainsDir)
        // What earlier installs and uninstalls left behind; whatever is still in use stays for later.
        for leftover in (try? FileManager.default.contentsOfDirectory(atPath: area.string)) ?? [] {
            try? FileManager.default.removeItem(atPath: (area / leftover).string)
        }
        let staging = area / Windows.newStamp()
        try FileManager.default.createDirectory(atPath: staging.string, withIntermediateDirectories: true)
        return Self.shortPath(staging) ?? staging
    }

    /// Where installs unpack and uninstalls move toolchains to delete: in the toolchains directory,
    /// so on its volume, where renames move directories without copying.
    static func stagingArea(in toolchainsDir: FilePath) -> FilePath {
        toolchainsDir / "_"
    }

    /// Removes the staging area when nothing is left in it, so the toolchains directory has only toolchains.
    static func removeStagingAreaIfEmpty(in toolchainsDir: FilePath) {
        let area = self.stagingArea(in: toolchainsDir)
        if (try? FileManager.default.contentsOfDirectory(atPath: area.string))?.isEmpty == true {
            try? FileManager.default.removeItem(atPath: area.string)
        }
    }

    /// The 8.3 form of an existing path, if the volume has short names. ReFS volumes (such as Dev
    /// Drives) and NTFS volumes with short names turned off have none, so there the long path is
    /// used and very deep toolchain directories can still fail with error 1603.
    static func shortPath(_ path: FilePath) -> FilePath? {
        path.string.withCString(encodedAs: UTF16.self) { pathW in
            let length = GetShortPathNameW(pathW, nil, 0)
            guard length > 0 else { return nil }
            var buffer = [WCHAR](repeating: 0, count: Int(length))
            guard GetShortPathNameW(pathW, &buffer, length) > 0 else { return nil }
            return FilePath(String(decodingCString: buffer, as: UTF16.self))
        }
    }

    // MARK: Installing

    /// Unpacks `file`, a swift.org installer or a zip archive with the installer's layout, into
    /// `staging` and returns the unpacked toolchain root (Toolchains, Runtimes, Platforms).
    static func unpack(_ ctx: SwiftlyCoreContext, _ file: FilePath, staging: FilePath, verbose: Bool) async throws -> FilePath {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.string))
        let magic = try handle.read(upToCount: 2) ?? Data()
        try handle.close()

        let root: FilePath
        if magic == Data([0x50, 0x4B]) { // "PK": a zip archive
            // Only tests' own toolchain archives are zip files; swift.org's are installers.
            guard ctx.installsTestToolchains else {
                throw SwiftlyError(message: "\(file) isn't a swift.org toolchain installer.")
            }
            root = staging / "z"
            try await fs.mkdir(.parents, atPath: root)
            // tar.exe (bsdtar) ships with Windows; the archive is copied next to it so that the
            // command line has only short ASCII names.
            try FileManager.default.copyItem(atPath: file.string, toPath: (staging / "archive.zip").string)
            try await Win32.runTool("tar.exe", ["-xf", "..\\archive.zip"], in: root)
        } else {
            root = try await self.unpackInstaller(ctx, file, staging: staging, verbose: verbose)
        }
        try self.prune(root)
        try self.linkDuplicates(in: root)
        return root
    }

    private static func unpackInstaller(_ ctx: SwiftlyCoreContext, _ bundle: FilePath, staging: FilePath, verbose: Bool) async throws -> FilePath {
        var selection: PackageSelection?
        let msis = try await BurnBundle.extract(ctx, bundle, into: staging / "b", select: { manifest in
            let picked = try self.selectPackages(manifest, arch: self.runtimeArch)
            selection = picked
            return picked.toolchain + [picked.runtime] + picked.others
        }, verbose: verbose)
        guard let selection else {
            throw SwiftlyError(message: "No packages were selected from the installer.")
        }
        func msi(_ id: String) throws -> FilePath {
            guard let path = msis[id.lowercased()] else {
                throw SwiftlyError(message: "The installer's \(id) package is missing.")
            }
            return path
        }

        // Per-user packages land in <TARGETDIR>\LocalApp\Programs\Swift, the toolchain's usual home;
        // per-machine ones under the Program Files folder in TARGETDIR. `swiftRoot` finds either.
        let target = staging / "t"
        for id in selection.toolchain {
            if verbose {
                await ctx.message("Unpacking \(id)...")
            }
            try self.administrativeInstall(msi(id), to: target, log: staging / "\(id).log")
        }
        guard let swiftRoot = self.swiftRoot(in: target),
              let platform = try? FileManager.default.contentsOfDirectory(atPath: (swiftRoot / "Platforms").string).first
        else {
            throw SwiftlyError(message: "The installer's Windows SDK package didn't contain a platform. It unpacked: \(self.describeTree(target)).")
        }

        // The runtime package's files land directly in TARGETDIR; give them their usual home.
        if verbose {
            await ctx.message("Unpacking \(selection.runtime)...")
        }
        let runtimeTarget = staging / "r"
        try self.administrativeInstall(msi(selection.runtime), to: runtimeTarget, log: staging / "rtl.log")
        if let runtimeRoot = self.swiftRoot(in: runtimeTarget) {
            try self.merge(runtimeRoot, into: swiftRoot)
            try self.removeTopDirectory(of: runtimeRoot, in: runtimeTarget)
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

        // The other packages: files under the per-user directory join the others there; files
        // that land directly in TARGETDIR (as the runtime's do) are the toolchain's.
        for id in selection.others {
            if verbose {
                await ctx.message("Unpacking \(id)...")
            }
            let otherTarget = staging / "x"
            try self.administrativeInstall(msi(id), to: otherTarget, log: staging / "\(id).log")
            if verbose {
                await ctx.message("\(id) unpacked: \(self.describeTree(otherTarget))")
            }
            // Its files go where the installer puts them relative to the Swift directory: into the
            // layout (Toolchains, ...) or next to it (Python, for lldb).
            if let otherRoot = self.swiftRoot(in: otherTarget) ?? self.swiftDirectory(in: otherTarget) {
                try self.merge(otherRoot, into: swiftRoot)
                try self.removeTopDirectory(of: otherRoot, in: otherTarget)
            }
            // Anything else such a package puts directly in TARGETDIR isn't part of the layout.
            try? FileManager.default.removeItem(atPath: otherTarget.string)
        }
        try await self.addMissingAssemblies(ctx, bin: bin, root: swiftRoot, verbose: verbose)
        // The unpacked installer payloads take more than a gigabyte and aren't needed anymore.
        try await fs.remove(atPath: staging / "b")
        return swiftRoot
    }

    /// The directory an administrative install into `target` put the Swift layout in: the one with
    /// Toolchains, Platforms or Runtimes, such as `LocalApp\Programs\Swift` (per-user packages) or
    /// a Program Files folder's `Swift` (per-machine ones).
    static func swiftRoot(in target: FilePath) -> FilePath? {
        var level = [target]
        for _ in 0..<5 {
            var next: [FilePath] = []
            for dir in level {
                let children = (try? FileManager.default.contentsOfDirectory(atPath: dir.string)) ?? []
                if dir != target, children.contains(where: { ["toolchains", "platforms", "runtimes"].contains($0.lowercased()) }) {
                    return dir
                }
                next += children.map { dir / $0 }.filter {
                    var isDirectory: ObjCBool = false
                    return FileManager.default.fileExists(atPath: $0.string, isDirectory: &isDirectory) && isDirectory.boolValue
                }
            }
            level = next
        }
        return nil
    }

    /// The `Swift` directory an administrative install into `target` created, for packages whose
    /// files aren't in the Toolchains/Platforms/Runtimes layout (such as Python).
    static func swiftDirectory(in target: FilePath) -> FilePath? {
        var level = [target]
        for _ in 0..<4 {
            var next: [FilePath] = []
            for dir in level {
                for child in (try? FileManager.default.contentsOfDirectory(atPath: dir.string)) ?? [] {
                    let path = dir / child
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: path.string, isDirectory: &isDirectory), isDirectory.boolValue else {
                        continue
                    }
                    if child.lowercased() == "swift" {
                        return path
                    }
                    next.append(path)
                }
            }
            level = next
        }
        return nil
    }

    /// Removes the directory of `target` that `path` is in.
    static func removeTopDirectory(of path: FilePath, in target: FilePath) throws {
        guard path.starts(with: target), let first = path.components.dropFirst(target.components.count).first else {
            return
        }
        try FileManager.default.removeItem(atPath: (target / first.string).string)
    }

    /// What's in `dir`, two levels deep, for error messages.
    static func describeTree(_ dir: FilePath) -> String {
        let top = (try? FileManager.default.contentsOfDirectory(atPath: dir.string)) ?? []
        return top.sorted().map { name in
            let children = ((try? FileManager.default.contentsOfDirectory(atPath: (dir / name).string)) ?? []).sorted()
            return children.isEmpty ? name : "\(name) (\(children.joined(separator: ", ")))"
        }.joined(separator: "; ")
    }

    /// Moves the contents of `source` into `destination`, merging directories that are in both.
    static func merge(_ source: FilePath, into destination: FilePath) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: destination.string, withIntermediateDirectories: true)
        for name in try manager.contentsOfDirectory(atPath: source.string) {
            let from = source / name
            let to = destination / name
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: to.string, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    try self.merge(from, into: to)
                    continue
                }
                try manager.removeItem(atPath: to.string)
            }
            try manager.moveItem(atPath: from.string, toPath: to.string)
        }
    }

    /// Unpacks an MSI with an administrative install (`msiexec /a`), through the Windows Installer API.
    static func administrativeInstall(_ msi: FilePath, to target: FilePath, log: FilePath) throws {
        _ = MsiSetInternalUI(INSTALLUILEVEL_NONE, nil)
        let logMode = DWORD(INSTALLLOGMODE_FATALEXIT.rawValue | INSTALLLOGMODE_ERROR.rawValue | INSTALLLOGMODE_WARNING.rawValue | INSTALLLOGMODE_INFO.rawValue)
        _ = log.string.withCString(encodedAs: UTF16.self) { MsiEnableLogW(logMode, $0, 0) }
        defer { _ = MsiEnableLogW(0, nil, 0) }

        let commandLine = "ACTION=ADMIN TARGETDIR=\"\(target.string)\""
        var status: UINT = 0
        // Windows Installer runs one installation at a time (error 1618 while another one runs,
        // such as Windows Update's): wait a little for it.
        for attempt in 1...6 {
            status = msi.string.withCString(encodedAs: UTF16.self) { msiW in
                commandLine.withCString(encodedAs: UTF16.self) { MsiInstallProductW(msiW, $0) }
            }
            guard status == UINT(ERROR_INSTALL_ALREADY_RUNNING), attempt < 6 else {
                break
            }
            Thread.sleep(forTimeInterval: 10)
        }
        if status == UINT(ERROR_INSTALL_ALREADY_RUNNING) {
            throw SwiftlyError(message: "Another installation is in progress (Windows Installer error 1618), such as an update. Try again when it has finished.")
        }
        guard status == UINT(ERROR_SUCCESS) else {
            let details = self.readLog(log)
                .split(whereSeparator: \.isNewline)
                .filter { $0.contains("Error") || $0.contains("error") || $0.contains("Return value 3") }
                .suffix(10)
                .joined(separator: "\n")
            var message = "Unpacking \(msi.lastComponent?.string ?? msi.string) failed with Windows Installer error \(status)."
            if status == 1603 {
                message += " If the path of swiftly's toolchains directory is long, a shorter one (SWIFTLY_TOOLCHAINS_DIR) can help."
            }
            throw SwiftlyError(message: message + "\n" + details)
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

    /// A side-by-side assembly `name` under `root` (not in `bin`): a directory `name` with `name.dll`
    /// in it, or a `name.dll` in an `SxS` directory.
    static func findAssembly(_ name: String, in root: FilePath, excluding bin: FilePath) -> FilePath? {
        guard let enumerator = FileManager.default.enumerator(atPath: root.string) else {
            return nil
        }
        let lowered = name.lowercased()
        while let relative = enumerator.nextObject() as? String {
            let path = root / relative
            if path.removingLastComponent() == bin {
                continue
            }
            let last = path.lastComponent?.string.lowercased() ?? ""
            if last == lowered, FileManager.default.fileExists(atPath: (path / "\(name).dll").string) {
                return path
            }
            if last == lowered + ".dll", path.removingLastComponent().lastComponent?.string.lowercased() == "sxs" {
                return path
            }
        }
        return nil
    }

    /// The names of the assemblies an application manifest depends on.
    static func dependentAssemblies(inManifest manifest: String) -> [String] {
        manifest.matches(of: #/<dependentAssembly>.*?<assemblyIdentity\s[^>]*?name="([^"]+)"/#.dotMatchesNewlines()).map { String($0.output.1) }
    }

    /// Copies the side-by-side assemblies the toolchain's tools need from where its packages put
    /// them, when that isn't next to the tools (snapshots' runtime has them in an SxS directory).
    /// Without them a tool fails to start with error 14001.
    private static func addMissingAssemblies(_ ctx: SwiftlyCoreContext, bin: FilePath, root: FilePath, verbose: Bool) async throws {
        var missing = try self.missingAssemblies(in: bin)
        // Elsewhere in the toolchain's own packages first: snapshots' runtime has the assemblies
        // (as <name>.dll) in Runtimes\<version>\usr\bin\SxS.
        var copied: Set<String> = []
        for name in missing {
            guard let found = self.findAssembly(name, in: root, excluding: bin) else {
                continue
            }
            if verbose {
                await ctx.message("Copying the side-by-side assembly \(name) from \(found)...")
            }
            try FileManager.default.copyItem(atPath: found.string, toPath: (bin / found.lastComponent!.string).string)
            let manifest = found.removingLastComponent() / "\(name).manifest"
            if found.extension?.lowercased() == "dll", FileManager.default.fileExists(atPath: manifest.string) {
                try? FileManager.default.copyItem(atPath: manifest.string, toPath: (bin / "\(name).manifest").string)
            }
            copied.insert(name)
        }
        missing = try self.missingAssemblies(in: bin).subtracting(copied)
        if !missing.isEmpty {
            await ctx.message("Warning: the toolchain is missing the side-by-side assemblies \(missing.sorted().joined(separator: ", ")).")
        }
    }

    /// Removes the merge modules for building installers (Redistributables), which a toolchain
    /// doesn't need. The SDK's libraries for other architectures stay, as with the installer (for
    /// cross-compiling); `linkDuplicates` recovers the space that identical files take.
    static func prune(_ root: FilePath) throws {
        let redistributables = root / "Redistributables"
        if FileManager.default.fileExists(atPath: redistributables.string) {
            try FileManager.default.removeItem(atPath: redistributables.string)
        }
    }

    /// Replaces identical copies of large files with hard links to one of them. The installer ships
    /// the same binary under many names (clang, clang++, clang-cl; lld-link, ld.lld; swift-frontend,
    /// swift-symbolgraph-extract, ...), which saves about a gigabyte per toolchain. Each link is
    /// created under a temporary name and renamed over the copy; if that fails, the copy stays.
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
                let temporary = FilePath(file.string + ".link")
                do {
                    try Win32.createHardLink(at: temporary, to: original)
                    try Win32.move(temporary, to: file, replace: true)
                } catch {
                    try? FileManager.default.removeItem(atPath: temporary.string)
                }
            }
        }
    }
}
