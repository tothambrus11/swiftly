import ArgumentParser
import Foundation
import SwiftlyCore
import SystemPackage

struct Unlink: SwiftlyCommand {
    public static let configuration = CommandConfiguration(
        abstract: "Unlinks swiftly so it no longer manages the active toolchain."
    )

    @Argument(help: ArgumentHelp(
        "Unlinks swiftly, allowing the system default toolchain to be used.",
        discussion: """

        Unlinks swiftly until swiftly is linked again with:

            $ swiftly link
        """
    ))
    var toolchainSelector: String?

    @OptionGroup var root: GlobalOptions

    mutating func run() async throws {
        try await self.run(Swiftly.createDefaultContext())
    }

    mutating func run(_ ctx: SwiftlyCoreContext) async throws {
        let versionUpdateReminder = try await validateSwiftly(ctx)
        defer {
            versionUpdateReminder()
        }

        var pathChanged = false
        for proxy in try await Self.existingProxies(ctx) {
            if try await fs.exists(atPath: proxy) {
                _ = try await Swiftly.currentPlatform.removeFromBinDir(ctx, proxy)
                pathChanged = true
            }
        }

        if pathChanged {
            await ctx.message(Messages.unlinkSuccess)
            await ctx.message(Messages.refreshShell)
        }
    }

    /// The proxies in swiftly's bin directory, not counting swiftly itself.
    static func existingProxies(_ ctx: SwiftlyCoreContext) async throws -> [FilePath] {
        guard let proxyTo = try? await Swiftly.currentPlatform.findSwiftlyBin(ctx) else {
            return []
        }
        let swiftlyBinDir = Swiftly.currentPlatform.swiftlyBinDir(ctx)
        let swiftlyBinDirContents = (try? await fs.ls(atPath: swiftlyBinDir)) ?? [String]()
        var proxies = [FilePath]()
        // A way to test swiftly locally is to symlink the swiftly executable in the bin dir to one
        // being built from a local swiftly repository; that's swiftly, not a proxy.
        for file in swiftlyBinDirContents where !isSwiftlyExecutable(file) {
            if (try? await Swiftly.currentPlatform.isProxy(ctx, swiftlyBinDir / file, to: proxyTo)) == true {
                proxies.append(swiftlyBinDir / file)
            }
        }
        return proxies
    }
}

extension SwiftlyCommand {
    /// Checks if swiftly is currently linked to manage the active toolchain.
    /// - Parameter ctx: The Swiftly context.
    func validateLinked(_ ctx: SwiftlyCoreContext) async throws {
        if try await Unlink.existingProxies(ctx).isEmpty {
            await ctx.printError(Messages.currentlyUnlinked)
        }
    }
}
