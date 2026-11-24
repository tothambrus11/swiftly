#if os(Windows)
import Foundation
@testable import Swiftly
@testable import SwiftlyCore
import SystemPackage
import Testing
@testable import WindowsPlatform
import WinSDK

@Suite struct WindowsPlatformTests {
    /// A scratch directory, deleted after `body`.
    func withScratchDirectory(_ body: (FilePath) async throws -> Void) async throws {
        let dir = fs.mktemp()
        try await fs.mkdir(.parents, atPath: dir)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        try await body(dir)
    }

    /// Starts `executable`, which is a copy of ping.exe, so that it runs for a while.
    func startRunning(_ executable: FilePath) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable.string)
        process.arguments = ["-n", "60", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    var ping: FilePath { Win32.system32 / "PING.EXE" }

    @Test func proxiesAreHardLinksToSwiftly() async throws {
        try await self.withScratchDirectory { dir in
            let swiftly = dir / "swiftly.exe"
            try Data("swiftly".utf8).write(to: swiftly)
            try Data("other".utf8).write(to: dir / "other.exe")
            let platform = Windows()

            try await platform.createProxy(SwiftlyTests.ctx, at: dir / "swift.exe", to: swiftly)

            #expect(try await platform.isProxy(SwiftlyTests.ctx, dir / "swift.exe", to: swiftly))
            // The file id doesn't depend on how the path is spelled.
            #expect(try await platform.isProxy(SwiftlyTests.ctx, FilePath(dir.string.uppercased()) / "SWIFT.EXE", to: swiftly))
            #expect(try await !platform.isProxy(SwiftlyTests.ctx, dir / "other.exe", to: swiftly))
            #expect(try await !platform.isProxy(SwiftlyTests.ctx, swiftly, to: swiftly))
            #expect(try await !platform.isProxy(SwiftlyTests.ctx, FilePath(swiftly.string.uppercased()), to: swiftly))
            #expect(try await !platform.isProxy(SwiftlyTests.ctx, dir / "missing.exe", to: swiftly))
        }
    }

    @Test func onlyExecutablesGetProxies() {
        #expect(Windows().proxyCandidates(["swift.exe", "swiftCore.dll", "clang.cfg", "FoundationXML", "SWIFTC.EXE"]) == ["swift.exe", "SWIFTC.EXE"])
    }

    @Test func swiftlyIsRecognizedInAnyCase() {
        #expect(isSwiftlyExecutable("swiftly"))
        #expect(isSwiftlyExecutable("swiftly.exe"))
        #expect(isSwiftlyExecutable("Swiftly.EXE"))
        #expect(!isSwiftlyExecutable("swift.exe"))
        #expect(!isSwiftlyExecutable("swiftly.exe.swiftly-0123abcd.old"))
    }

    @Test func recognizesOnlyItsOwnLeftovers() {
        #expect(Windows.isLeftover("swiftly.exe.swiftly-0123abcd.old"))
        #expect(Windows.isLeftover("swift.exe.swiftly-0123ABCD.new"))
        #expect(!Windows.isLeftover("swift.exe"))
        #expect(!Windows.isLeftover("notes.0123abcd.old"))
        #expect(!Windows.isLeftover("notes.old"))
        #expect(Windows.leftoverName(for: FilePath(#"C:\b\swift.exe"#), stamp: "0123abcd", kind: "old") == FilePath(#"C:\b\swift.exe.swiftly-0123abcd.old"#))
    }

    /// Upgrading swiftly while one of its proxies runs: the running proxy is renamed aside, and the
    /// proxies are links to the new swiftly.exe afterwards. Once nothing runs the old files, they're
    /// deleted.
    @Test func replacesSwiftlyWhileAProxyRuns() async throws {
        try await self.withScratchDirectory { dir in
            let bin = dir / "bin"
            try await fs.mkdir(atPath: bin)
            let swiftly = bin / "swiftly.exe"
            try FileManager.default.copyItem(atPath: self.ping.string, toPath: swiftly.string)
            try Win32.createHardLink(at: bin / "swift.exe", to: swiftly)
            try Win32.createHardLink(at: bin / "swiftc.exe", to: swiftly)
            // A proxy that an upgrade which didn't finish left linked to an older swiftly.exe.
            try Data("older swiftly".utf8).write(to: bin / "swiftly.exe.swiftly-11111111.old")
            try Win32.createHardLink(at: bin / "lldb.exe", to: bin / "swiftly.exe.swiftly-11111111.old")
            // Not a proxy: an executable that isn't swiftly.
            try Data("tool".utf8).write(to: bin / "tool.exe")
            let newSwiftly = dir / "new.exe"
            try Data("new swiftly".utf8).write(to: newSwiftly)
            let running = try self.startRunning(bin / "swift.exe")
            defer { running.terminate() }

            try Windows.replaceSwiftly(in: bin, with: newSwiftly)

            #expect(try Data(contentsOf: swiftly) == Data("new swiftly".utf8))
            #expect(Windows.isLink(bin / "swift.exe", to: swiftly))
            #expect(Windows.isLink(bin / "swiftc.exe", to: swiftly))
            #expect(Windows.isLink(bin / "lldb.exe", to: swiftly))
            #expect(try Data(contentsOf: bin / "tool.exe") == Data("tool".utf8))
            // The running proxy couldn't be deleted yet.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: bin.string).filter(Windows.isLeftover)
            #expect(!leftovers.isEmpty)

            running.terminate()
            running.waitUntilExit()
            Windows.removeLeftovers(in: bin)
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin.string).filter(Windows.isLeftover).isEmpty)
        }
    }

    /// A failed upgrade leaves swiftly.exe and its proxies as they were.
    @Test func rollsBackAFailedReplacement() async throws {
        try await self.withScratchDirectory { dir in
            let bin = dir / "bin"
            try await fs.mkdir(atPath: bin)
            let swiftly = bin / "swiftly.exe"
            try Data("old swiftly".utf8).write(to: swiftly)
            try Win32.createHardLink(at: bin / "swift.exe", to: swiftly)

            #expect(throws: (any Error).self) {
                try Windows.replaceSwiftly(in: bin, with: dir / "missing.exe")
            }

            #expect(try Data(contentsOf: swiftly) == Data("old swiftly".utf8))
            #expect(Windows.isLink(bin / "swift.exe", to: swiftly))
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin.string).sorted() == ["swift.exe", "swiftly.exe"])
        }
    }

    /// A failure in the middle of relinking the proxies undoes everything done so far.
    @Test func rollsBackAReplacementThatFailsHalfway() async throws {
        try await self.withScratchDirectory { dir in
            let bin = dir / "bin"
            try await fs.mkdir(atPath: bin)
            let swiftly = bin / "swiftly.exe"
            try Data("old swiftly".utf8).write(to: swiftly)
            try Win32.createHardLink(at: bin / "swift.exe", to: swiftly)
            try Win32.createHardLink(at: bin / "swiftc.exe", to: swiftly)
            let newSwiftly = dir / "new.exe"
            try Data("new swiftly".utf8).write(to: newSwiftly)
            struct Injected: Error {}
            var relinked = 0

            #expect(throws: Injected.self) {
                try Windows.replaceSwiftly(in: bin, with: newSwiftly, stamp: "0000aaaa") { _ in
                    relinked += 1
                    if relinked == 2 { throw Injected() }
                }
            }

            #expect(try Data(contentsOf: swiftly) == Data("old swiftly".utf8))
            #expect(Windows.isLink(bin / "swift.exe", to: swiftly))
            #expect(Windows.isLink(bin / "swiftc.exe", to: swiftly))
            #expect(try FileManager.default.contentsOfDirectory(atPath: bin.string).sorted() == ["swift.exe", "swiftc.exe", "swiftly.exe"])
        }
    }

    /// installSwiftlyBin changes nothing when swiftly runs from the bin directory already (by file
    /// id), and otherwise takes the install lock.
    @Test func installsSwiftlyUnderTheLockUnlessItsThereAlready() async throws {
        try await self.withScratchDirectory { dir in
            let bin = dir / "bin"
            let home = dir / "home"
            try await fs.mkdir(atPath: bin)
            try await fs.mkdir(atPath: home)
            try Data("swiftly".utf8).write(to: bin / "swiftly.exe")
            try Win32.createHardLink(at: bin / "swift.exe", to: bin / "swiftly.exe")
            // A proxy is the same file: nothing to install.
            #expect(try await !Windows.installSwiftly(FilePath((bin / "swift.exe").string.uppercased()), binDir: bin, homeDir: home))

            let newSwiftly = dir / "new.exe"
            try Data("new swiftly".utf8).write(to: newSwiftly)
            let lock = try FileLock(at: home / "swiftly.lock")
            await #expect(throws: (any Error).self) {
                try await Windows.installSwiftly(newSwiftly, binDir: bin, homeDir: home, lockTimeout: 1)
            }
            #expect(try Data(contentsOf: bin / "swiftly.exe") == Data("swiftly".utf8))
            try await lock.unlock()

            #expect(try await Windows.installSwiftly(newSwiftly, binDir: bin, homeDir: home, lockTimeout: 10))
            #expect(try Data(contentsOf: bin / "swiftly.exe") == Data("new swiftly".utf8))
            #expect(Windows.isLink(bin / "swift.exe", to: bin / "swiftly.exe"))
        }
    }

    /// After removing a running proxy, what's left of it (if Windows didn't delete it) isn't a proxy:
    /// swiftly isn't linked anymore.
    @Test func aRemovedRunningProxyIsntAProxy() async throws {
        try await self.withScratchDirectory { home in
            let bin = home / "bin"
            try await fs.mkdir(atPath: bin)
            let swiftly = bin / "swiftly.exe"
            try FileManager.default.copyItem(atPath: self.ping.string, toPath: swiftly.string)
            try Win32.createHardLink(at: bin / "swift.exe", to: swiftly)
            let running = try self.startRunning(bin / "swift.exe")
            defer { running.terminate() }
            let ctx = SwiftlyCoreContext(mockedHomeDir: home, httpRequestExecutor: HTTPRequestExecutorFail(), outputHandler: nil, inputProvider: nil)

            _ = try await Windows().removeFromBinDir(ctx, bin / "swift.exe")

            #expect(try await Unlink.existingProxies(ctx).isEmpty)
            for leftover in try FileManager.default.contentsOfDirectory(atPath: bin.string).filter(Windows.isLeftover) {
                #expect(try await !Windows().isProxy(ctx, bin / leftover, to: swiftly))
            }
        }
    }

    @Test func removesARunningProxy() async throws {
        try await self.withScratchDirectory { dir in
            let swiftly = dir / "swiftly.exe"
            try FileManager.default.copyItem(atPath: self.ping.string, toPath: swiftly.string)
            try Win32.createHardLink(at: dir / "swift.exe", to: swiftly)
            try Win32.createHardLink(at: dir / "swiftc.exe", to: swiftly)
            let running = try self.startRunning(dir / "swift.exe")
            defer { running.terminate() }

            #expect(try await Windows().removeFromBinDir(SwiftlyTests.ctx, dir / "swiftc.exe") == nil)
            let leftover = try await Windows().removeFromBinDir(SwiftlyTests.ctx, dir / "swift.exe")

            #expect(!FileManager.default.fileExists(atPath: (dir / "swift.exe").string))
            #expect(!FileManager.default.fileExists(atPath: (dir / "swiftc.exe").string))
            // Windows may delete a name of a running executable (it has other names here, and NTFS
            // has POSIX delete semantics); if not, what's left is a leftover in the same directory.
            if let leftover {
                #expect(leftover.removingLastComponent() == dir)
                #expect(Windows.isLeftover(leftover.lastComponent!.string))
            }
        }
    }

    /// Unlink finds the proxies by file id, and swiftly.exe (a link to itself) isn't one.
    @Test func unlinkFindsProxiesButNotSwiftly() async throws {
        try await self.withScratchDirectory { home in
            let bin = home / "bin"
            try await fs.mkdir(atPath: bin)
            try Data("swiftly".utf8).write(to: bin / "swiftly.exe")
            try Data("other".utf8).write(to: bin / "tool.exe")
            let ctx = SwiftlyCoreContext(mockedHomeDir: home, httpRequestExecutor: HTTPRequestExecutorFail(), outputHandler: nil, inputProvider: nil)

            #expect(try await Unlink.existingProxies(ctx).isEmpty)

            try Win32.createHardLink(at: bin / "swift.exe", to: bin / "swiftly.exe")
            #expect(try await Unlink.existingProxies(ctx) == [bin / "swift.exe"])
        }
    }

    /// self-uninstall removes the proxies and swiftly.exe, also while swiftly.exe runs (as it does
    /// when swiftly uninstalls itself): that's renamed aside, to be deleted once it exits.
    @Test func selfUninstallRemovesProxiesAndARunningSwiftly() async throws {
        try await self.withScratchDirectory { home in
            let bin = home / "bin"
            try await fs.mkdir(atPath: bin)
            let swiftly = bin / "swiftly.exe"
            try FileManager.default.copyItem(atPath: self.ping.string, toPath: swiftly.string)
            try Win32.createHardLink(at: bin / "swift.exe", to: swiftly)
            try Win32.createHardLink(at: bin / "swiftc.exe", to: swiftly)
            try Data("{}".utf8).write(to: home / "config.json")
            let running = try self.startRunning(swiftly)
            defer { running.terminate() }
            let ctx = SwiftlyCoreContext(mockedHomeDir: home, httpRequestExecutor: HTTPRequestExecutorFail(), outputHandler: nil, inputProvider: nil)

            try await SelfUninstall.execute(ctx, verbose: false)

            // Only a leftover of swiftly.exe may remain (if Windows didn't let it be deleted while it runs).
            let left = try FileManager.default.contentsOfDirectory(atPath: bin.string)
            #expect(left.count <= 1)
            #expect(left.allSatisfy { Windows.isLeftover($0) && $0.lowercased().hasPrefix("swiftly.exe.") })
            #expect(!FileManager.default.fileExists(atPath: (home / "config.json").string))

            running.terminate()
            running.waitUntilExit()
            if FileManager.default.fileExists(atPath: bin.string) {
                Windows.removeLeftovers(in: bin)
                #expect(try FileManager.default.contentsOfDirectory(atPath: bin.string).isEmpty)
            }
        }
    }

    /// The helper's script passes as one double-quoted -Command argument.
    @Test func writesTheDeletionScriptForCommand() {
        let script = Windows.deletionScript([FilePath(#"C:\it's\swiftly.exe.swiftly-0000aaaa.old"#)], directories: [FilePath(#"C:\it's"#)], waitingFor: 42)
        #expect(!script.contains("\""))
        #expect(!script.contains("\n"))
        #expect(script.contains(#"'C:\it''s\swiftly.exe.swiftly-0000aaaa.old'"#))
        #expect(script.contains("Wait-Process -Id 42"))
    }

    // MARK: The user's Path and environment

    @Test func comparesPathEntriesLikeWindows() {
        let expand: (String) -> String = { $0.replacingOccurrences(of: "%LOCALAPPDATA%", with: #"C:\Users\Me\AppData\Local"#) }
        let bin = FilePath(#"C:\Users\Me\AppData\Local\swiftly\bin"#)
        func path(_ value: String, expandable: Bool = true) -> Win32.RegistryString { .init(value: value, expandable: expandable) }
        #expect(UserPath.contains(path(#"C:\Windows;%LOCALAPPDATA%\swiftly\bin"#), bin, expand: expand))
        #expect(UserPath.contains(path(#"c:\users\me\appdata\local\SWIFTLY\BIN\;C:\Windows"#), bin, expand: expand))
        #expect(UserPath.contains(path(#""C:/Users/Me/AppData/Local/swiftly/bin""#), bin, expand: expand))
        #expect(!UserPath.contains(path(#"C:\Users\Me\AppData\Local\swiftly\bin2"#), bin, expand: expand))
        #expect(!UserPath.contains(path(""), bin, expand: expand))
        // Windows doesn't expand the entries of a REG_SZ Path.
        #expect(!UserPath.contains(path(#"%LOCALAPPDATA%\swiftly\bin"#, expandable: false), bin, expand: expand))
    }

    @Test func addsAndRemovesPathEntries() {
        let expand: (String) -> String = { $0.replacingOccurrences(of: "%LOCALAPPDATA%", with: #"C:\L"#) }
        let bin = FilePath(#"C:\L\swiftly\bin"#)
        #expect(UserPath.adding(bin, to: "") == #"C:\L\swiftly\bin"#)
        #expect(UserPath.adding(bin, to: #"%USERPROFILE%\.dotnet\tools"#) == #"C:\L\swiftly\bin;%USERPROFILE%\.dotnet\tools"#)
        // Removing keeps the other entries exactly as written, unexpanded.
        let path = Win32.RegistryString(value: #"%LOCALAPPDATA%\swiftly\bin;%USERPROFILE%\.dotnet\tools;C:\L\SWIFTLY\bin\"#, expandable: true)
        #expect(UserPath.removing(bin, from: path, expand: expand) == #"%USERPROFILE%\.dotnet\tools"#)
    }

    @Test func findsASwiftAheadOfTheProxies() {
        let bin = FilePath(#"C:\L\swiftly\bin"#)
        let swiftExists: (FilePath) -> Bool = { $0.string.lowercased().hasSuffix(#"\swift\bin\swift.exe"#) || $0.string == #"rel\swift.exe"# }
        let machine = Win32.RegistryString(value: #"C:\Windows;;rel;C:\Swift\bin"#, expandable: false)
        let user = Win32.RegistryString(value: bin.string, expandable: false)
        #expect(UserPath.swiftAhead(of: bin, machine: machine, user: user, exists: swiftExists) == FilePath(#"C:\Swift\bin\swift.exe"#))
        // Entries after swiftly's don't matter, and empty or relative ones are skipped.
        #expect(UserPath.swiftAhead(of: bin, machine: .init(value: #";rel"#, expandable: false), user: .init(value: bin.string + #";C:\Swift\bin"#, expandable: false), exists: swiftExists) == nil)
    }

    /// The registry calls, on a scratch key: values keep their type, an emptied Path is deleted
    /// rather than left empty, and swiftly's variables are recorded and forgotten.
    @Test func roundTripsTheEnvironmentInTheRegistry() throws {
        let environment = RegistryEnvironment(root: HKEY_CURRENT_USER, subkey: #"Software\swiftly-tests\#(UUID().uuidString)"#)
        try Win32.createKey(environment.root, environment.subkey)
        defer { Win32.deleteKey(environment.root, environment.subkey) }

        try environment.update { key in
            try Win32.writeString(key, "Plain", .init(value: #"C:\x"#, expandable: false))
            try Win32.writeString(key, "Expandable", .init(value: #"%SystemRoot%\x"#, expandable: true))
        }
        #expect(try environment.read("Plain") == .init(value: #"C:\x"#, expandable: false))
        #expect(try environment.read("Expandable") == .init(value: #"%SystemRoot%\x"#, expandable: true))
        #expect(try environment.read("Missing") == nil)

        let bin = FilePath(#"C:\swiftly-tests\bin"#)
        #expect(try environment.addToPath(bin))
        #expect(try !environment.addToPath(bin))
        #expect(try environment.read("Path") == .init(value: bin.string, expandable: true))
        #expect(try environment.removeFromPath(bin))
        #expect(try environment.read("Path") == nil)

        try environment.update { try Win32.writeString($0, "Path", .init(value: #"%SystemRoot%\y"#, expandable: true)) }
        #expect(try environment.addToPath(bin))
        #expect(try environment.read("Path") == .init(value: bin.string + #";%SystemRoot%\y"#, expandable: true))
        #expect(try environment.removeFromPath(bin))
        #expect(try environment.read("Path") == .init(value: #"%SystemRoot%\y"#, expandable: true))

        // A REG_SZ Path stays REG_SZ.
        try environment.update { try Win32.writeString($0, "Path", .init(value: #"C:\z"#, expandable: false)) }
        #expect(try environment.addToPath(bin))
        #expect(try environment.read("Path") == .init(value: bin.string + #";C:\z"#, expandable: false))

        // Which Path entry swiftly added.
        let ownership = PathOwnership(root: environment.root, subkey: environment.subkey + #"\owner"#)
        #expect(try !ownership.owns(bin))
        try ownership.write(bin)
        #expect(try ownership.owns(FilePath(bin.string.uppercased() + #"\"#)))
        try ownership.clear()
        #expect(try !ownership.owns(bin))

        // A value that already says the same through REG_EXPAND_SZ stays as it is.
        let systemRoot = Win32.expandEnvironmentStrings("%SystemRoot%")
        try environment.update { try Win32.writeString($0, "SWIFTLY_HOME_DIR", .init(value: #"%SystemRoot%\s"#, expandable: true)) }
        #expect(try environment.record([("SWIFTLY_HOME_DIR", systemRoot + #"\s"#), ("SWIFTLY_BIN_DIR", #"C:\b"#)]) == ["SWIFTLY_BIN_DIR"])
        #expect(try environment.read("SWIFTLY_HOME_DIR") == .init(value: #"%SystemRoot%\s"#, expandable: true))
        #expect(try environment.read("SWIFTLY_BIN_DIR") == .init(value: #"C:\b"#, expandable: false))
        // Only values that still point to this installation are forgotten.
        #expect(try environment.forget([("SWIFTLY_HOME_DIR", systemRoot + #"\s"#), ("SWIFTLY_BIN_DIR", #"C:\other"#)]) == ["SWIFTLY_HOME_DIR"])
        #expect(try environment.read("SWIFTLY_HOME_DIR") == nil)
        #expect(try environment.read("SWIFTLY_BIN_DIR") != nil)
    }

    // MARK: Installing toolchains

    /// Builds an LZX cabinet with makecab.exe (part of Windows), embeds it in a larger file like a
    /// Burn bundle does, and extracts one of its files.
    @Test func extractsSelectedFilesFromAnEmbeddedCabinet() async throws {
        let dir = fs.mktemp()
        try FileManager.default.createDirectory(atPath: dir.string, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir.string) }
        let a = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let b = Data(String(repeating: "swiftly ", count: 50000).utf8)
        try a.write(to: dir / "a0")
        try b.write(to: dir / "a1")
        try Data("""
        .Set CabinetNameTemplate=test.cab
        .Set DiskDirectoryTemplate=.
        .Set CompressionType=LZX
        .Set Cabinet=on
        .Set Compress=on
        a0
        a1

        """.utf8).write(to: dir / "test.ddf")
        try await Win32.runTool("makecab.exe", ["/F", "test.ddf"], in: dir)

        let cabinet = try Data(contentsOf: dir / "test.cab")
        let prefix = Data(repeating: 0xAB, count: 12345)
        try (prefix + cabinet + Data(repeating: 0xCD, count: 999)).write(to: dir / "bundle.bin")

        let output = dir / "out" / "b.txt"
        try Cabinet.extract(from: dir / "bundle.bin", offset: prefix.count, length: cabinet.count, files: ["a1": output])
        #expect(try Data(contentsOf: output) == b)
        #expect(!FileManager.default.fileExists(atPath: (dir / "out" / "a0").string))

        // A file the cabinet doesn't have is an error.
        #expect(throws: SwiftlyError.self) {
            try Cabinet.extract(from: dir / "bundle.bin", offset: prefix.count, length: cabinet.count, files: ["a9": dir / "x"])
        }
    }

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
            .init(id: "bld.asserts.msi", payloads: ["bld.asserts.msi", "cabn6SXNROfFd.gMb_HgFzkkVsbWpE"], installCondition: "OptionsInstallAssertsToolchain = 1"),
            .init(id: "windows.msi", payloads: ["windows.msi", "cabIiBMkTDbNGuh0UCsTxi5GmvGzas", "cab6Iqm9RD35DwfVMg18tDogASPtTA"]),
        ])
        #expect(manifest.payloads["cab6Iqm9RD35DwfVMg18tDogASPtTA"] == .init(
            id: "cab6Iqm9RD35DwfVMg18tDogASPtTA", filePath: "sdk.windows.x64.cab", sourcePath: "a36", container: "SharedContainer", fileSize: 72_746_145
        ))
        #expect(manifest.payloads["bld.asserts.msi"]?.hash == "D3291B")
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
        put32(2, at: burn + 4)
        put32(stubSize, at: burn + 24)
        put32(UInt32(containers.count), at: burn + 44)
        for (i, size) in containers.enumerated() { put32(size, at: burn + 48 + 4 * i) }
        return Data(bytes)
    }

    /// Reads ranges of `data` like `BurnBundle` reads the bundle file.
    static func reader(_ data: Data) -> (Int, Int) throws -> Data {
        { offset, count in data.subdata(in: min(offset, data.count)..<min(offset + count, data.count)) }
    }

    @Test func readsBundleLayout() throws {
        let header = Self.bundleHeader(stubSize: 1_082_368, containers: [220_020, 841_075_862, 572_768_866])
        let layout = try BurnBundle.layout(read: Self.reader(header))
        #expect(layout == .init(stubSize: 1_082_368, containerSizes: [220_020, 841_075_862, 572_768_866]))
    }

    @Test func rejectsFilesThatAreNotBundles() throws {
        var header = Self.bundleHeader(stubSize: 1, containers: [1])
        header[0x301] = 0 // break the magic number (00 43 F1 00)
        #expect(throws: SwiftlyError.self) { try BurnBundle.layout(read: Self.reader(header)) }
        #expect(throws: SwiftlyError.self) { try BurnBundle.layout(read: Self.reader(Data(count: 16))) }
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
            "python.msi", "ide.asserts.msi", "ide.noasserts.msi", "rtl.amd64.msi", "rtl.arm64.msi", "windows.msi",
        ]
        let selection = try WindowsToolchain.selectPackages(ids, arch: "arm64")
        #expect(selection == .init(
            toolchain: ["bld.asserts.msi", "cli.asserts.msi", "windows.msi"],
            runtime: "rtl.arm64.msi",
            others: ["dbg.asserts.msi", "python.msi", "ide.asserts.msi"]
        ))
    }

    /// Snapshots have the toolchain's private runtime (prt), which the installer always installs.
    @Test func selectsThePrivateRuntimeOfSnapshots() throws {
        let ids = [
            "bld.asserts.msi", "bld.noasserts.msi", "cli.asserts.msi", "cli.noasserts.msi", "prt.asserts.msi", "prt.noasserts.msi",
            "rtl.amd64.msi", "rtl.arm64.msi", "windows.msi", "android.aarch64.msi",
        ]
        let selection = try WindowsToolchain.selectPackages(ids, arch: "amd64")
        #expect(selection.toolchain == ["bld.asserts.msi", "cli.asserts.msi", "windows.msi"])
        #expect(selection.runtime == "rtl.amd64.msi")
        #expect(selection.others == ["prt.asserts.msi"])
    }

    @Test func selectsPackagesOfSingleFlavorInstallers() throws {
        // Swift 6.2's installer has one toolchain flavor and one runtime package.
        let ids = ["rtl.msi", "bld.msi", "cli.msi", "dbg.msi", "python.msi", "ide.msi", "android.msi", "windows.msi"]
        let selection = try WindowsToolchain.selectPackages(ids, arch: "amd64")
        #expect(selection == .init(toolchain: ["bld.msi", "cli.msi", "windows.msi"], runtime: "rtl.msi", others: ["dbg.msi", "python.msi", "ide.msi"]))
        #expect(throws: SwiftlyError.self) { try WindowsToolchain.selectPackages(["bld.msi", "windows.msi", "rtl.msi"], arch: "amd64") }
        // Before 6.2, the SDK was in per-architecture packages.
        #expect(throws: SwiftlyError.self) { try WindowsToolchain.selectPackages(["bld.msi", "cli.msi", "sdk.windows.amd64.msi", "rtl.msi"], arch: "amd64") }
    }

    @Test func evaluatesInstallConditions() throws {
        let variables = ["OptionsInstallIDE": "1", "OptionsInstallDBG": "0", "Flavor": "asserts", "NativeMachine": "43620"]
        let numeric: Set<String> = ["OptionsInstallIDE", "OptionsInstallDBG", "NativeMachine"]
        #expect(try BurnCondition.evaluate("OptionsInstallIDE", variables: variables, numeric: numeric))
        #expect(try !BurnCondition.evaluate("OptionsInstallDBG", variables: variables, numeric: numeric))
        #expect(try BurnCondition.evaluate("OptionsInstallIDE = 1 AND NOT OptionsInstallDBG", variables: variables, numeric: numeric))
        #expect(try BurnCondition.evaluate("OptionsInstallDBG = 1 or (Flavor = \"asserts\" and NativeMachine = 43620)", variables: variables, numeric: numeric))
        #expect(try !BurnCondition.evaluate("NativeMachine <> 43620", variables: variables, numeric: numeric))
        #expect(throws: SwiftlyError.self) { try BurnCondition.evaluate("Unknown = 1", variables: variables, numeric: numeric) }
        // String-typed digits compare as strings, as in Burn.
        #expect(try BurnCondition.evaluate("Text < 9", variables: ["Text": "10"], numeric: []))
        #expect(try !BurnCondition.evaluate("Number < 9", variables: ["Number": "10"], numeric: ["Number"]))
        #expect(throws: SwiftlyError.self) { try BurnCondition.evaluate("OptionsInstallIDE ~= 1", variables: variables, numeric: numeric) }
        #expect(throws: SwiftlyError.self) { try BurnCondition.evaluate("(OptionsInstallIDE", variables: variables, numeric: numeric) }
    }

    /// The packages are those whose conditions hold with the bundle's defaults, without Android.
    @Test func selectsThePackagesTheBundleInstallsByDefault() throws {
        var manifest = try BurnManifest(xml: Self.burnManifest)
        manifest.packages = ["bld.asserts.msi", "cli.asserts.msi", "windows.msi", "rtl.amd64.msi", "rtl.arm64.msi", "ide.asserts.msi", "dbg.asserts.msi", "android.msi"].map {
            .init(id: $0, payloads: [], installCondition: nil)
        }
        manifest.packages[3].installCondition = "NativeMachine = 34404"
        manifest.packages[4].installCondition = "NativeMachine = 43620"
        manifest.packages[5].installCondition = "OptionsInstallIDE"
        manifest.packages[6].installCondition = "OptionsInstallDBG"
        // An optional package's condition isn't evaluated at all.
        manifest.packages[7].installCondition = "SomethingSwiftlyCantEvaluate ~= 1"
        manifest.variables = ["OptionsInstallIDE": "1", "OptionsInstallDBG": "0", "OptionsInstallAndroid": "1"]
        manifest.numericVariables = ["OptionsInstallIDE", "OptionsInstallDBG", "OptionsInstallAndroid"]
        let selection = try WindowsToolchain.selectPackages(manifest, arch: "amd64")
        #expect(selection.runtime == "rtl.amd64.msi")
        #expect(selection.others == ["ide.asserts.msi"])
    }

    @Test func rejectsPayloadNamesWindowsCantCreate() {
        #expect(BurnManifest.isSafeRelativePath(#"a\b.msi"#))
        #expect(!BurnManifest.isSafeRelativePath(#"a\CON.msi"#))
        #expect(!BurnManifest.isSafeRelativePath("nul"))
        #expect(!BurnManifest.isSafeRelativePath(#"a.\b.msi"#))
        #expect(!BurnManifest.isSafeRelativePath("b.msi "))
    }

    @Test func installsSwift62AndLater() throws {
        var ctx = SwiftlyTests.ctx
        ctx.installsTestToolchains = false
        let windows = Windows()
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "6.2.0")) == nil)
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "6.4.3")) == nil)
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "main-snapshot-2026-11-01")) == nil)
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "6.1.2")) != nil)
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "6.1-snapshot-2025-01-01")) != nil)
        ctx.installsTestToolchains = true
        #expect(windows.unsupportedToolchainReason(ctx, try ToolchainVersion(parsing: "5.8.0")) == nil)
    }

    @Test func acceptsZipArchivesOnlyFromTests() async throws {
        try await self.withScratchDirectory { dir in
            let archive = dir / "toolchain.exe"
            try Data([0x50, 0x4B, 0x03, 0x04]).write(to: archive)
            var ctx = SwiftlyTests.ctx
            ctx.installsTestToolchains = false
            await #expect(throws: SwiftlyError.self) {
                _ = try await WindowsToolchain.unpack(ctx, archive, staging: dir / "staging", verbose: false)
            }
        }
    }

    @Test func refusesCabinetsOf2GBOrMore() throws {
        #expect(throws: SwiftlyError.self) {
            try Cabinet.extract(from: FilePath(#"C:\nonexistent"#), offset: 0, length: Int(Int32.max), files: [:])
        }
    }

    @Test func checksTheSDKsLibrariesForTheArchitecture() {
        let root = FilePath(#"C:\Kits\10"#)
        let present: Set<String> = [
            #"C:\Kits\10\Include\10.0.26100.0\um\windows.h"#, #"C:\Kits\10\Include\10.0.26100.0\ucrt\stdio.h"#,
            #"C:\Kits\10\Lib\10.0.26100.0\um\x64\kernel32.lib"#, #"C:\Kits\10\Lib\10.0.26100.0\ucrt\x64\ucrt.lib"#,
        ]
        let exists: (FilePath) -> Bool = { present.contains($0.string) }
        #expect(VisualStudio.sdkIsComplete(root: root, version: "10.0.26100.0", arch: "x64", exists: exists))
        #expect(!VisualStudio.sdkIsComplete(root: root, version: "10.0.26100.0", arch: "arm64", exists: exists))
        #expect(VisualStudio.versionComponents("10.0.26100.0").lexicographicallyPrecedes(VisualStudio.versionComponents("10.0.100000.0")))
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

    @Test func rejectsPayloadNamesOutsideTheDirectory() throws {
        for name in [#"..\x.msi"#, #"C:\x.msi"#, #"\x.msi"#, "a/../../x", ""] {
            #expect(!BurnManifest.isSafeRelativePath(name), "\(name)")
        }
        #expect(BurnManifest.isSafeRelativePath("bld.asserts.msi"))
        #expect(BurnManifest.isSafeRelativePath(#"redist\vc.exe"#))
        let manifest = #"<BurnManifest><MsiPackage Id="a.msi"><PayloadRef Id="a" /></MsiPackage><Payload Id="a" FilePath="..\a.msi" SourcePath="a0" /></BurnManifest>"#
        #expect(throws: SwiftlyError.self) { try BurnManifest(xml: manifest) }
    }

    @Test func picksTheHashAlgorithmByLength() throws {
        #expect(try BurnBundle.hashAlgorithm(ofHexDigest: String(repeating: "a", count: 128)) == .sha512)
        #expect(try BurnBundle.hashAlgorithm(ofHexDigest: String(repeating: "a", count: 64)) == .sha256)
        #expect(throws: SwiftlyError.self) { try BurnBundle.hashAlgorithm(ofHexDigest: String(repeating: "a", count: 40)) }
    }

    @Test func selectsPackagesCaseInsensitively() throws {
        let selection = try WindowsToolchain.selectPackages(["BLD.msi", "Cli.MSI", "windows.msi", "RTL.msi"], arch: "amd64")
        #expect(selection.toolchain == ["bld.msi", "cli.msi", "windows.msi"])
        #expect(selection.runtime == "rtl.msi")
    }

    @Test func explainsWhatsMissingFromVisualStudio() throws {
        #expect(VisualStudio.instructions(for: .ready(installation: FilePath(#"C:\VS"#))) == nil)
        let none = try #require(VisualStudio.instructions(for: .notInstalled))
        #expect(none.contains("winget install --id Microsoft.VisualStudio.2022.Community"))
        #expect(none.contains("Microsoft.VisualStudio.2022.BuildTools"))
        let partial = try #require(VisualStudio.instructions(for: .missingComponents(installation: FilePath(#"C:\VS"#), cppTools: false, windowsSDK: true)))
        #expect(partial.contains("the C++ tools"))
        #expect(!partial.contains("a Windows SDK"))
        #expect(partial.contains("Desktop development with C++"))
        #expect(partial.contains(#"--installPath "C:\VS""#))
    }

    @Test func readsTheClangTheSTLRequires() {
        let header = """
        #ifdef __clang__
        #if __clang_major__ < 19
        _EMIT_STL_ERROR(STL1000, "Unexpected compiler version, expected Clang 19.0.0 or newer.");
        #endif
        """
        #expect(VisualStudio.requiredClangMajor(yvalsCore: header) == 19)
        #expect(VisualStudio.requiredClangMajor(yvalsCore: "") == nil)
    }

    @Test func putsRuntimeAfterToolchainOnPath() throws {
        let runtime = FilePath(#"C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin"#)
        #expect(Windows.insertingAfterFirst(runtime, into: #"C:\tc\usr\bin;C:\Windows;C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin\"#)
            == #"C:\tc\usr\bin;C:\h\toolchains\6.4.3\Runtimes\6.4.3\usr\bin;C:\Windows"#)
        #expect(Windows.insertingAfterFirst(runtime, into: "") == runtime.string)
    }
}
#endif
