import Foundation
import OpenAPIRuntime
import Subprocess
@testable import Swiftly
@testable import SwiftlyCore
import SwiftlyWebsiteAPI
import SystemPackage
import Testing
#if canImport(Darwin)
import Darwin
#endif

@Suite struct PlatformTests {
    @Test func toolchainDownloadPlatform() {
#if os(Windows)
        let (directory, file) = Swiftly.currentPlatform.toolchainDownloadPlatform(.windows10)
#if arch(arm64)
        #expect(directory == "windows10-arm64")
        #expect(file == "windows10-arm64")
#else
        #expect(directory == "windows10")
        #expect(file == "windows10")
#endif
#else
        let (directory, file) = Swiftly.currentPlatform.toolchainDownloadPlatform(.ubuntu2404)
#if os(Linux) && arch(arm64)
        #expect(directory == "ubuntu2404-aarch64")
        #expect(file == "ubuntu24.04-aarch64")
#else
        #expect(directory == "ubuntu2404")
        #expect(file == "ubuntu24.04")
#endif
#endif
    }

    /// swift.org lists Windows snapshots for ARM64 under "arm64", other platforms' under "aarch64".
    @Test func arm64SnapshotsOfWindows() async throws {
        struct Executor: HTTPRequestExecutor {
            func getCurrentSwiftlyRelease() async throws -> SwiftlyWebsiteAPI.Components.Schemas.SwiftlyRelease { fatalError(unmockedMsg) }
            func getReleaseToolchains() async throws -> [Components.Schemas.Release] { fatalError(unmockedMsg) }
            func getSnapshotToolchains(branch _: SwiftlyWebsiteAPI.Components.Schemas.SourceBranch, platform _: SwiftlyWebsiteAPI.Components.Schemas.PlatformIdentifier) async throws -> SwiftlyWebsiteAPI.Components.Schemas.DevToolchains {
                SwiftlyWebsiteAPI.Components.Schemas.DevToolchains(arm64: [
                    SwiftlyWebsiteAPI.Components.Schemas.DevToolchainForArch(
                        name: nil, date: "", dir: "swift-DEVELOPMENT-SNAPSHOT-2026-11-01-a", download: "", downloadSignature: nil, debugInfo: nil
                    ),
                ])
            }

            func getGpgKeys() async throws -> OpenAPIRuntime.HTTPBody { fatalError(unmockedMsg) }
            func getSwiftlyRelease(url _: URL) async throws -> OpenAPIRuntime.HTTPBody { fatalError(unmockedMsg) }
            func getSwiftlyReleaseSignature(url _: URL) async throws -> OpenAPIRuntime.HTTPBody { fatalError(unmockedMsg) }
            func getSwiftToolchainFile(_: ToolchainFile) async throws -> OpenAPIRuntime.HTTPBody { fatalError(unmockedMsg) }
            func getSwiftToolchainFileSignature(_: ToolchainFile) async throws -> OpenAPIRuntime.HTTPBody { fatalError(unmockedMsg) }
        }
        let client = SwiftlyHTTPClient(httpRequestExecutor: Executor())
#if os(Windows)
        let snapshots = try await client.getSnapshotToolchains(platform: .windows10, arch: "aarch64", branch: .main)
        #expect(snapshots.map(\.date) == ["2026-11-01"])
#else
        // Elsewhere, "arm64" isn't aarch64: no snapshots (an empty list, or an error saying so).
        let snapshots = (try? await client.getSnapshotToolchains(platform: .windows10, arch: "aarch64", branch: .main)) ?? []
        #expect(snapshots.isEmpty)
#endif
    }

#if os(Linux) || os(macOS)
    @Test func proxiesAreSymbolicLinks() async throws {
        let dir = fs.mktemp()
        try await fs.mkdir(.parents, atPath: dir)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let swiftly = dir / "swiftly"
        try Data("swiftly".utf8).write(to: swiftly)

        try await Swiftly.currentPlatform.createProxy(SwiftlyTests.ctx, at: dir / "swift", to: swiftly)

        #expect(try await fs.isSymLink(atPath: dir / "swift"))
        #expect(try await Swiftly.currentPlatform.isProxy(SwiftlyTests.ctx, dir / "swift", to: swiftly))
        #expect(try await !Swiftly.currentPlatform.isProxy(SwiftlyTests.ctx, swiftly, to: swiftly))
        #expect(Swiftly.currentPlatform.proxyCandidates(["swift", "libFoo.so"]) == ["swift", "libFoo.so"])
    }

    /// Homebrew's proxies link to `$(brew --prefix)/bin/swiftly`, which links into the Cellar (#454):
    /// a proxy through a chain of links, relative ones too, is still swiftly's.
    @Test func proxiesThroughAChainOfLinks() async throws {
        let dir = fs.mktemp()
        try await fs.mkdir(.parents, atPath: dir / "Cellar")
        try await fs.mkdir(.parents, atPath: dir / "bin")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let swiftly = dir / "Cellar" / "swiftly"
        try Data("swiftly".utf8).write(to: swiftly)
        try FileManager.default.createSymbolicLink(atPath: (dir / "bin" / "swiftly").string, withDestinationPath: "../Cellar/swiftly")
        try await fs.symlink(atPath: dir / "swift", linkPath: dir / "bin" / "swiftly")

        #expect(try await Swiftly.currentPlatform.isProxy(SwiftlyTests.ctx, dir / "swift", to: swiftly))
        #expect(try await Swiftly.currentPlatform.isProxy(SwiftlyTests.ctx, dir / "swift", to: dir / "bin" / "swiftly"))
        #expect(try await !Swiftly.currentPlatform.isProxy(SwiftlyTests.ctx, dir / "swift", to: dir / "other"))
    }
#endif

    func mockToolchainDownload(version: String) async throws -> (FilePath, ToolchainVersion, FilePath) {
        let mockDownloader = MockToolchainDownloader(executables: ["swift"])
        let version = try! ToolchainVersion(parsing: version)
        let ext = Swiftly.currentPlatform.toolchainFileExtension
        let tmpDir = fs.mktemp()
        try! await fs.mkdir(.parents, atPath: tmpDir)
        let mockedToolchainFile = tmpDir / "swift-\(version).\(ext)"
        let mockedToolchain = try await mockDownloader.makeMockedToolchain(toolchain: version, name: tmpDir.lastComponent!.string)
        try mockedToolchain.write(to: mockedToolchainFile)

        return (mockedToolchainFile, version, tmpDir)
    }

    @Test(.testHome(), .mockedSwiftlyVersion()) func install() async throws {
        // GIVEN: a toolchain has been downloaded
        var (mockedToolchainFile, version, tmpDir) = try await self.mockToolchainDownload(version: "5.7.1")
        var cleanup = [tmpDir]
        defer {
            for dir in cleanup {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }

        // WHEN: the platform installs the toolchain
        try await Swiftly.currentPlatform.install(SwiftlyTests.ctx, from: mockedToolchainFile, version: version, verbose: true)
        // THEN: the toolchain is extracted in the toolchains directory
        var toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(1 == toolchains.count)

        // GIVEN: a second toolchain has been downloaded
        (mockedToolchainFile, version, tmpDir) = try await self.mockToolchainDownload(version: "5.8.0")
        cleanup += [tmpDir]
        // WHEN: the platform installs the toolchain
        try await Swiftly.currentPlatform.install(SwiftlyTests.ctx, from: mockedToolchainFile, version: version, verbose: true)
        // THEN: the toolchain is added to the toolchains directory
        toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(2 == toolchains.count)

        // GIVEN: an identical toolchain has been downloaded
        (mockedToolchainFile, version, tmpDir) = try await self.mockToolchainDownload(version: "5.8.0")
        cleanup += [tmpDir]
        // WHEN: the platform installs the toolchain
        try await Swiftly.currentPlatform.install(SwiftlyTests.ctx, from: mockedToolchainFile, version: version, verbose: true)
        // THEN: the toolchains directory remains the same
        toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(2 == toolchains.count)
    }

    @Test(.testHome(), .mockedSwiftlyVersion()) func uninstall() async throws {
        // GIVEN: toolchains have been downloaded, and installed
        var (mockedToolchainFile, version, tmpDir) = try await self.mockToolchainDownload(version: "5.8.0")
        var cleanup = [tmpDir]
        defer {
            for dir in cleanup {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }
        try await Swiftly.currentPlatform.install(SwiftlyTests.ctx, from: mockedToolchainFile, version: version, verbose: true)
        (mockedToolchainFile, version, tmpDir) = try await self.mockToolchainDownload(version: "5.6.3")
        cleanup += [tmpDir]
        try await Swiftly.currentPlatform.install(SwiftlyTests.ctx, from: mockedToolchainFile, version: version, verbose: true)
        // WHEN: one of the toolchains is uninstalled
        try await Swiftly.currentPlatform.uninstall(SwiftlyTests.ctx, version, verbose: true)
        // THEN: there is only one remaining toolchain installed
        var toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(1 == toolchains.count)

        // GIVEN; there is only one toolchain installed
        // WHEN: a non-existent toolchain is uninstalled
        try? await Swiftly.currentPlatform.uninstall(SwiftlyTests.ctx, ToolchainVersion(parsing: "5.9.1"), verbose: true)
        // THEN: there is the one remaining toolchain that is still installed
        toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(1 == toolchains.count)

        // GIVEN: there is only one toolchain installed
        // WHEN: the last toolchain is uninstalled
        try await Swiftly.currentPlatform.uninstall(SwiftlyTests.ctx, ToolchainVersion(parsing: "5.8.0"), verbose: true)
        // THEN: there are no toolchains installed
        toolchains = try await fs.ls(atPath: Swiftly.currentPlatform.swiftlyToolchainsDir(SwiftlyTests.ctx))
        #expect(0 == toolchains.count)
    }

#if os(macOS)
    @Test(.mockedSwiftlyVersion(), .testHome()) func findXcodeToolchainLocation() async throws {
        // GIVEN: the xcode toolchain
        // AND there is xcode installed
        guard let swiftLocation = try? await run(.name("xcrun"), arguments: ["-f", "swift"], output: .string(limit: 1024 * 10)).standardOutput, swiftLocation != "" else {
            return
        }

        // WHEN: the location of the xcode toolchain can be found
        let toolchainLocation = try await Swiftly.currentPlatform.findToolchainLocation(SwiftlyTests.ctx, .xcodeVersion)

        // THEN: the xcode toolchain matches the currently selected xcode toolchain
        #expect(toolchainLocation.string == swiftLocation.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "/usr/bin/swift", with: ""))
    }
#endif

#if os(macOS) || os(Linux)
    @Test(
        .mockedSwiftlyVersion(),
        .mockHomeToolchains(),
        arguments: [
            "/a/b/c:SWIFTLY_BIN_DIR:/d/e/f",
            "SWIFTLY_BIN_DIR:/abcde",
            "/defgh:SWIFTLY_BIN_DIR",
            "/xyzabc:/1/3/4",
            "",
        ]
    ) func proxyEnv(_ path: String) async throws {
#if os(macOS)
        // Prevent platform environment variable from affecting the tests
        unsetenv("TOOLCHAINS")
        unsetenv("DEVELOPER_DIR")
#endif

        // GIVEN: a PATH that may contain the swiftly bin directory
        let env: Environment = .custom(["PATH": path.replacing("SWIFTLY_BIN_DIR", with: Swiftly.currentPlatform.swiftlyBinDir(SwiftlyTests.ctx).string)])

        // WHEN: proxying to an installed toolchain
        let newEnv = try await Swiftly.currentPlatform.proxyEnvironment(SwiftlyTests.ctx, env: env, toolchain: .newStable)

        // THEN: the toolchain's bin directory is added to the beginning of the PATH
        // #expect(newEnv.description == "")
        #expect(newEnv.description.contains("PATH: \"\((try await Swiftly.currentPlatform.findToolchainLocation(SwiftlyTests.ctx, .newStable)) / "usr/bin"):"))

        // AND: the swiftly bin directory is removed from the PATH
        #expect(!newEnv.description.contains(Swiftly.currentPlatform.swiftlyBinDir(SwiftlyTests.ctx).string))
        #expect(!newEnv.description.contains(Swiftly.currentPlatform.swiftlyBinDir(SwiftlyTests.ctx).string))
    }
#endif
}
