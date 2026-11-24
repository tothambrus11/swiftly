#if os(Windows)
import Foundation
import SwiftlyCore
import SystemPackage
import Testing
@testable import WindowsPlatform

@Suite struct WindowsPlatformTests {
    // An excerpt of the Burn manifest of the swift.org 6.4.3 installer.
    static let burnManifest = """
    <?xml version="1.0" encoding="utf-8"?><BurnManifest EngineVersion="4.0.5.0" ProtocolVersion="1" Win64="yes" xmlns="http://wixtoolset.org/schemas/v4/2008/Burn">\
    <Container Id="AssertsToolchainContainer" FileSize="841075862" Hash="DAA0AA" FilePath="installer.exe" AttachedIndex="1" Attached="yes" Primary="yes" />\
    <Container Id="SharedContainer" FileSize="572768866" Hash="622853" FilePath="installer.exe" AttachedIndex="3" Attached="yes" Primary="yes" />\
    <MsiPackage Id="bld.asserts.msi" Cache="keep" PerMachine="no" InstallCondition="OptionsInstallAssertsToolchain = 1" Version="6.4.3">\
    <MsiProperty Id="INSTALLROOT" Value="[InstallRoot]" /><Provides Key="{4D8CB593}_v6.4.3" Version="6.4.3" DisplayName="Swift Build Tools (Asserts)" />\
    <PayloadRef Id="bld.asserts.msi" /><PayloadRef Id="cabn6SXNROfFd.gMb_HgFzkkVsbWpE" /></MsiPackage>\
    <MsiPackage Id="windows.msi" Cache="keep" PerMachine="no" Version="6.4.3"><PayloadRef Id="windows.msi" />\
    <PayloadRef Id="cabIiBMkTDbNGuh0UCsTxi5GmvGzas" /><PayloadRef Id="cab6Iqm9RD35DwfVMg18tDogASPtTA" /></MsiPackage>\
    <Payload Id="bld.asserts.msi" FilePath="bld.asserts.msi" FileSize="669986" Hash="D3291B" Packaging="embedded" SourcePath="a0" Container="AssertsToolchainContainer" />\
    <Payload Id="windows.msi" FilePath="windows.msi" FileSize="601207" Hash="5620E7" Packaging="embedded" SourcePath="a12" Container="SharedContainer" />\
    <Payload Id="cabn6SXNROfFd.gMb_HgFzkkVsbWpE" FilePath="bld.asserts.cab" FileSize="451087764" Packaging="embedded" SourcePath="a13" Container="AssertsToolchainContainer" />\
    <Payload Id="cabIiBMkTDbNGuh0UCsTxi5GmvGzas" FilePath="windows.cab" FileSize="42944524" Packaging="embedded" SourcePath="a34" Container="SharedContainer" />\
    <Payload Id="cab6Iqm9RD35DwfVMg18tDogASPtTA" FilePath="sdk.windows.x64.cab" FileSize="72746145" Packaging="embedded" SourcePath="a36" Container="SharedContainer" />\
    <Payload Id="ux.dll" FilePath="ux.dll" FileSize="10" Packaging="embedded" SourcePath="u0" />\
    </BurnManifest>
    """

    @Test func parsesBurnManifest() throws {
        let manifest = try BurnManifest(xml: Self.burnManifest)
        #expect(manifest.containers == [
            .init(id: "AssertsToolchainContainer", attachedIndex: 1, hash: "DAA0AA"),
            .init(id: "SharedContainer", attachedIndex: 3, hash: "622853"),
        ])
        #expect(manifest.packages == [
            .init(id: "bld.asserts.msi", payloads: ["bld.asserts.msi", "cabn6SXNROfFd.gMb_HgFzkkVsbWpE"]),
            .init(id: "windows.msi", payloads: ["windows.msi", "cabIiBMkTDbNGuh0UCsTxi5GmvGzas", "cab6Iqm9RD35DwfVMg18tDogASPtTA"]),
        ])
        #expect(manifest.payloads["cab6Iqm9RD35DwfVMg18tDogASPtTA"] == .init(
            id: "cab6Iqm9RD35DwfVMg18tDogASPtTA", filePath: "sdk.windows.x64.cab", sourcePath: "a36", container: "SharedContainer"
        ))
        #expect(manifest.payloads["ux.dll"]?.container == nil)
    }

    @Test func rejectsManifestWithoutPackages() throws {
        #expect(throws: SwiftlyError.self) { try BurnManifest(xml: "<BurnManifest></BurnManifest>") }
    }

    /// A minimal PE header with a `.wixburn` section, like the start of a Burn bundle.
    static func bundleHeader(stubSize: UInt32, containers: [UInt32]) -> Data {
        var bytes = [UInt8](repeating: 0, count: 0x400)
        func put32(_ value: UInt32, at offset: Int) {
            for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * UInt32(i))) & 0xFF) }
        }
        func put16(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(value & 0xFF)
            bytes[offset + 1] = UInt8(value >> 8)
        }
        let pe = 0x80
        put32(UInt32(pe), at: 0x3C)
        put16(2, at: pe + 6) // two sections
        put16(0xF0, at: pe + 20) // size of the optional header
        let sections = pe + 24 + 0xF0
        bytes.replaceSubrange(sections..<(sections + 5), with: Array(".text".utf8))
        bytes.replaceSubrange((sections + 40)..<(sections + 48), with: Array(".wixburn".utf8))
        let burn = 0x300
        put32(UInt32(burn), at: sections + 40 + 20)
        put32(0x00F1_4300, at: burn)
        put32(stubSize, at: burn + 24)
        put32(UInt32(containers.count), at: burn + 44)
        for (i, size) in containers.enumerated() { put32(size, at: burn + 48 + 4 * i) }
        return Data(bytes)
    }

    @Test func readsBundleLayout() throws {
        let layout = try BurnBundle.layout(of: Self.bundleHeader(stubSize: 1_082_368, containers: [220_020, 841_075_862, 572_768_866]))
        #expect(layout == .init(stubSize: 1_082_368, containerSizes: [220_020, 841_075_862, 572_768_866]))
    }

    @Test func rejectsFilesThatAreNotBundles() throws {
        var header = Self.bundleHeader(stubSize: 1, containers: [1])
        header[0x301] = 0 // break the magic number (00 43 F1 00)
        #expect(throws: SwiftlyError.self) { try BurnBundle.layout(of: header) }
        #expect(throws: SwiftlyError.self) { try BurnBundle.layout(of: Data(count: 16)) }
    }

    @Test func findsCabinetOfTheExpectedSize() throws {
        var data = Data(count: 64)
        // A cabinet header ("MSCF", reserved, size) of the wrong size, then one of the right size.
        data.replaceSubrange(4..<16, with: [0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0, 0x10, 0, 0, 0])
        data.replaceSubrange(20..<32, with: [0x4D, 0x53, 0x43, 0x46, 0, 0, 0, 0, 0x34, 0x12, 0, 0])
        #expect(BurnBundle.findCabinet(in: data, size: 0x1234) == 20)
        #expect(BurnBundle.findCabinet(in: data, size: 0x99) == nil)
    }

    @Test func selectsAssertsToolchainPackages() throws {
        let ids = [
            "bld.asserts.msi", "bld.noasserts.msi", "cli.asserts.msi", "cli.noasserts.msi", "dbg.asserts.msi", "dbg.noasserts.msi",
            "python.msi", "ide.asserts.msi", "ide.noasserts.msi", "res.msi", "rtl.arm64.msi", "windows.msi",
        ]
        let selection = try WindowsToolchain.selectPackages(ids, arch: "arm64")
        #expect(selection == .init(
            toolchain: ["bld.asserts.msi", "cli.asserts.msi", "windows.msi"],
            runtime: "rtl.arm64.msi",
            assemblyDonors: ["ide.asserts.msi", "dbg.asserts.msi"]
        ))
    }

    @Test func selectsPackagesOfSingleFlavorInstallers() throws {
        // Swift 6.2's installer has one toolchain flavor and one runtime package.
        let ids = ["rtl.msi", "bld.msi", "cli.msi", "dbg.msi", "python.msi", "ide.msi", "android.msi", "windows.msi"]
        let selection = try WindowsToolchain.selectPackages(ids, arch: "amd64")
        #expect(selection == .init(toolchain: ["bld.msi", "cli.msi", "windows.msi"], runtime: "rtl.msi", assemblyDonors: ["ide.msi", "dbg.msi"]))
        #expect(throws: SwiftlyError.self) { try WindowsToolchain.selectPackages(["bld.msi", "windows.msi", "rtl.msi"], arch: "amd64") }
    }

    @Test func readsDependentAssembliesFromManifest() throws {
        let manifest = """
        <assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
          <dependency><dependentAssembly>
            <assemblyIdentity type="win32" name="Foundation" version="1.0.0.0" processorArchitecture="amd64"/>
          </dependentAssembly></dependency>
          <dependency>
            <dependentAssembly>
              <assemblyIdentity name="FoundationXML" processorArchitecture="amd64" type="win32" version="1.0.0.0"/>
            </dependentAssembly>
          </dependency>
          <dependency><dependentAssembly><assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0"/></dependentAssembly></dependency>
        </assembly>
        """
        #expect(WindowsToolchain.dependentAssemblies(inManifest: manifest) == ["Foundation", "FoundationXML", "Microsoft.Windows.Common-Controls"])
    }

    static let vsManifest = """
    {"manifestVersion":"1.1","packages":[
      {"id":"Microsoft.VisualCpp.CRT.Headers","version":"17.14.36015.10","type":"Component",
       "dependencies":{"Microsoft.VC.14.44.17.14.CRT.Headers.base":"[17.14,18.0)","Microsoft.VisualCpp.Redist":{"version":"[1.0,)"}}},
      {"id":"Microsoft.VC.14.44.17.14.CRT.Headers.base","version":"14.44.35220","type":"Vsix","payloads":[
        {"fileName":"payload.vsix","sha256":"AAAA0000000000000000000000000000000000000000000000000000000000AA","size":2000000,
         "url":"https://download.visualstudio.microsoft.com/download/pr/1/0000000000000000000000000000000000000000000000000000000000000001/payload.vsix"}]},
      {"id":"Microsoft.VC.14.44.17.14.CRT.x64.Store.base","version":"14.44.35220","type":"Vsix","payloads":[
        {"fileName":"payload.vsix","size":3000000,
         "url":"https://download.visualstudio.microsoft.com/download/pr/2/BBBB000000000000000000000000000000000000000000000000000000000002/payload.vsix"}]},
      {"id":"Microsoft.VC.14.44.17.14.CRT.x64.Desktop.base","version":"14.44.35220","type":"Vsix","payloads":[
        {"fileName":"payload.vsix","sha256":"cccc000000000000000000000000000000000000000000000000000000000003",
         "url":"https://download.visualstudio.microsoft.com/download/pr/3/x/payload.vsix"}]},
      {"id":"Microsoft.VC.14.45.17.15.CRT.Headers.base","version":"14.45.35000","type":"Vsix","payloads":[{"url":"https://example.invalid/0000000000000000000000000000000000000000000000000000000000000004/p.vsix"}]},
      {"id":"Microsoft.VC.14.44.17.14.CRT.ARM64.Store.base","version":"14.44.35220","type":"Vsix","chip":"arm64","payloads":[]}
    ]}
    """

    @Test func picksDefaultCRTPackagesFromVisualStudioManifest() throws {
        let manifest = try JSONDecoder().decode(VSManifest.self, from: Data(Self.vsManifest.utf8))
        let (version, files) = try MSVCSysroot.crtFiles(in: manifest, arch: "x64")
        #expect(version == "14.44.35220")
        #expect(files.map(\.name) == [
            "Microsoft.VC.14.44.17.14.CRT.Headers.base", "Microsoft.VC.14.44.17.14.CRT.x64.Store.base", "Microsoft.VC.14.44.17.14.CRT.x64.Desktop.base",
        ])
        // The hash comes from the payload, or else from its URL; either way lowercase.
        #expect(files.map(\.sha256) == [
            "aaaa0000000000000000000000000000000000000000000000000000000000aa",
            "bbbb000000000000000000000000000000000000000000000000000000000002",
            "cccc000000000000000000000000000000000000000000000000000000000003",
        ])
        #expect(files[0].size == 2_000_000)
        // There's no arm64 runtime with a payload in this excerpt.
        #expect(throws: SwiftlyError.self) { try MSVCSysroot.crtFiles(in: manifest, arch: "arm64") }
    }

    @Test func picksNewestStableVersion() throws {
        #expect(MSVCSysroot.newestStableVersion(["10.0.22621.3233", "10.0.26100.9457", "10.0.26100.10000-preview", "10.0.9200.1"]) == "10.0.26100.9457")
        #expect(MSVCSysroot.newestStableVersion([]) == nil)
        #expect(MSVCSysroot.compareVersions("14.9", "14.44"))
        #expect(!MSVCSysroot.compareVersions("14.44.35207", "14.44"))
    }

    @Test func escapesClangConfigPaths() throws {
        #expect(MSVCSysroot.quoteConfigArgument(#"C:\Users\A B\swiftly"#) == #""C:\\Users\\A B\\swiftly""#)
        #expect(MSVCSysroot.quoteConfigArgument(#"C:\a"b"#) == #""C:\\a\"b""#)

        let config = MSVCSysroot.clangConfig(
            sysroot: FilePath(#"C:\Users\me\AppData\Local\swiftly\msvc-sysroot-x64"#),
            overlay: FilePath(#"C:\Users\me\AppData\Local\swiftly\toolchains\6.4.3\msvc-modulemaps.yaml"#),
            delayLoad: []
        )
        let lines = config.split(separator: "\n").map(String.init)
        #expect(lines.dropFirst() == [
            "-fuse-ld=lld",
            #"-Xmicrosoft-windows-sys-root "C:\\Users\\me\\AppData\\Local\\swiftly\\msvc-sysroot-x64""#,
            #"-ivfsoverlay "C:\\Users\\me\\AppData\\Local\\swiftly\\toolchains\\6.4.3\\msvc-modulemaps.yaml""#,
        ])
        #expect(lines[0].hasPrefix("#"))
    }

    @Test func delayLoadsMissingDLLsInClangConfig() throws {
        let config = MSVCSysroot.clangConfig(sysroot: FilePath(#"C:\s"#), overlay: FilePath(#"C:\o.yaml"#), delayLoad: ["swift_Builtin_float.dll", "swift_Volatile.dll"])
        #expect(config.hasSuffix("""
        --start-no-unused-arguments
        -Wl,/delayload:swift_Builtin_float.dll
        -Wl,/delayload:swift_Volatile.dll
        -Wl,delayimp.lib
        --end-no-unused-arguments

        """))
    }

    @Test func placesModulemapsNextToTheirHeaders() throws {
        let include = FilePath(#"C:\s\Windows Kits\10\Include\10.0.26100.0"#)
        let vc = FilePath(#"C:\s\VC\Tools\MSVC\14.44.35207\include"#)
        let files = ["Info.plist", "ucrt.modulemap", "vcruntime.apinotes", "vcruntime.modulemap", "winsdk.modulemap", "winsdk_shared.modulemap"]
        let placements = MSVCSysroot.modulemapPlacements(files, include: include, vcInclude: vc)
        #expect(placements.map(\.file) == ["ucrt.modulemap", "vcruntime.apinotes", "vcruntime.modulemap", "winsdk.modulemap", "winsdk_shared.modulemap"])
        #expect(placements.map(\.destination) == [
            include / "ucrt" / "module.modulemap",
            vc / "vcruntime.apinotes",
            vc / "module.modulemap",
            include / "um" / "module.modulemap",
            include / "shared" / "module.modulemap",
        ])
    }

    @Test func writesVFSOverlay() throws {
        let yaml = try MSVCSysroot.overlayYAML([
            (virtualPath: FilePath(#"C:\s\inc\ucrt\module.modulemap"#), realPath: FilePath(#"C:\t\ucrt.modulemap"#)),
            (virtualPath: FilePath(#"C:\s\inc\ucrt\ucrt.apinotes"#), realPath: FilePath(#"C:\t\ucrt.apinotes"#)),
            (virtualPath: FilePath(#"C:\s\vc\module.modulemap"#), realPath: FilePath(#"C:\t\vcruntime.modulemap"#)),
        ])
        let json = try #require(JSONSerialization.jsonObject(with: Data(yaml.utf8)) as? [String: Any])
        #expect(json["version"] as? Int == 0)
        #expect(json["case-sensitive"] as? String == "false")
        let roots = try #require(json["roots"] as? [[String: Any]])
        #expect(roots.map { $0["name"] as? String } == [#"C:\s\inc\ucrt"#, #"C:\s\vc"#])
        let ucrt = try #require(roots[0]["contents"] as? [[String: Any]])
        #expect(ucrt.map { $0["name"] as? String } == ["module.modulemap", "ucrt.apinotes"])
        #expect(ucrt[0]["external-contents"] as? String == #"C:\t\ucrt.modulemap"#)
    }

    @Test func putsRuntimeAfterToolchainOnPath() throws {
        let runtime = FilePath(#"C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin"#)
        #expect(Windows.insertingAfterFirst(runtime, into: #"C:\tc\usr\bin;C:\Windows;C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin\"#)
            == #"C:\tc\usr\bin;C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin;C:\Windows"#)
        #expect(Windows.insertingAfterFirst(runtime, into: "") == runtime.string)
    }
}
#endif
