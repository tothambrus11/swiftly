#if os(Windows)
import Foundation
@testable import Swiftly
@testable import SwiftlyCore
import SystemPackage
import Testing
@testable import WindowsPlatform

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
}
#endif
