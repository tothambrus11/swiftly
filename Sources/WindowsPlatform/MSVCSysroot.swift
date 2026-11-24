import _StringProcessing
import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage

/// An explicit opt-in (`swiftly install --msvc=portable`) for machines without Visual Studio: swiftly
/// downloads just the headers and libraries of the Microsoft C runtime (MSVC CRT) and the Windows SDK
/// that Swift needs, from Microsoft, into a sysroot that every toolchain shares:
///
/// ```
/// <swiftly home>\msvc-sysroot-<arch>\
///   VC\Tools\MSVC\<version>\{include,lib\<arch>}         from the Visual Studio 2022 channel manifest
///   Windows Kits\10\{Include,Lib}\<version>\...          from NuGet, Microsoft.Windows.SDK.CPP
///   sysroot.json                                         what was downloaded, the accepted terms
/// ```
///
/// Each toolchain then gets clang and clang-cl configuration files next to its `clang.exe`, for this
/// machine's triples only (see `configFiles`): lld instead of link.exe, and
/// `-Xmicrosoft-windows-sys-root` (`/winsysroot`) for the headers and libraries.
///
/// Or, with `--msvc=install-build-tools`, swiftly runs Microsoft's own Build Tools installer, which
/// presents Microsoft's terms; that's the preferred way.
///
/// The files are Microsoft software under Microsoft's license terms. swiftly itself doesn't
/// redistribute, mirror or cache them: they're downloaded on the user's machine, from Microsoft,
/// after the user accepts the terms, and kept only in the user's sysroot directory.
///
/// Trust: the packages are checked against the SHA-256 (CRT) and SHA-512 (SDK) that Microsoft's
/// metadata lists, and that metadata comes over HTTPS from Microsoft. The signatures embedded in
/// the Visual Studio manifest and in the packages aren't verified, so the trust boundary is TLS.
enum MSVCSysroot {
    /// Where toolchains get the MSVC CRT and the Windows SDK from.
    enum Mode: String, CaseIterable {
        /// Visual Studio or its Build Tools, as with the swift.org installer (the default).
        case visualStudio = "visual-studio"
        /// swiftly's sysroot, downloaded after the user accepts Microsoft's license terms.
        case portable
        /// Microsoft's Visual Studio Build Tools installer, run by swiftly, which presents the terms.
        case installBuildTools = "install-build-tools"
    }

    static let licenseEnvironmentVariable = "SWIFTLY_ACCEPT_MSVC_LICENSE"

    /// The mode the user asked for with `--msvc` (or SWIFTLY_MSVC). An unknown value is an error.
    static func requestedMode(_ ctx: SwiftlyCoreContext) throws -> Mode? {
        guard let value = ctx.platformOptions["msvc"] ?? ProcessInfo.processInfo.environment["SWIFTLY_MSVC"], !value.isEmpty else {
            return nil
        }
        guard let mode = Mode(rawValue: value.lowercased()) else {
            throw SwiftlyError(message: "Unknown --msvc value \"\(value)\"; use \(Mode.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return mode
    }

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

    /// The sysroot's record, if it's complete.
    static func info(_ ctx: SwiftlyCoreContext) -> SysrootInfo? {
        guard let data = try? Data(contentsOf: self.directory(ctx) / "sysroot.json") else {
            return nil
        }
        return try? JSONDecoder().decode(SysrootInfo.self, from: data)
    }

    /// Whether the toolchains use the sysroot: when it was asked for, or when it was set up before and
    /// Visual Studio still isn't ready.
    static func isSelected(_ ctx: SwiftlyCoreContext, visualStudio: VisualStudio.Status) throws -> Bool {
        switch try self.requestedMode(ctx) {
        case .portable: true
        case .visualStudio, .installBuildTools: false
        case nil: self.info(ctx) != nil && !visualStudio.isReady
        }
    }

    // MARK: The license gate

    /// The license terms the packages point to, as Microsoft links them.
    static let buildToolsLicense = "https://go.microsoft.com/fwlink/?LinkId=2179911"
    static let windowsSDKLicense = "https://aka.ms/WinSDKLicenseURL"
    /// Microsoft's own description of who may use the Build Tools (the Visual Studio licensing page).
    static let eligibility = "https://visualstudio.microsoft.com/license-terms/"

    /// The terms as fetched: the URLs the packages point to and an identifier of their text, which
    /// changes when either document's text does. Fetching the license documents doesn't need
    /// consent; the packages are downloaded only after the user accepts.
    struct Terms: Codable, Equatable {
        var msvc: String
        var windowsSDK: String
        var identifier: String
    }

    static func terms(_ ctx: SwiftlyCoreContext, msvc: String, windowsSDK: String) async throws -> Terms {
        var text = ""
        for url in [msvc, windowsSDK] {
            guard let link = URL(string: url) else {
                throw SwiftlyError(message: "Invalid license URL \(url)")
            }
            text += self.normalizedText(String(decoding: try await self.get(ctx, link), as: UTF8.self)) + "\n"
        }
        return Terms(msvc: msvc, windowsSDK: windowsSDK, identifier: try self.identifier(of: text))
    }

    /// The first 12 hex digits of the SHA-256 of `text`.
    static func identifier(of text: String) throws -> String {
        let hash = try Win32.Hash(.sha256)
        try hash.update(Data(text.utf8))
        return String(try hash.finish().prefix(12))
    }

    /// A license page's words, without markup, scripts or whitespace differences, so that only a
    /// change of its text counts as a change of the terms.
    static func normalizedText(_ html: String) -> String {
        var text = html.replacing(#/(?s)<script\b.*?</script>/#, with: " ")
        text = text.replacing(#/(?s)<style\b.*?</style>/#, with: " ")
        text = text.replacing(#/<[^>]*>/#, with: " ")
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func licenseText(_ terms: Terms) -> String {
        """
        swiftly can download the headers and libraries of the Microsoft C runtime (MSVC) and the \
        Windows SDK that Swift needs to build programs, directly from Microsoft, for this user on this \
        machine. They are Microsoft software under these license terms (\(terms.identifier)):

          Visual Studio Build Tools (the MSVC libraries): \(terms.msvc)
          Windows SDK: \(terms.windowsSDK)

        Whether the Build Tools' terms cover your use is between you and Microsoft; see Microsoft's \
        description at \(self.eligibility). Accepting here is like accepting them in Microsoft's \
        installer. swiftly doesn't support sharing the downloaded files: each user and machine accepts \
        and downloads them, so they aren't for CI caches or a shared SWIFTLY_HOME_DIR. (How the terms \
        treat build devices, section 2.2, is for Microsoft's terms to say.)
        """
    }

    /// Asks the user to accept `terms`. `--accept-msvc-license` or SWIFTLY_ACCEPT_MSVC_LICENSE=1
    /// accept non-interactively, but only terms that are new on this machine or the same as accepted
    /// before; changed terms need SWIFTLY_ACCEPT_MSVC_LICENSE=<identifier> or an answer at the prompt.
    /// `--assume-yes` deliberately doesn't accept: it answers swiftly's own questions, while this is
    /// an agreement between the user and Microsoft. Returns how they were accepted, or nil.
    static func askToAccept(_ ctx: SwiftlyCoreContext, _ terms: Terms, previous: Terms?) async throws -> String? {
        await ctx.message(self.licenseText(terms))
        let variable = ProcessInfo.processInfo.environment[self.licenseEnvironmentVariable]?.lowercased() ?? ""
        if variable == terms.identifier {
            await ctx.message("Accepted with \(self.licenseEnvironmentVariable)=\(terms.identifier).")
            return "\(self.licenseEnvironmentVariable)=\(terms.identifier)"
        }
        let flag = ctx.platformOptions["accept-msvc-license"] == "true" ? "--accept-msvc-license" : nil
        let general = ["1", "true", "yes"].contains(variable) ? self.licenseEnvironmentVariable : nil
        if let nonInteractive = flag ?? general {
            if let previous, previous.identifier != terms.identifier {
                throw SwiftlyError(message: """
                The license terms changed since they were accepted on this machine (\(previous.identifier), now \
                \(terms.identifier)). \(nonInteractive) doesn't accept changed terms: read them and accept them at \
                the prompt, or set \(self.licenseEnvironmentVariable)=\(terms.identifier).
                """)
            }
            await ctx.message("Accepted with \(nonInteractive).")
            return nonInteractive
        }
        guard ctx.format != .json else {
            return nil
        }
        while true {
            guard let answer = await ctx.readLine(prompt: "Accept the Microsoft license terms? (y/N)")?.trimmingCharacters(in: .whitespaces).lowercased() else {
                return nil
            }
            switch answer {
            case "y", "yes": return "prompt"
            case "", "n", "no": return nil
            default: await ctx.message("Please answer \"y\" or \"n\".")
            }
        }
    }

    /// Sets the toolchains up for the selected source of the MSVC CRT and Windows SDK, before a
    /// toolchain is installed: downloads the sysroot if it's selected and missing (or `--msvc-refresh`
    /// asks for a new one), after the user accepts Microsoft's license terms, or runs Microsoft's
    /// Build Tools installer for `install-build-tools`. Every installed toolchain is configured for
    /// the result. Returns the instructions to show when Visual Studio is still needed; the
    /// toolchain installs either way.
    static func prepare(_ ctx: SwiftlyCoreContext, visualStudio: VisualStudio.Status) async throws -> String? {
        let requested = try self.requestedMode(ctx)
        if ctx.platformOptions["msvc-remove"] == "true" {
            try await self.remove(ctx)
            return VisualStudio.instructions(for: visualStudio)
        }
        if requested == .installBuildTools {
            return try await self.installBuildTools(ctx, visualStudio: visualStudio)
        }
        guard try self.isSelected(ctx, visualStudio: visualStudio) else {
            // Toolchains configured for the sysroot before go back to Visual Studio.
            try await self.configureAll(ctx, sysroot: nil)
            return VisualStudio.instructions(for: visualStudio)
        }
        let existing = self.info(ctx)
        if existing != nil, ctx.platformOptions["msvc-refresh"] != "true" {
            try await self.configureAll(ctx, sysroot: self.directory(ctx))
            return nil
        }
        if Win32.isNetworkPath(self.directory(ctx)) {
            await ctx.message("Warning: the sysroot would be on a network location (\(self.directory(ctx))). swiftly doesn't support sharing it between users or machines.")
        }

        // Metadata and the license documents first (they need no consent), then one question with
        // the terms the packages point to.
        let plan: Plan
        let terms: Terms
        do {
            plan = try await self.resolve(ctx)
            terms = try await self.terms(ctx, msvc: plan.msvcLicense, windowsSDK: plan.sdkLicense)
        } catch {
            await ctx.message("Warning: couldn't look up the Microsoft packages (\(error)); nothing was downloaded.")
            return VisualStudio.instructions(for: visualStudio)
        }
        await ctx.message("The packages: the Microsoft C runtime \(plan.crtVersion) (Visual Studio \(plan.channelVersion)) and the Windows SDK \(plan.sdkVersion).")
        guard let acceptedBy = try await self.askToAccept(ctx, terms, previous: existing?.terms) else {
            await ctx.message("The license terms weren't accepted; no packages were downloaded from Microsoft.")
            return VisualStudio.instructions(for: visualStudio)
        }
        try await self.download(ctx, plan, terms: terms, licenseAcceptedBy: acceptedBy)
        await self.checkRedistributable(ctx, toolset: plan.crtVersion)
        try await self.configureAll(ctx, sysroot: self.directory(ctx))
        return nil
    }

    /// Microsoft's own installer, which presents Microsoft's terms itself: swiftly runs winget,
    /// interactively, for the Visual Studio 2022 Build Tools with the components Swift needs.
    static func installBuildTools(_ ctx: SwiftlyCoreContext, visualStudio: VisualStudio.Status) async throws -> String? {
        if visualStudio.isReady {
            return nil
        }
        let command = self.buildToolsCommand
        await ctx.message("""
        swiftly can run Microsoft's installer for the Visual Studio Build Tools, which shows Microsoft's \
        license terms and asks you to accept them:
            \(command.joined(separator: " "))
        Run it now?
        """)
        guard await ctx.promptForConfirmation(defaultBehavior: false) else {
            return VisualStudio.instructions(for: visualStudio)
        }
        do {
            try await Win32.runProgram(command[0], Array(command.dropFirst()))
        } catch {
            await ctx.message("Warning: the Build Tools installer didn't finish (\(error)).")
        }
        return VisualStudio.instructions(for: await VisualStudio.detect())
    }

    /// The winget command for the Visual Studio 2022 Build Tools in Microsoft's interactive installer.
    static var buildToolsCommand: [String] {
        let adds = VisualStudio.components.map { "--add \($0)" }.joined(separator: " ")
        return ["winget", "install", "--id", "Microsoft.VisualStudio.2022.BuildTools", "--exact", "--interactive", "--source", "winget", "--custom", "\(adds) --wait"]
    }

    /// Removes swiftly's configuration from every toolchain and deletes the sysroot.
    static func remove(_ ctx: SwiftlyCoreContext) async throws {
        try await self.configureAll(ctx, sysroot: nil)
        let directory = self.directory(ctx)
        if FileManager.default.fileExists(atPath: directory.string) {
            try FileManager.default.removeItem(atPath: directory.string)
            await ctx.message("Removed the sysroot in \(directory), and swiftly's configuration of the toolchains for it.")
        }
    }

    /// Configures every toolchain swiftly installed for `sysroot`, or for Visual Studio without one.
    static func configureAll(_ ctx: SwiftlyCoreContext, sysroot: FilePath?) async throws {
        let toolchains = Windows().swiftlyToolchainsDir(ctx)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: toolchains.string)) ?? [] where !name.hasPrefix("_") {
            if let layout = WindowsToolchainLayout.read(toolchains / name) {
                try await self.configure(ctx, layout, sysroot: sysroot)
            }
        }
    }

    /// Warns when the Visual C++ runtime that programs built with the toolset `toolset` need is
    /// missing or older than the toolset, for both of its DLLs.
    static func checkRedistributable(_ ctx: SwiftlyCoreContext, toolset: String) async {
        let wanted = Array(VisualStudio.versionComponents(toolset).prefix(2))
        for dll in ["vcruntime140.dll", "msvcp140.dll"] {
            let version = Win32.fileVersion(Win32.system32 / dll)
            guard let version, !Array(version.prefix(2)).lexicographicallyPrecedes(wanted) else {
                let have = version.map { "version " + $0.map(String.init).joined(separator: ".") } ?? "missing"
                await ctx.message("""
                Warning: the Visual C++ runtime (\(dll)) is \(have), and programs built with the toolset \
                \(toolset) need \(wanted.map(String.init).joined(separator: ".")) or later to run. Install it \
                from Microsoft: https://aka.ms/vs/17/release/vc_redist.\(self.arch).exe
                """)
                return
            }
        }
    }

    // MARK: Resolving what to download

    /// The Visual Studio 2022 channel. Its newest toolset (14.44) accepts the clang of current Swift
    /// toolchains; the STL of Visual Studio 2026 (14.52) rejects clang < 22 (error STL1000).
    /// The Windows SDK release swiftly takes from NuGet, the one it's tested with (its newest servicing update).
    static let testedWindowsSDK = "10.0.26100."

    static let visualStudioChannel = URL(string: "https://aka.ms/vs/17/release/channel")!

    struct File: Codable, Equatable {
        var name: String
        var url: String
        /// The expected digest, as lowercase hex.
        var sha256: String?
        var sha512: String?
    }

    struct Plan: Codable, Equatable {
        var crt: [File]
        var crtVersion: String
        var channelVersion: String
        var sdk: [File]
        var sdkVersion: String
        var msvcLicense: String
        var sdkLicense: String
    }

    /// Finds the packages to download and the terms they point to. This downloads only metadata.
    static func resolve(_ ctx: SwiftlyCoreContext) async throws -> Plan {
        let channel = try await JSONDecoder().decode(VSChannel.self, from: self.get(ctx, self.visualStudioChannel))
        guard let manifestItem = channel.channelItems.first(where: { $0.id == "Microsoft.VisualStudio.Manifests.VisualStudio" }),
              let manifestURL = manifestItem.payloads?.first.flatMap({ URL(string: $0.url) })
        else {
            throw SwiftlyError(message: "The Visual Studio channel \(self.visualStudioChannel) has no package manifest.")
        }
        let msvcLicense = channel.channelItems.first(where: { $0.id == "Microsoft.VisualStudio.Product.BuildTools" })?
            .localizedResources?.first(where: { $0.language?.lowercased() == "en-us" })?.license
            ?? self.buildToolsLicense

        // The channel's size and SHA-256 for the manifest don't describe the file that's served, so
        // they can't be checked; the manifest comes over HTTPS from Microsoft's download server.
        let manifest = try await JSONDecoder().decode(VSManifest.self, from: self.get(ctx, manifestURL))
        let (crtVersion, crt) = try self.crtFiles(in: manifest, arch: self.arch)

        let index = try await JSONDecoder().decode(NuGetIndex.self, from: self.get(ctx, URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/index.json")!))
        guard let sdkVersion = self.newestStableVersion(index.versions.filter { $0.hasPrefix(self.testedWindowsSDK) }) else {
            throw SwiftlyError(message: "NuGet lists no release \(self.testedWindowsSDK)* of Microsoft.Windows.SDK.CPP, the Windows SDK swiftly is tested with.")
        }
        var sdk: [File] = []
        for package in ["microsoft.windows.sdk.cpp", "microsoft.windows.sdk.cpp.\(self.arch)"] {
            sdk.append(try await self.nugetFile(ctx, package: package, version: sdkVersion))
        }
        let nuspec = try await String(decoding: self.get(ctx, URL(string: "https://api.nuget.org/v3-flatcontainer/microsoft.windows.sdk.cpp/\(sdkVersion)/microsoft.windows.sdk.cpp.nuspec")!), as: UTF8.self)
        let sdkLicense = nuspec.firstMatch(of: #/<licenseUrl>([^<]+)</licenseUrl>/#).map { String($0.output.1) } ?? self.windowsSDKLicense

        return Plan(
            crt: crt, crtVersion: crtVersion, channelVersion: channel.info?.productDisplayVersion ?? "unknown",
            sdk: sdk, sdkVersion: sdkVersion, msvcLicense: msvcLicense, sdkLicense: sdkLicense
        )
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
            return File(name: package.id, url: payload.url, sha256: sha256.lowercased())
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
            sha512: hash.map { String(format: "%02x", $0) }.joined()
        )
    }

    // MARK: Downloading

    /// What `sysroot.json` records about a downloaded sysroot and the accepted terms.
    struct SysrootInfo: Codable, Equatable {
        var arch: String
        var msvcPackageVersion: String
        var channelVersion: String
        var windowsSDKVersion: String
        var licenses: [String: String]
        /// The terms accepted, as shown, and how and when, by which swiftly.
        var terms: Terms?
        var licenseAcceptedBy: String
        var accepted: String
        var swiftlyVersion: String?
    }

    /// Downloads and lays out the sysroot. The finished sysroot replaces any previous one at once.
    static func download(_ ctx: SwiftlyCoreContext, _ plan: Plan, terms: Terms, licenseAcceptedBy: String) async throws {
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
            for (index, file) in plan.crt.enumerated() {
                // A .vsix is a zip; tar.exe (bsdtar, part of Windows) reads it. It runs in the target
                // directory with short ASCII names, as it mangles non-ASCII arguments.
                try await self.fetch(ctx, file, to: crt / "\(index).zip")
                try await Win32.runTool("tar.exe", ["-xf", "\(index).zip", "Contents/VC"], in: crt)
                try await fs.remove(atPath: crt / "\(index).zip")
            }
            try await fs.mkdir(.parents, atPath: root)
            try await fs.move(atPath: crt / "Contents" / "VC", toPath: root / "VC")
            // The program databases of the static libraries and the CRT variants for UWP/OneCore
            // aren't needed.
            try self.prune(root / "VC")

            let nuget = work / "nuget"
            for (index, file) in plan.sdk.enumerated() {
                let dir = nuget / "\(index)"
                try await fs.mkdir(.parents, atPath: dir)
                try await self.fetch(ctx, file, to: dir / "p.zip")
                try await Win32.runTool("tar.exe", ["-xf", "p.zip"] + (index == 0 ? ["c/Include"] : ["c/ucrt", "c/um"]), in: dir)
                try await fs.remove(atPath: dir / "p.zip")
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
                channelVersion: plan.channelVersion,
                windowsSDKVersion: plan.sdkVersion,
                licenses: ["msvc": plan.msvcLicense, "windowsSDK": plan.sdkLicense],
                terms: terms,
                licenseAcceptedBy: licenseAcceptedBy,
                accepted: ISO8601DateFormatter().string(from: Date()),
                swiftlyVersion: String(describing: SwiftlyCore.version)
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

    private static func fetch(_ ctx: SwiftlyCoreContext, _ file: File, to path: FilePath) async throws {
        await ctx.message("Downloading \(file.name)...")
        try await fs.create(file: path, contents: nil)
        guard let url = URL(string: file.url) else {
            throw SwiftlyError(message: "Invalid download URL \(file.url)")
        }
        try await ctx.httpClient.getFile(url: url).download(to: path)
        // The hashes are the check: Visual Studio manifests' payload sizes don't always match the
        // files served.
        if let sha256 = file.sha256, try Win32.hash(.sha256, file: path) != sha256 {
            throw SwiftlyError(message: "\(file.name) from \(file.url) doesn't match its SHA-256.")
        }
        if let sha512 = file.sha512, try Win32.hash(.sha512, file: path) != sha512 {
            throw SwiftlyError(message: "\(file.name) from \(file.url) doesn't match its SHA-512.")
        }
    }

    private static func get(_ ctx: SwiftlyCoreContext, _ url: URL) async throws -> Data {
        let file = fs.mktemp(ext: ".json")
        try await fs.create(file: file, contents: nil)
        return try await fs.withTemporary(files: file) {
            try await ctx.httpClient.getFile(url: url).download(to: file)
            return try Data(contentsOf: file)
        }
    }

    /// Removes the program databases and the CRT variants for UWP, OneCore and enclaves.
    private static func prune(_ dir: FilePath) throws {
        guard let enumerator = FileManager.default.enumerator(atPath: dir.string) else {
            return
        }
        var remove: [String] = []
        while let relative = enumerator.nextObject() as? String {
            let name = (FilePath(relative).lastComponent?.string ?? relative).lowercased()
            if ["store", "uwp", "onecore", "enclave"].contains(name) {
                remove.append(relative)
                enumerator.skipDescendants()
            } else if name.hasSuffix(".pdb") {
                remove.append(relative)
            }
        }
        for relative in remove {
            try FileManager.default.removeItem(atPath: (dir / relative).string)
        }
    }

    // MARK: Configuring a toolchain

    /// The first line of the files swiftly writes into a toolchain; only files with it are replaced
    /// or removed.
    static let marker = "# Written by swiftly:"

    /// The triples clang is configured for: the one Swift uses (`unknown`) and the one clang-cl and
    /// CMake use (`pc`), each for clang and clang-cl. Cross-compiling to other triples isn't
    /// affected.
    static var configFiles: [(name: String, clangCL: Bool)] {
        let cpu = self.arch == "arm64" ? "aarch64" : "x86_64"
        return ["unknown", "pc"].flatMap { vendor in
            [("\(cpu)-\(vendor)-windows-msvc.cfg", false), ("\(cpu)-\(vendor)-windows-msvc-clang-cl.cfg", true)]
        }
    }

    /// Records the files swiftly wrote into a toolchain, so they can be recognized and removed later
    /// (the overlay is JSON and can't carry the marker line).
    static let stampName = "swiftly-msvc-sysroot.json"

    /// Points a toolchain at the sysroot, or (without one) removes what swiftly wrote for it before.
    static func configure(_ ctx: SwiftlyCoreContext, _ toolchain: WindowsToolchainLayout, sysroot: FilePath?) async throws {
        let stamp = toolchain.root / self.stampName
        let overlay = toolchain.root / "msvc-modulemaps.yaml"
        let configs = self.configFiles.map { (path: toolchain.bin / $0.name, clangCL: $0.clangCL) }
        var written = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: stamp))) ?? []
        // Files with the marker are swiftly's too (swiftly wrote them before it kept a stamp).
        written += (configs.map(\.path) + [toolchain.bin / "clang.cfg", toolchain.bin / "clang++.cfg"]).filter(self.isOurs).map(\.string)
        for file in Set(written) {
            try? FileManager.default.removeItem(atPath: file)
        }
        try? FileManager.default.removeItem(atPath: stamp.string)
        guard let sysroot else {
            return
        }
        if let foreign = configs.first(where: { FileManager.default.fileExists(atPath: $0.path.string) }) {
            await ctx.message("Warning: \(foreign.path) exists and wasn't written by swiftly; leaving the toolchain's configuration alone.")
            return
        }

        guard let vc = self.newestSubdirectory(sysroot / "VC" / "Tools" / "MSVC"),
              let sdkVersion = self.newestSubdirectory(sysroot / "Windows Kits" / "10" / "Include")?.lastComponent?.string
        else {
            throw SwiftlyError(message: "The sysroot in \(sysroot) is incomplete. Download it again with --msvc=portable --msvc-refresh.")
        }
        let include = sysroot / "Windows Kits" / "10" / "Include" / sdkVersion

        // The Swift compiler maps its modulemaps for the C runtime and the Windows SDK into the
        // SDK's header directories only for SDKs it finds itself (in the registry, or with
        // -windows-sdk-root). Map them in with a VFS overlay, which leaves the shared sysroot as
        // Microsoft ships it and lets every toolchain use its own modulemaps.
        let shared = toolchain.sdk / "usr" / "share"
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: shared.string)) ?? []).sorted()
        let modulemaps = self.modulemapPlacements(files, include: include, vcInclude: vc / "include")
        // Headers the modulemaps name (such as SwiftUCRT.h on main) go next to the modulemap.
        let headers = self.referencedHeaderPlacements(modulemaps, files: files) { file in
            (try? String(contentsOfFile: (shared / file).string, encoding: .utf8)) ?? ""
        }
        let placements = (modulemaps + headers).map { (virtualPath: $0.destination, realPath: shared / $0.file) }
        try Data(self.overlayYAML(placements).utf8).write(to: overlay)
        var stamped = [overlay.string]

        var defines: [String] = []
        // The STL refuses clangs older than it expects (error STL1000), as the Visual Studio 2026 STL
        // (14.50 and later) does with Swift 6.2 to 6.4. Allow the mismatch, deliberately and with a
        // warning, rather than leaving C++ broken.
        if let required = self.requiredClangMajor(vc), let clang = await VisualStudio.clangMajor(bin: toolchain.bin), clang < required {
            await ctx.message("Warning: the MSVC STL \(vc.lastComponent!.string) expects clang \(required) or later and this toolchain has clang \(clang); defining _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH for it.")
            defines.append("-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH")
        }
        let delayLoad = self.importLibrariesWithoutDLLs(toolchain)
        let hasDelayImp = FileManager.default.fileExists(atPath: (vc / "lib" / self.arch / "delayimp.lib").string)
        for config in configs {
            let text = config.clangCL
                ? self.clangCLConfig(sysroot: sysroot, extra: defines)
                : self.clangConfig(sysroot: sysroot, overlay: overlay, delayLoad: hasDelayImp ? delayLoad : [], extra: defines)
            try Data(text.utf8).write(to: config.path)
            stamped.append(config.path.string)
        }
        try JSONEncoder().encode(stamped).write(to: stamp)
    }

    /// The `<triple>-clang-cl.cfg` for clang-cl, in its own option syntax.
    static func clangCLConfig(sysroot: FilePath, extra: [String] = []) -> String {
        ([
            "\(self.marker) link with lld against the Microsoft C runtime and Windows SDK in \(sysroot.string).",
            "-fuse-ld=lld",
            "/winsysroot \(self.quoteConfigArgument(sysroot.string))",
        ] + extra.map { $0.replacingOccurrences(of: "-D", with: "/D") }).joined(separator: "\n") + "\n"
    }

    static func isOurs(_ file: FilePath) -> Bool {
        guard let data = FileManager.default.contents(atPath: file.string) else {
            return false
        }
        return String(decoding: data.prefix(256), as: UTF8.self).hasPrefix(self.marker)
    }

    private static func requiredClangMajor(_ vc: FilePath) -> Int? {
        (try? String(contentsOfFile: (vc / "include" / "yvals_core.h").string, encoding: .utf8)).flatMap { VisualStudio.requiredClangMajor(yvalsCore: $0) }
    }

    /// Where each of the toolchain's modulemaps and API notes (the files in `<SDK>\usr\share`) goes in
    /// the sysroot. Later files win when two map to the same place.
    static func modulemapPlacements(_ files: [String], include: FilePath, vcInclude: FilePath) -> [(file: String, destination: FilePath)] {
        var byDestination: [FilePath: String] = [:]
        var order: [FilePath] = []
        let newLayout = files.contains { $0.lowercased() == "um.modulemap" }
        for file in files {
            let name = file.lowercased()
            let destination: FilePath? = switch name {
            case "ucrt.modulemap": include / "ucrt" / "module.modulemap"
            case "ucrt.apinotes": include / "ucrt" / "ucrt.apinotes"
            case "vcruntime.modulemap": vcInclude / "module.modulemap"
            case "vcruntime.apinotes": vcInclude / "vcruntime.apinotes"
            // On main, winsdk.modulemap is an umbrella at the top, with um/shared/winrt modulemaps.
            case "winsdk.modulemap" where newLayout: include / "module.modulemap"
            case "um.modulemap", "shared.modulemap", "winrt.modulemap":
                include / String(name.dropLast(".modulemap".count)) / "module.modulemap"
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

    /// The files of `files` that a placed modulemap names with `header "<file>"`, placed in that
    /// modulemap's directory. This follows the toolchain's own modulemaps, whatever their layout.
    static func referencedHeaderPlacements(_ modulemaps: [(file: String, destination: FilePath)], files: [String], contents: (String) -> String) -> [(file: String, destination: FilePath)] {
        let available = Dictionary(files.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var placements: [(file: String, destination: FilePath)] = []
        var placed: Set<FilePath> = []
        for modulemap in modulemaps where modulemap.file.lowercased().hasSuffix(".modulemap") {
            for match in contents(modulemap.file).matches(of: #/header\s+"([^"/\\]+)"/#) {
                guard let file = available[String(match.output.1).lowercased()] else {
                    continue
                }
                let destination = modulemap.destination.removingLastComponent() / String(match.output.1)
                if placed.insert(destination).inserted {
                    placements.append((file, destination))
                }
            }
        }
        return placements
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

    /// The `<triple>.cfg` that points clang at the sysroot when compiling for this machine.
    static func clangConfig(sysroot: FilePath, overlay: FilePath, delayLoad: [String], extra: [String] = []) -> String {
        var lines = [
            "\(self.marker) link with lld against the Microsoft C runtime and Windows SDK in \(sysroot.string).",
            "-fuse-ld=lld",
            "-Xmicrosoft-windows-sys-root \(self.quoteConfigArgument(sysroot.string))",
            "-ivfsoverlay \(self.quoteConfigArgument(overlay.string))",
        ] + extra
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
        let libDir = toolchain.sdk / "usr" / "lib" / "swift" / "windows" / (self.arch == "arm64" ? "aarch64" : "x86_64")
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
    struct Info: Decodable {
        var productDisplayVersion: String?
    }

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

    var info: Info?
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
}
