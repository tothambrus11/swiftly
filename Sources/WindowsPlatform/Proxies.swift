import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// swiftly.exe in the bin directory, and the proxies that run it.
///
/// Proxies are hard links to swiftly.exe, so a proxy *is* swiftly.exe under the tool's name, and
/// swiftly tells which tool to run from the name it was started with. Symbolic links would need
/// Developer Mode or administrator rights; hard links need neither, only a volume that has them
/// (NTFS or ReFS). A copy of swiftly.exe per tool would work too, but cost its size for each of
/// the 50 or so tools of a toolchain, and every one would need updating with swiftly.
///
/// The swiftly.exe there and the proxies may be running, and a running executable can't be deleted
/// or replaced, only renamed (within its volume). Files are therefore renamed aside before they are
/// deleted or replaced, to `<name>.swiftly-<8 hex>.old`, and deleted once they're no longer in use.
extension Windows {
    public func createProxy(_: SwiftlyCoreContext, at proxy: FilePath, to swiftlyBin: FilePath) async throws {
        try Win32.createHardLink(at: proxy, to: swiftlyBin)
    }

    /// Files renamed aside (`*.swiftly-<stamp>.old`) are still hard links to swiftly.exe while they
    /// run, but they aren't proxies anymore.
    public func isProxy(_: SwiftlyCoreContext, _ file: FilePath, to swiftlyBin: FilePath) async throws -> Bool {
        !Self.isLeftover(file.lastComponent?.string ?? "") && Self.isLink(file, to: swiftlyBin)
    }

    /// Whether `file` is another name (hard link) of the file `target`, not `target` itself.
    static func isLink(_ file: FilePath, to target: FilePath) -> Bool {
        guard file.string.lowercased() != target.string.lowercased(), let identity = Win32.fileIdentity(of: file) else {
            return false
        }
        return identity == Win32.fileIdentity(of: target)
    }

    /// Only the executables of a toolchain get proxies; its bin directory also has DLLs and assemblies.
    public func proxyCandidates(_ files: [String]) -> [String] {
        files.filter { $0.lowercased().hasSuffix(".exe") }
    }

    /// Renames the file aside in its directory, then deletes it. A running file can't be deleted;
    /// it stays as a leftover that a later run deletes (`removeLeftovers`), or, after
    /// `self-uninstall`, the helper that `UserEnvironment.tearDown` starts.
    public func removeFromBinDir(_: SwiftlyCoreContext, _ file: FilePath) async throws -> FilePath? {
        let directory = file.removingLastComponent()
        Self.removeLeftovers(in: directory, kinds: ["old"])
        let aside = Self.leftoverName(for: file, stamp: Self.newStamp(), kind: "old")
        // Another program (a virus scanner, typically) may have the file open for a moment.
        for attempt in 1... {
            do {
                try Win32.move(file, to: aside)
                break
            } catch let error as Win32.Failure where Win32.inUse.contains(error.code) && attempt < 10 {
                try await Task.sleep(for: .milliseconds(200 * attempt))
            }
        }
        do {
            try Win32.deleteFile(aside)
            return nil
        } catch {
            return aside
        }
    }

    public func findSwiftlyBin(_ ctx: SwiftlyCoreContext) async throws -> FilePath? {
        let swiftlyHomeBin = self.swiftlyBinDir(ctx) / "swiftly.exe"
        return try await fs.exists(atPath: swiftlyHomeBin) ? swiftlyHomeBin : nil
    }

    /// Copies the running swiftly.exe into the bin directory, as on Linux and macOS, and points the
    /// proxies at the new copy (see `replaceSwiftly`).
    public func installSwiftlyBin(_ ctx: SwiftlyCoreContext) async throws {
        guard ctx.mockedHomeDir == nil, let current = Self.currentExecutable else {
            return
        }
        let binDir = self.swiftlyBinDir(ctx)
        let swiftlyHomeBin = binDir / "swiftly.exe"

        // Already installed: this is the swiftly.exe in the bin directory, one of its proxies, or
        // something else running from the bin directory (compared by file id, not by spelling).
        try await Self.installSwiftly(current, binDir: binDir, homeDir: self.swiftlyHomeDir(ctx)) {
            await ctx.message("Installing swiftly in \(swiftlyHomeBin)...")
        }
    }

    /// `installSwiftlyBin` for the executable `current`: returns false without changing anything if
    /// it's in `binDir` already, else replaces swiftly there under the lock that toolchain
    /// installation takes (`<homeDir>\swiftly.lock`, waiting up to `lockTimeout` seconds).
    @discardableResult
    static func installSwiftly(
        _ current: FilePath, binDir: FilePath, homeDir: FilePath, lockTimeout: TimeInterval = FileLock.defaultTimeout,
        installing: () async -> Void = {}
    ) async throws -> Bool {
        let swiftlyHomeBin = binDir / "swiftly.exe"
        // Already installed: this is the swiftly.exe in the bin directory, one of its proxies, or
        // something else running from the bin directory (compared by file id, not by spelling).
        if let identity = Win32.fileIdentity(of: current),
           identity == Win32.fileIdentity(of: swiftlyHomeBin)
           || Win32.fileIdentity(of: current.removingLastComponent()) == Win32.fileIdentity(of: binDir)
        {
            // Outside the lock, only old files: a `.new` may be another swiftly's, in the middle of
            // an upgrade.
            Self.removeLeftovers(in: binDir, kinds: ["old"])
            return false
        }

        await installing()
        try await fs.mkdir(.parents, atPath: binDir)
        try await fs.mkdir(.parents, atPath: homeDir)
        // The same lock as installing toolchains, which creates proxies.
        try await withLock(homeDir / "swiftly.lock", timeout: lockTimeout) {
            try Self.replaceSwiftly(in: binDir, with: current)
        }
        return true
    }

    /// Makes `binDir\swiftly.exe` a copy of `newSwiftly`, and its proxies hard links to that copy.
    ///
    /// The old swiftly.exe is renamed aside and the new one copied in. Each proxy is then linked to
    /// the new copy under a temporary name, the old proxy renamed aside and the new one renamed into
    /// its place, so the proxy's name is missing only between those two renames. If any step
    /// fails, the steps done so far are undone. Old files still in use are deleted by a later run.
    ///
    /// Proxies are the hard links to the old swiftly.exe, and also to an older one renamed aside
    /// by an upgrade that didn't finish, so that no proxy keeps running an old swiftly.
    ///
    /// `stamp` names the files renamed aside; `afterEachProxy` lets tests fail in the middle.
    static func replaceSwiftly(
        in binDir: FilePath, with newSwiftly: FilePath, stamp: String = newStamp(), afterEachProxy: (String) throws -> Void = { _ in }
    ) throws {
        let swiftlyHomeBin = binDir / "swiftly.exe"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: binDir.string)) ?? []
        let swiftlies = [swiftlyHomeBin] + files.filter { Self.isLeftover($0) && $0.lowercased().hasPrefix("swiftly.exe.") }.map { binDir / $0 }
        let proxies = files.filter { file in
            !isSwiftlyExecutable(file) && !Self.isLeftover(file)
                && swiftlies.contains { Self.isLink(binDir / file, to: $0) }
        }

        var undo: [() -> Void] = []
        do {
            if FileManager.default.fileExists(atPath: swiftlyHomeBin.string) {
                let old = Self.leftoverName(for: swiftlyHomeBin, stamp: stamp, kind: "old")
                try Win32.move(swiftlyHomeBin, to: old)
                undo.append { try? Win32.move(old, to: swiftlyHomeBin) }
            }
            try FileManager.default.copyItem(atPath: newSwiftly.string, toPath: swiftlyHomeBin.string)
            undo.append { try? Win32.deleteFile(swiftlyHomeBin) }
            for proxy in proxies.map({ binDir / $0 }) {
                let new = Self.leftoverName(for: proxy, stamp: stamp, kind: "new")
                let old = Self.leftoverName(for: proxy, stamp: stamp, kind: "old")
                try Win32.createHardLink(at: new, to: swiftlyHomeBin)
                undo.append { try? Win32.deleteFile(new) }
                try Win32.move(proxy, to: old)
                undo.append { try? Win32.move(old, to: proxy) }
                try Win32.move(new, to: proxy)
                undo.append { try? Win32.move(proxy, to: new) }
                try afterEachProxy(proxy.lastComponent!.string)
            }
        } catch {
            for step in undo.reversed() {
                step()
            }
            throw error
        }
        Self.removeLeftovers(in: binDir)
    }

    /// A fresh stamp for the names of files renamed aside.
    static func newStamp() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// `<name>.swiftly-<stamp>.<kind>`, in the directory of `file`.
    static func leftoverName(for file: FilePath, stamp: String, kind: String) -> FilePath {
        file.removingLastComponent() / "\(file.lastComponent?.string ?? "").swiftly-\(stamp).\(kind)"
    }

    /// Whether `file` is a name that swiftly gives files it renamed aside: `<name>.swiftly-<8 hex>.old|.new`.
    static func isLeftover(_ file: String) -> Bool {
        file.lowercased().wholeMatch(of: #/.+\.swiftly-[0-9a-f]{8}\.(old|new)/#) != nil
    }

    /// Deletes the files that swiftly renamed aside, unless they're still running.
    static func removeLeftovers(in binDir: FilePath, kinds: Set<String> = ["old", "new"]) {
        for file in (try? FileManager.default.contentsOfDirectory(atPath: binDir.string)) ?? []
            where Self.isLeftover(file) && kinds.contains(String(file.lowercased().split(separator: ".").last ?? ""))
        {
            try? Win32.deleteFile(binDir / file)
        }
    }

    /// Starts a helper that waits for this process to exit, then deletes `files` once they're no
    /// longer in use (retrying for a few minutes), and then each of `directories` that's empty, in
    /// order. It's for what no later run of swiftly would delete: swiftly.exe after
    /// `swiftly self-uninstall`, and the bin and home directories. The helper is PowerShell, which
    /// every Windows has, given its script with -Command (not -EncodedCommand, which endpoint
    /// protection tends to flag).
    static func deleteWhenUnused(_ files: [FilePath], thenDirectories directories: [FilePath]) {
        let script = self.deletionScript(files, directories: directories, waitingFor: GetCurrentProcessId())
        let powershell = Win32.system32 / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        let commandLine = "\"\(powershell)\" -NoProfile -NonInteractive -Command \"\(script)\""
        // Detached, so that closing the terminal doesn't end it; out of the job if allowed, so that
        // ending a job (as CI runners do) doesn't either.
        let flags = DWORD(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
        if !Win32.startProcess(commandLine, flags: flags | DWORD(CREATE_BREAKAWAY_FROM_JOB)), !Win32.startProcess(commandLine, flags: flags) {
            // Without the helper, delete them at the next restart, which works when swiftly runs as an administrator.
            for file in files {
                _ = file.string.withCString(encodedAs: UTF16.self) { MoveFileExW($0, nil, DWORD(MOVEFILE_DELAY_UNTIL_REBOOT)) }
            }
        }
    }

    /// The helper's script: one line, with single-quoted paths only, so that it passes as one
    /// double-quoted argument (Windows paths can't contain double quotes).
    static func deletionScript(_ files: [FilePath], directories: [FilePath], waitingFor process: DWORD) -> String {
        func quoted(_ path: FilePath) -> String {
            "'" + path.string.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return [
            "$files = @(\(files.map(quoted).joined(separator: ",")))",
            "Wait-Process -Id \(process) -ErrorAction SilentlyContinue",
            "foreach ($attempt in 1..60) { foreach ($file in $files) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }; if (-not ($files | Where-Object { Test-Path -LiteralPath $_ })) { break }; Start-Sleep -Seconds 5 }",
            "foreach ($dir in @(\(directories.map(quoted).joined(separator: ",")))) { if (-not (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $dir -ErrorAction SilentlyContinue } }",
        ].joined(separator: "; ")
    }

    /// The path of the running executable.
    static var currentExecutable: FilePath? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let length = GetModuleFileNameW(nil, &buffer, DWORD(buffer.count))
        guard length > 0, Int(length) < buffer.count else {
            return nil
        }
        return FilePath(String(decoding: buffer[..<Int(length)], as: UTF16.self))
    }
}
