import _StringProcessing
import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage

/// Swift on Windows links against the Microsoft C runtime (MSVC CRT) and the Windows SDK, which
/// usually come with Visual Studio or its Build Tools. When neither is installed, swiftly can
/// download just the headers and libraries a toolchain needs, directly from Microsoft, into a
/// sysroot that every toolchain shares:
///
/// ```
/// <swiftly home>\msvc-sysroot-<arch>\
///   VC\Tools\MSVC\<version>\{include,lib\<arch>}         from the Visual Studio channel manifest
///   Windows Kits\10\{Include,Lib}\<version>\...          from NuGet, Microsoft.Windows.SDK.CPP
///   sysroot.json                                         what was downloaded, the accepted licenses
/// ```
///
/// Each toolchain is then pointed at it with `clang.cfg` next to its `clang.exe`, which both clang
/// and the Swift compiler's Clang importer read: lld instead of link.exe, and
/// `-Xmicrosoft-windows-sys-root` for the headers and libraries. With that, only `Path` and
/// `SDKROOT` need to be set to build and run Swift code.
///
/// These files are Microsoft software under Microsoft's license terms. swiftly never redistributes
/// them: they are downloaded on the user's machine, from Microsoft, and only after the user accepts
/// the license terms, either interactively or with `SWIFTLY_ACCEPT_MSVC_LICENSE=1`.
enum MSVCSysroot {
    /// How a toolchain gets the MSVC CRT and the Windows SDK.
    enum Setup: Equatable {
        /// Visual Studio (or its Build Tools) is installed with the C++ tools and a Windows SDK,
        /// which the toolchain finds on its own.
        case visualStudio(FilePath)
        /// swiftly's sysroot at this path.
        case portable(FilePath)
        /// Neither: the toolchain can compile Swift code but can't link programs.
        case unavailable
    }

    /// The `SWIFTLY_MSVC` environment variable: `auto` (the default) uses Visual Studio when it's
    /// installed and swiftly's sysroot otherwise, `portable` always uses swiftly's sysroot, and
    /// `system` never downloads anything from Microsoft.
    enum Mode: String {
        case auto
        case portable
        case system

        static var current: Mode {
            ProcessInfo.processInfo.environment["SWIFTLY_MSVC"].flatMap { Mode(rawValue: $0.lowercased()) } ?? .auto
        }
    }

    static let licenseEnvironmentVariable = "SWIFTLY_ACCEPT_MSVC_LICENSE"

    /// Whether the license terms were accepted with `SWIFTLY_ACCEPT_MSVC_LICENSE`.
    ///
    /// `--assume-yes` deliberately doesn't accept them: it answers swiftly's own questions (overwrite
    /// a file, uninstall a toolchain), while this is an agreement between the user and Microsoft,
    /// so it needs a separate, explicit opt-in that shows up in scripts and CI configurations.
    static var licenseAcceptedByEnvironment: Bool {
        ["1", "true", "yes"].contains(ProcessInfo.processInfo.environment[licenseEnvironmentVariable]?.lowercased() ?? "")
    }

    /// The architecture name Microsoft's packages use for this machine.
    static var arch: String {
#if arch(arm64)
        "arm64"
#else
        "x64"
#endif
    }

    static func directory(_ ctx: SwiftlyCoreContext) -> FilePath {
        Windows().swiftlyHomeDir(ctx) / "msvc-sysroot-\(self.arch)"
    }

    // MARK: Choosing the setup

    /// Decides how toolchains get the MSVC CRT and the Windows SDK, without asking or downloading.
    static func currentSetup(_ ctx: SwiftlyCoreContext) async -> Setup {
        let mode = Mode.current
        if mode != .portable, let vs = await self.findVisualStudio() {
            return .visualStudio(vs)
        }
        let sysroot = self.directory(ctx)
        if mode != .system, FileManager.default.fileExists(atPath: (sysroot / "sysroot.json").string) {
            return .portable(sysroot)
        }
        return .unavailable
    }

    /// Makes sure toolchains can link programs before one is installed: uses Visual Studio when it's
    /// installed, or else the sysroot, downloading it (after the user accepts the license terms)
    /// the first time.
    static func prepare(_ ctx: SwiftlyCoreContext) async throws -> Setup {
        let setup = await self.currentSetup(ctx)
        switch setup {
        case let .visualStudio(path):
            await ctx.message("Using the Microsoft C runtime and Windows SDK of Visual Studio at \(path).")
            return setup
        case .portable:
            return setup
        case .unavailable:
            break
        }
        if Mode.current == .system {
            await ctx.message("""
            Warning: Visual Studio with the C++ tools and a Windows SDK isn't installed, and SWIFTLY_MSVC=system \
            keeps swiftly from downloading them. The toolchain won't be able to link programs until you install them.
            """)
            return .unavailable
        }

        let plan = try await self.resolve(ctx)
        await ctx.message("""
        Swift needs the Microsoft C runtime (MSVC) and the Windows SDK to build programs. Visual Studio \
        isn't installed, so swiftly can download just these headers and libraries (\(plan.downloadDescription)) \
        from Microsoft into \(self.directory(ctx)). They are Microsoft software under these license terms:

          Microsoft Visual C++ runtime libraries (Visual Studio Build Tools): \(plan.msvcLicense)
          Microsoft Windows SDK \(plan.sdkVersion): \(plan.sdkLicense)

        Using the MSVC libraries requires a Visual Studio license; Visual Studio Community's terms cover \
        individuals, open source projects and small organizations. Do you accept these license terms?
        """)
        let accepted: String
        if self.licenseAcceptedByEnvironment {
            await ctx.message("Accepted with \(self.licenseEnvironmentVariable).")
            accepted = "environment"
        } else if await ctx.promptForConfirmation(defaultBehavior: false) {
            accepted = "prompt"
        } else {
            throw SwiftlyError(message: """
            The license terms weren't accepted, so nothing was downloaded from Microsoft. To accept them \
            non-interactively, set \(self.licenseEnvironmentVariable)=1. Alternatively, install Visual Studio \
            or its Build Tools with the C++ tools and a Windows SDK, or set SWIFTLY_MSVC=system to install \
            toolchains without either.
            """)
        }

        try await self.download(ctx, plan, licenseAcceptedBy: accepted)
        return .portable(self.directory(ctx))
    }

    /// Finds an installed Visual Studio with the C++ tools for this architecture, provided a
    /// Windows 10+ SDK is installed too.
    static func findVisualStudio() async -> FilePath? {
        guard let programFiles = ProcessInfo.processInfo.environment["ProgramFiles(x86)"] else {
            return nil
        }
        let vswhere = FilePath(programFiles) / "Microsoft Visual Studio" / "Installer" / "vswhere.exe"
        guard FileManager.default.fileExists(atPath: vswhere.string) else {
            return nil
        }
        let component = self.arch == "arm64" ? "Microsoft.VisualStudio.Component.VC.Tools.ARM64" : "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
        let arguments: Arguments = [
            "-latest", "-products", "*", "-requires", component, "-property", "installationPath", "-utf8", "-nologo",
        ]
        guard let result = try? await run(.path(vswhere), arguments: arguments, output: .string(limit: 64 * 1024), error: .discarded),
              result.terminationStatus.isSuccess
        else {
            return nil
        }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, self.hasWindowsSDK() else {
            return nil
        }
        return FilePath(path)
    }

    /// Whether a Windows 10+ SDK with the headers and import libraries for this architecture is installed.
    static func hasWindowsSDK() -> Bool {
        let roots = [
            "SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots",
            "SOFTWARE\\WOW6432Node\\Microsoft\\Windows Kits\\Installed Roots",
        ].compactMap { Win32.readMachineString($0, "KitsRoot10") }
        for root in roots.map({ FilePath($0) }) {
            let versions = (try? FileManager.default.contentsOfDirectory(atPath: (root / "Include").string)) ?? []
            for version in versions where version.hasPrefix("10.") {
                if FileManager.default.fileExists(atPath: (root / "Include" / version / "um" / "windows.h").string),
                   FileManager.default.fileExists(atPath: (root / "Lib" / version / "um" / self.arch / "kernel32.lib").string)
                {
                    return true
                }
            }
        }
        return false
    }

    // MARK: Resolving what to download

    /// The Visual Studio 2022 channel. Its newest toolset (14.44) still accepts the clang versions
    /// in current Swift toolchains; the STL of Visual Studio 2026 (14.50+) requires clang 20 or later.
    static let visualStudioChannel = URL(string: "https://aka.ms/vs/17/release/channel")!

    struct File: Codable, Equatable {
        var name: String
        var url: String
        /// The expected digest, as lowercase hex.
        var sha256: String?
        var sha512: String?
        var size: Int?
    }

    struct Plan: Codable, Equatable {
        var crt: [File]
        var crtVersion: String
        var sdk: [File]
        var sdkVersion: String
        var msvcLicense: String
        var sdkLicense: String

        var downloadDescription: String {
            let bytes = (self.crt + self.sdk).compactMap(\.size).reduce(0, +)
            return bytes > 0 ? "about \(bytes / 1_000_000) MB" : "a few hundred MB"
        }
    }

    /// Finds the packages to download and their license terms. This downloads only metadata.
    static func resolve(_ ctx: SwiftlyCoreContext) async throws -> Plan {
        let channel = try await JSONDecoder().decode(VSChannel.self, from: self.get(ctx, self.visualStudioChannel))
        guard let manifestItem = channel.channelItems.first(where: { $0.id == "Microsoft.VisualStudio.Manifests.VisualStudio" }),
              let manifestURL = manifestItem.payloads?.first.flatMap({ URL(string: $0.url) })
        else {
            throw SwiftlyError(message: "The Visual Studio channel \(self.visualStudioChannel) has no package manifest.")
        }
        let msvcLicense = channel.channelItems.first(where: { $0.id == "Microsoft.VisualStudio.Product.BuildTools" })?
            .localizedResources?.first(where: { $0.language?.lowercased() == "en-us" })?.license
            ?? "https://go.microsoft.com/fwlink/?LinkId=2179911"

        let manifestData = try await self.get(ctx, manifestURL)
        if let expected = manifestItem.payloads?.first?.sha256 {
            let actual = try self.digest(.sha256, of: manifestData)
            guard actual == expected.lowercased() else {
                throw SwiftlyError(message: "The Visual Studio package manifest doesn't match the hash in its channel.")
            }
        }
        let manifest = try JSONDecoder().decode(VSManifest.self, from: manifestData)
        let (crtVersion, crt) = try self.crtFiles(in: manifest, arch: self.arch)

        let index = try await JSONDecoder().decode(NuGetIndex.self, from: self.get(ctx, URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json")!))
        guard let sdkVersion = self.newestStableVersion(index.versions) else {
            throw SwiftlyError(message: "NuGet lists no release of Microsoft.Windows.SDK.CPP.")
        }
        var sdk: [File] = []
        for package in ["microsoft.windows.sdk.cpp", "microsoft.windows.sdk.cpp.\(self.arch)"] {
            sdk.append(try await self.nugetFile(ctx, package: package, version: sdkVersion))
        }
        let nuspec = try await String(decoding: self.get(ctx, URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/\(sdkVersion)/microsoft.windows.sdk.cpp.nuspec")!), as: UTF8.self)
        let sdkLicense = nuspec.firstMatch(of: #/<licenseUrl>([^<]+)</licenseUrl>/#).map { String($0.output.1) }
            ?? "https://www.nuget.org/packages/Microsoft.Windows.SDK.CPP/\(sdkVersion)/License"

        return Plan(crt: crt, crtVersion: crtVersion, sdk: sdk, sdkVersion: sdkVersion, msvcLicense: msvcLicense, sdkLicense: sdkLicense)
    }

    /// The CRT packages to download from a Visual Studio package manifest: the headers, the import
    /// libraries of the DLL runtime (Store.base) and the static runtime (Desktop.base). Prefers the
    /// toolset Visual Studio installs by default, then the newest one.
    static func crtFiles(in manifest: VSManifest, arch: String) throws -> (version: String, files: [File]) {
        var packages: [String: VSManifest.Package] = [:]
        for package in manifest.packages where packages[package.id.lowercased()] == nil {
            packages[package.id.lowercased()] = package
        }
        let headersPattern = #/^microsoft\.vc\.(.+)\.crt\.headers\.base$/#
        let defaultHeaders = packages["microsoft.visualcpp.crt.headers"]?.dependencies?.keys
            .map { $0.lowercased() }
            .first { $0.wholeMatch(of: headersPattern) != nil }
        let newestHeaders = packages.values
            .filter { $0.id.lowercased().wholeMatch(of: headersPattern) != nil }
            .max { self.compareVersions($0.version, $1.version) }?.id.lowercased()
        guard let headers = defaultHeaders.flatMap({ packages[$0] }) ?? newestHeaders.flatMap({ packages[$0] }),
              let stem = headers.id.lowercased().wholeMatch(of: headersPattern)?.output.1
        else {
            throw SwiftlyError(message: "The Visual Studio package manifest has no MSVC C runtime.")
        }
        let ids = ["microsoft.vc.\(stem).crt.headers.base", "microsoft.vc.\(stem).crt.\(arch.lowercased()).store.base", "microsoft.vc.\(stem).crt.\(arch.lowercased()).desktop.base"]
        let files = try ids.map { id -> File in
            guard let package = packages[id], let payload = package.payloads?.first else {
                throw SwiftlyError(message: "The Visual Studio package manifest has no \(id) package.")
            }
            // Payload URLs contain the SHA-256 of the file when the manifest doesn't list it separately.
            let sha256 = payload.sha256 ?? payload.url.firstMatch(of: #/\/([0-9a-fA-F]{64})\//#).map { String($0.output.1) }
            guard let sha256 else {
                throw SwiftlyError(message: "The Visual Studio package manifest has no hash for \(id).")
            }
            return File(name: package.id, url: payload.url, sha256: sha256.lowercased(), size: payload.size)
        }
        return (headers.version, files)
    }

    /// The newest version without a prerelease suffix, comparing the numbers in it.
    static func newestStableVersion(_ versions: [String]) -> String? {
        versions.filter { $0.wholeMatch(of: #/\d+(\.\d+)+/#) != nil }.max { self.compareVersions($0, $1) }
    }

    /// Whether version `a` is lower than `b`, comparing dot-separated numbers.
    static func compareVersions(_ a: String, _ b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    /// A NuGet package, with the SHA-512 the NuGet catalog lists for it.
    private static func nugetFile(_ ctx: SwiftlyCoreContext, package: String, version: String) async throws -> File {
        let leaf = try await JSONDecoder().decode(
            NuGetRegistrationLeaf.self,
            from: self.get(ctx, URL(string: "https://api.nuget.org/v3/registration5-semver1/\(package)/\(version).json")!)
        )
        guard let catalogURL = URL(string: leaf.catalogEntry) else {
            throw SwiftlyError(message: "NuGet has no catalog entry for \(package) \(version).")
        }
        let entry = try await JSONDecoder().decode(NuGetCatalogEntry.self, from: self.get(ctx, catalogURL))
        guard entry.packageHashAlgorithm.uppercased() == "SHA512", let hash = Data(base64Encoded: entry.packageHash) else {
            throw SwiftlyError(message: "NuGet has no SHA-512 for \(package) \(version).")
        }
        return File(
            name: "\(package).\(version).nupkg",
            url: "https://api.nuget.org/v3-flatcontainer/\(package)/\(version)/\(package).\(version).nupkg",
            sha512: hash.map { String(format: "%02x", $0) }.joined(),
            size: entry.packageSize
        )
    }

    // MARK: Downloading

    /// Downloads and lays out the sysroot. The finished sysroot replaces any previous one at once.
    static func download(_ ctx: SwiftlyCoreContext, _ plan: Plan, licenseAcceptedBy: String) async throws {
        let destination = self.directory(ctx)
        let work = destination.removingLastComponent() / "\(destination.lastComponent!.string).partial"
        if try await fs.exists(atPath: work) {
            try await fs.remove(atPath: work)
        }
        try await fs.mkdir(.parents, atPath: work)
        try await fs.withTemporary(files: work) {
            let root = work / "sysroot"
            let crt = work / "crt"
            try await fs.mkdir(.parents, atPath: crt)
            for file in plan.crt {
                let path = try await self.fetch(ctx, file, into: work)
                // A .vsix is a zip; tar.exe (bsdtar, part of Windows) reads it.
                try await Win32.runTool("tar.exe", ["-xf", path.string, "-C", crt.string, "Contents/VC"])
                try await fs.remove(atPath: path)
            }
            try await fs.mkdir(.parents, atPath: root)
            try await fs.move(atPath: crt / "Contents" / "VC", toPath: root / "VC")
            // The program databases of the static libraries are the biggest part and aren't needed.
            try self.removeFiles(in: root / "VC", where: { $0.lowercased().hasSuffix(".pdb") })

            let nuget = work / "nuget"
            for (index, file) in plan.sdk.enumerated() {
                let path = try await self.fetch(ctx, file, into: work)
                let dir = nuget / "\(index)"
                try await fs.mkdir(.parents, atPath: dir)
                try await Win32.runTool("tar.exe", ["-xf", path.string, "-C", dir.string] + (index == 0 ? ["c/Include"] : ["c/ucrt", "c/um"]))
                try await fs.remove(atPath: path)
            }
            guard let includeVersion = try await fs.ls(atPath: nuget / "0" / "c" / "Include").first else {
                throw SwiftlyError(message: "The Windows SDK package has no headers.")
            }
            let kits = root / "Windows Kits" / "10"
            try await fs.mkdir(.parents, atPath: kits / "Include")
            try await fs.mkdir(.parents, atPath: kits / "Lib" / includeVersion)
            try await fs.move(atPath: nuget / "0" / "c" / "Include" / includeVersion, toPath: kits / "Include" / includeVersion)
            try await fs.move(atPath: nuget / "1" / "c" / "ucrt", toPath: kits / "Lib" / includeVersion / "ucrt")
            try await fs.move(atPath: nuget / "1" / "c" / "um", toPath: kits / "Lib" / includeVersion / "um")

            let info = SysrootInfo(
                arch: self.arch,
                msvcPackageVersion: plan.crtVersion,
                windowsSDKVersion: plan.sdkVersion,
                licenses: ["msvc": plan.msvcLicense, "windowsSDK": plan.sdkLicense],
                licenseAcceptedBy: licenseAcceptedBy,
                downloaded: ISO8601DateFormatter().string(from: Date())
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(info).write(to: root / "sysroot.json")

            if try await fs.exists(atPath: destination) {
                try await fs.remove(atPath: destination)
            }
            try await fs.move(atPath: root, toPath: destination)
        }
        await ctx.message("The Microsoft C runtime \(plan.crtVersion) and Windows SDK \(plan.sdkVersion) are in \(destination).")
    }

    /// What `sysroot.json` records about a downloaded sysroot.
    struct SysrootInfo: Codable, Equatable {
        var arch: String
        var msvcPackageVersion: String
        var windowsSDKVersion: String
        var licenses: [String: String]
        var licenseAcceptedBy: String
        var downloaded: String
    }

    private static func fetch(_ ctx: SwiftlyCoreContext, _ file: File, into dir: FilePath) async throws -> FilePath {
        await ctx.message("Downloading \(file.name)...")
        let path = dir / file.name
        try await fs.create(file: path, contents: nil)
        guard let url = URL(string: file.url) else {
            throw SwiftlyError(message: "Invalid download URL \(file.url)")
        }
        try await ctx.httpClient.getFile(url: url).download(to: path)
        if let sha256 = file.sha256, try Win32.hash(.sha256, file: path) != sha256 {
            throw SwiftlyError(message: "\(file.name) from \(file.url) doesn't match its SHA-256.")
        }
        if let sha512 = file.sha512, try Win32.hash(.sha512, file: path) != sha512 {
            throw SwiftlyError(message: "\(file.name) from \(file.url) doesn't match its SHA-512.")
        }
        return path
    }

    private static func get(_ ctx: SwiftlyCoreContext, _ url: URL) async throws -> Data {
        let file = fs.mktemp(ext: ".json")
        try await fs.create(file: file, contents: nil)
        return try await fs.withTemporary(files: file) {
            try await ctx.httpClient.getFile(url: url).download(to: file)
            return try Data(contentsOf: file)
        }
    }

    private static func digest(_ algorithm: Win32.Hash.Algorithm, of data: Data) throws -> String {
        let hash = try Win32.Hash(algorithm)
        try hash.update(data)
        return try hash.finish()
    }

    private static func removeFiles(in dir: FilePath, where predicate: (String) -> Bool) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: dir.string) else {
            return
        }
        var matches: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if predicate(relative) {
                matches.append(relative)
            }
        }
        for relative in matches {
            try FileManager.default.removeItem(atPath: (dir / relative).string)
        }
    }

    // MARK: Configuring a toolchain

    /// Points a toolchain at the sysroot (or, for the other setups, makes sure it isn't).
    static func configure(_ toolchain: WindowsToolchainLayout, for setup: Setup) throws {
        let configs = ["clang.cfg", "clang++.cfg"].map { toolchain.bin / $0 }
        let overlay = toolchain.root / "msvc-modulemaps.yaml"
        guard case let .portable(sysroot) = setup else {
            for file in configs + [overlay] where FileManager.default.fileExists(atPath: file.string) {
                try FileManager.default.removeItem(atPath: file.string)
            }
            return
        }

        guard let vc = self.newestSubdirectory(sysroot / "VC" / "Tools" / "MSVC"),
              let sdkVersion = self.newestSubdirectory(sysroot / "Windows Kits" / "10" / "Include")?.lastComponent?.string
        else {
            throw SwiftlyError(message: "The sysroot in \(sysroot) is incomplete. Remove it and install the toolchain again.")
        }
        let include = sysroot / "Windows Kits" / "10" / "Include" / sdkVersion

        // The Swift compiler maps its modulemaps for the C runtime and the Windows SDK into the
        // SDK's header directories only for SDKs it finds itself (in the registry, or with
        // -windows-sdk-root). Map them in with a VFS overlay, which leaves the shared sysroot as
        // Microsoft ships it and lets every toolchain use its own modulemaps.
        let shared = toolchain.sdk / "usr" / "share"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: shared.string)) ?? []).sorted()
        let placements = self.modulemapPlacements(files, include: include, vcInclude: vc / "include")
            .map { (virtualPath: $0.destination, realPath: shared / $0.file) }
        try Data(self.overlayYAML(placements).utf8).write(to: overlay)

        let delayLoad = self.importLibrariesWithoutDLLs(toolchain)
        let hasDelayImp = FileManager.default.fileExists(atPath: (vc / "lib" / self.arch / "delayimp.lib").string)
        let config = self.clangConfig(sysroot: sysroot, overlay: overlay, delayLoad: hasDelayImp ? delayLoad : [])
        for file in configs {
            try Data(config.utf8).write(to: file)
        }
    }

    /// Where each of the toolchain's modulemaps and API notes (the files in `<SDK>\usr\share`) goes in
    /// the sysroot. Later files win when two map to the same place.
    static func modulemapPlacements(_ files: [String], include: FilePath, vcInclude: FilePath) -> [(file: String, destination: FilePath)] {
        var byDestination: [FilePath: String] = [:]
        var order: [FilePath] = []
        for file in files {
            let name = file.lowercased()
            let destination: FilePath? = switch name {
            case "ucrt.modulemap": include / "ucrt" / "module.modulemap"
            case "ucrt.apinotes": include / "ucrt" / "ucrt.apinotes"
            case "vcruntime.modulemap": vcInclude / "module.modulemap"
            case "vcruntime.apinotes": vcInclude / "vcruntime.apinotes"
            case "winsdk.modulemap": include / "um" / "module.modulemap"
            case "winsdk.apinotes": include / "um" / "WinSDK.apinotes"
            default:
                if let match = name.wholeMatch(of: #/winsdk_(\w+)\.modulemap/#) {
                    include / String(match.output.1) / "module.modulemap"
                } else {
                    nil
                }
            }
            guard let destination else { continue }
            if byDestination[destination] == nil { order.append(destination) }
            byDestination[destination] = file
        }
        return order.map { (byDestination[$0]!, $0) }
    }

    /// A clang VFS overlay (JSON is YAML) that makes each real file appear at its virtual path.
    static func overlayYAML(_ placements: [(virtualPath: FilePath, realPath: FilePath)]) throws -> String {
        struct Entry: Encodable {
            var name: String
            var type: String
            var contents: [Entry]?
            var externalContents: String?

            enum CodingKeys: String, CodingKey {
                case name, type, contents
                case externalContents = "external-contents"
            }
        }
        struct Overlay: Encodable {
            var version = 0
            var caseSensitive = "false"
            var roots: [Entry]

            enum CodingKeys: String, CodingKey {
                case version, roots
                case caseSensitive = "case-sensitive"
            }
        }
        var directories: [String] = []
        var contents: [String: [Entry]] = [:]
        for placement in placements {
            let dir = placement.virtualPath.removingLastComponent().string
            if contents[dir] == nil { directories.append(dir) }
            contents[dir, default: []].append(
                Entry(name: placement.virtualPath.lastComponent!.string, type: "file", externalContents: placement.realPath.string)
            )
        }
        let overlay = Overlay(roots: directories.map { Entry(name: $0, type: "directory", contents: contents[$0]) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(overlay), as: UTF8.self)
    }

    /// The `clang.cfg` that points clang at the sysroot.
    static func clangConfig(sysroot: FilePath, overlay: FilePath, delayLoad: [String]) -> String {
        var lines = [
            "# Written by swiftly: link with lld against the Microsoft C runtime and Windows SDK in \(sysroot.string).",
            "-fuse-ld=lld",
            "-Xmicrosoft-windows-sys-root \(self.quoteConfigArgument(sysroot.string))",
            "-ivfsoverlay \(self.quoteConfigArgument(overlay.string))",
        ]
        if !delayLoad.isEmpty {
            // Some toolchains (Swift 6.2) ship import libraries for DLLs they don't ship. link.exe drops
            // unused imports, lld-link doesn't, so programs would fail to start. Delay-loading them
            // means the DLLs are only needed if they are actually called.
            lines.append("--start-no-unused-arguments")
            lines += delayLoad.map { "-Wl,/delayload:\($0)" }
            lines += ["-Wl,delayimp.lib", "--end-no-unused-arguments"]
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Quotes an argument for a clang configuration file, in which a backslash escapes the next
    /// character. (Writing the path with forward slashes instead breaks the Swift compiler's
    /// VFS overlay of the SDK, which requires native paths.)
    static func quoteConfigArgument(_ argument: String) -> String {
        "\"" + argument.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// The DLLs the SDK's Swift import libraries refer to that neither the toolchain nor its runtime has.
    static func importLibrariesWithoutDLLs(_ toolchain: WindowsToolchainLayout) -> [String] {
#if arch(arm64)
        let triple = "aarch64"
#else
        let triple = "x86_64"
#endif
        let libDir = toolchain.sdk / "usr" / "lib" / "swift" / "windows" / triple
        var missing: [String] = []
        for file in ((try? FileManager.default.contentsOfDirectory(atPath: libDir.string)) ?? []).sorted() where file.lowercased().hasSuffix(".lib") {
            let path = libDir / file
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path.string))?[.size] as? NSNumber, size.intValue < 1024 * 1024,
                  let data = FileManager.default.contents(atPath: path.string)
            else {
                continue
            }
            let dll = String(file.dropLast(4)) + ".dll"
            // An import library names its DLL; a static library doesn't.
            guard String(decoding: data, as: UTF8.self).range(of: dll, options: .caseInsensitive) != nil else {
                continue
            }
            if !FileManager.default.fileExists(atPath: (toolchain.runtimeBin / dll).string),
               !FileManager.default.fileExists(atPath: (toolchain.bin / dll).string)
            {
                missing.append(dll)
            }
        }
        return missing
    }

    private static func newestSubdirectory(_ dir: FilePath) -> FilePath? {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.string)) ?? [])
            .max { self.compareVersions($0, $1) }
            .map { dir / $0 }
    }
}

// MARK: Microsoft's metadata formats

/// A Visual Studio release channel (https://aka.ms/vs/17/release/channel).
struct VSChannel: Decodable {
    struct Item: Decodable {
        var id: String
        var payloads: [Payload]?
        var localizedResources: [Resource]?
    }

    struct Payload: Decodable {
        var url: String
        var sha256: String?
    }

    struct Resource: Decodable {
        var language: String?
        var license: String?
    }

    var channelItems: [Item]
}

/// The Visual Studio package manifest the channel refers to. Only what swiftly uses is decoded.
struct VSManifest: Decodable {
    struct Package: Decodable {
        var id: String
        var version: String
        var payloads: [Payload]?
        var dependencies: [String: Ignored]?
    }

    struct Payload: Decodable {
        var url: String
        var sha256: String?
        var size: Int?
    }

    /// Any JSON value; dependencies are versions or objects, and only their names matter.
    struct Ignored: Decodable {
        init(from _: Decoder) throws {}
    }

    var packages: [Package]
}

struct NuGetIndex: Decodable {
    var versions: [String]
}

struct NuGetRegistrationLeaf: Decodable {
    var catalogEntry: String
}

struct NuGetCatalogEntry: Decodable {
    var packageHash: String
    var packageHashAlgorithm: String
    var packageSize: Int?
}
