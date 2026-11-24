import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// Makes swiftly available in new sessions through the user's environment in the registry
/// (HKCU\Environment), which is what new Windows terminals start with.
struct UserEnvironment: SessionEnvironment {
    var environment = RegistryEnvironment.user
    var ownership = PathOwnership.swiftly

    var noModifyProfileHelp: String {
        "Do not add swiftly's bin directory to the user's Path (in the registry) for new terminals."
    }

    func initIntroduction(_: SwiftlyCoreContext) -> String {
        """

        For your convenience, swiftly will also add its bin directory to your user Path, so that
        installed items are available in new terminals. This can be suppressed with the
        '--no-modify-profile' option.

        """
    }

    /// The SWIFTLY_*_DIR variables of this process that point to this installation.
    func swiftlyVariables() -> [(String, String)] {
        UserPath.swiftlyVariables.compactMap { name in
            ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : (name, $0) }
        }
    }

    /// Records the SWIFTLY_*_DIR variables this process has, whatever `modifyPath` says (as env.sh
    /// does on Linux and macOS), and adds the bin directory to the user's Path if `modifyPath`.
    func setUp(_ ctx: SwiftlyCoreContext, modifyPath: Bool) async throws {
        // Tests mustn't change this machine's environment.
        guard ctx.mockedHomeDir == nil else {
            return
        }
        let variables = self.swiftlyVariables()
        guard modifyPath else {
            // --no-modify-profile changes nothing that persists; say what would make swiftly
            // available in new terminals. This terminal has swiftly's settings already.
            let binDir = Windows().swiftlyBinDir(ctx)
            let commands = variables.map { "[Environment]::SetEnvironmentVariable('\($0.0)', '\($0.1)', 'User')" }
                + ["[Environment]::SetEnvironmentVariable('Path', '\(binDir);' + [Environment]::GetEnvironmentVariable('Path', 'User'), 'User')"]
            await ctx.message("""
            To make swiftly available in new terminals, run in PowerShell:
                \(commands.joined(separator: "\n    "))
            """)
            return
        }
        let recorded = try self.environment.record(variables)
        if !recorded.isEmpty {
            await ctx.message("Recorded \(recorded.joined(separator: ", ")) in your user environment for new terminals.")
        }
        var pathChanged = false
        do {
            let binDir = Windows().swiftlyBinDir(ctx)
            pathChanged = try self.environment.addToPath(binDir)
            if pathChanged {
                // Remember that swiftly added the entry, so that self-uninstall removes only that,
                // not an entry an installer added (such as a future swiftly MSI).
                try self.ownership.write(binDir)
                await ctx.message("Added \(binDir) to your Path for new terminals.")
            }
            if let swift = UserPath.swiftAhead(
                of: binDir,
                machine: try? RegistryEnvironment.machine.read("Path"),
                user: try? self.environment.read("Path"),
                exists: { FileManager.default.fileExists(atPath: $0.string) }
            ) {
                await ctx.message("""
                Warning: in new terminals, `swift` will run \(swift) rather than swiftly's proxy, because \
                its directory comes earlier in Path (the system Path comes before the user's). Remove that \
                directory from Path to use the toolchains swiftly installs.
                """)
            }
        }
        if pathChanged || !recorded.isEmpty {
            Win32.broadcastEnvironmentChange()
        }
    }

    func currentSessionInstructions(_ ctx: SwiftlyCoreContext) -> String? {
        let binDir = Windows().swiftlyBinDir(ctx)
        return """
        To begin using installed swiftly from your current terminal, open a new one, or run
            $env:Path = "\(binDir);" + $env:Path      (PowerShell)
            set "Path=\(binDir);%Path%"               (cmd)

        """
    }

    func tearDown(_ ctx: SwiftlyCoreContext, verbose: Bool) async throws {
        guard ctx.mockedHomeDir == nil else {
            return
        }
        let binDir = Windows().swiftlyBinDir(ctx)
        let pathChanged = try self.ownership.owns(binDir) && self.environment.removeFromPath(binDir)
        try self.ownership.clear()
        if pathChanged {
            await ctx.print("Removed \(binDir) from your Path.")
        }
        let forgotten = try self.environment.forget(self.swiftlyVariables())
        if verbose && !forgotten.isEmpty {
            await ctx.print("Removed \(forgotten.joined(separator: ", ")) from your user environment.")
        }
        if pathChanged || !forgotten.isEmpty {
            Win32.broadcastEnvironmentChange()
        }
        // What self-uninstall couldn't delete (swiftly.exe, which is running it) goes once swiftly
        // has exited, and the bin and home directories with it if they're empty then.
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: binDir.string)) ?? []).filter(Windows.isLeftover).map { binDir / $0 }
        if !leftovers.isEmpty {
            Windows.deleteWhenUnused(leftovers, thenDirectories: [binDir, Windows().swiftlyHomeDir(ctx)])
        }
    }
}

/// Which Path entry swiftly added (HKCU\Software\swiftly, `PathEntry`), outside the environment
/// so that it isn't an environment variable.
struct PathOwnership: @unchecked Sendable {
    var root: HKEY
    var subkey: String

    static var swiftly: Self { Self(root: HKEY_CURRENT_USER, subkey: #"Software\swiftly"#) }

    func write(_ entry: FilePath) throws {
        try Win32.createKey(self.root, self.subkey)
        _ = try Win32.withKey(self.root, self.subkey, writable: true) { try Win32.writeString($0, "PathEntry", .init(value: entry.string, expandable: false)) }
    }

    func owns(_ entry: FilePath) throws -> Bool {
        let stored = try Win32.withKey(self.root, self.subkey, writable: false) { try Win32.readString($0, "PathEntry") } ?? nil
        return stored.map { UserPath.normalized($0.value) == UserPath.normalized(entry.string) } ?? false
    }

    func clear() throws {
        _ = try Win32.withKey(self.root, self.subkey, writable: true) { try Win32.deleteValue($0, "PathEntry") }
    }
}
