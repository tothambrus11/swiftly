import Foundation
import SystemPackage
#if os(Windows)
import WinSDK
#endif

typealias fs = FileSystem

public enum FileSystem {
    public static var cwd: FilePath {
        FileManager.default.currentDir
    }

    public static var home: FilePath {
        FileManager.default.homeDir
    }

    public static var tmp: FilePath {
        FileManager.default.temporaryDir
    }

    public static func exists(atPath: FilePath) async throws -> Bool {
        FileManager.default.fileExists(atPath: atPath)
    }

    public static func remove(atPath: FilePath) async throws {
        try retryingSharingViolations {
            try FileManager.default.removeItem(atPath: atPath)
        }
    }

    public static func move(atPath: FilePath, toPath: FilePath) async throws {
        try FileManager.default.moveItem(atPath: atPath, toPath: toPath)
    }

    public static func copy(atPath: FilePath, toPath: FilePath) async throws {
        try FileManager.default.copyItem(atPath: atPath, toPath: toPath)
    }

    public enum MkdirOptions {
        case parents
    }

    public static func mkdir(_ options: MkdirOptions..., atPath: FilePath) async throws {
        try await Self.mkdir(options, atPath: atPath)
    }

    public static func mkdir(_ options: [MkdirOptions] = [], atPath: FilePath) async throws {
        try FileManager.default.createDir(atPath: atPath, withIntermediateDirectories: options.contains(.parents))
    }

    public static func cat(atPath: FilePath) async throws -> Data {
        guard let data = FileManager.default.contents(atPath: atPath) else {
            throw SwiftlyError(message: "File at path \(atPath) could not be read")
        }

        return data
    }

    public static func mktemp(ext: String? = nil) -> FilePath {
        FileManager.default.temporaryDir.appending("swiftly-\(UUID())\(ext ?? "")")
    }

    public enum CreateOptions {
        case mode(Int)
    }

    public static func create(_ options: CreateOptions..., file: FilePath, contents: Data? = nil) async throws {
        try await Self.create(options, file: file, contents: contents)
    }

    public static func create(_ options: [CreateOptions] = [], file: FilePath, contents: Data?) async throws {
        let attributes = options.reduce(into: [FileAttributeKey: Any]()) {
            switch $1 {
            case let .mode(m):
                $0[FileAttributeKey.posixPermissions] = m
            }
        }

#if os(Windows)
        // createFile replaces the file atomically, which another program can briefly prevent.
        try retryingSharingViolations {
            guard FileManager.default.createFile(atPath: file.string, contents: contents, attributes: attributes) else {
                let code = Int(GetLastError())
                throw CocoaError(.fileWriteNoPermission, userInfo: [
                    NSFilePathErrorKey: file.string,
                    NSUnderlyingErrorKey: NSError(domain: win32ErrorDomain, code: code),
                ])
            }
        }
#else
        _ = FileManager.default.createFile(atPath: file.string, contents: contents, attributes: attributes)
#endif
    }

    public static func ls(atPath: FilePath) async throws -> [String] {
        try FileManager.default.contentsOfDir(atPath: atPath)
    }

    public static func readlink(atPath: FilePath) async throws -> FilePath {
        try FileManager.default.destinationOfSymbolicLink(atPath: atPath)
    }

    public static func isSymLink(atPath: FilePath) async throws -> Bool {
        try FileManager.default.attributesOfItem(atPath: atPath.string)[.type] as? FileAttributeType == .typeSymbolicLink
    }

    public static func symlink(atPath: FilePath, linkPath: FilePath) async throws {
        try FileManager.default.createSymbolicLink(atPath: atPath, withDestinationPath: linkPath)
    }

    public static func chmod(atPath: FilePath, mode: Int) async throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: atPath.string)
    }

    public static func withTemporary<T>(files: FilePath..., f: () async throws -> T) async throws -> T {
        try await self.withTemporary(files: files, f: f)
    }

    public static func withTemporary<T>(files: [FilePath], f: () async throws -> T) async throws -> T {
        do {
            let t: T = try await f()

            for f in files {
                try? await Self.remove(atPath: f)
            }

            return t
        } catch {
            // Sort the list in case there are temporary files nested within other temporary files
            for f in files.map(\.string).sorted() {
                try? await Self.remove(atPath: FilePath(f))
            }

            throw error
        }
    }
}

extension FileManager {
    public var currentDir: FilePath {
        FilePath(Self.default.currentDirectoryPath)
    }

    public var homeDir: FilePath {
        FilePath(Self.default.homeDirectoryForCurrentUser.path)
    }

    public func fileExists(atPath path: FilePath) -> Bool {
        Self.default.fileExists(atPath: path.string, isDirectory: nil)
    }

    public func removeItem(atPath path: FilePath) throws {
        try Self.default.removeItem(atPath: path.string)
    }

    public func moveItem(atPath: FilePath, toPath: FilePath) throws {
        try Self.default.moveItem(atPath: atPath.string, toPath: toPath.string)
    }

    public func copyItem(atPath: FilePath, toPath: FilePath) throws {
        try Self.default.copyItem(atPath: atPath.string, toPath: toPath.string)
    }

    public func deleteIfExists(atPath path: FilePath) throws {
        do {
            try Self.default.removeItem(atPath: path.string)
        } catch let error as NSError {
            guard error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileNoSuchFile.rawValue else {
                throw error
            }
        }
    }

    public func createDir(atPath: FilePath, withIntermediateDirectories: Bool) throws {
        try Self.default.createDirectory(atPath: atPath.string, withIntermediateDirectories: withIntermediateDirectories)
    }

    public func contents(atPath: FilePath) -> Data? {
        Self.default.contents(atPath: atPath.string)
    }

    public var temporaryDir: FilePath {
        FilePath(Self.default.temporaryDirectory.path)
    }

    public func contentsOfDir(atPath: FilePath) throws -> [String] {
        try Self.default.contentsOfDirectory(atPath: atPath.string)
    }

    public func destinationOfSymbolicLink(atPath: FilePath) throws -> FilePath {
        FilePath(try Self.default.destinationOfSymbolicLink(atPath: atPath.string))
    }

    public func createSymbolicLink(atPath: FilePath, withDestinationPath: FilePath) throws {
        try Self.default.createSymbolicLink(atPath: atPath.string, withDestinationPath: withDestinationPath.string)
    }
}

/// Runs `write`, retrying for a while on Windows when a file can't be created, replaced or removed
/// because another program has it open: a virus scanner looks at files just after they're written,
/// which makes replacing (atomic writes) or deleting them fail with a sharing violation for a moment.
///
/// `atomicWriteTo`: the file an atomic write replaces. Foundation leaves its temporary file
/// (`.dat.nosync*`, next to the destination) behind when the final rename fails, so those are
/// removed once a write had to be retried.
func retryingSharingViolations(atomicWriteTo destination: FilePath? = nil, _ write: () throws -> Void) throws {
#if os(Windows)
    // Foundation leaves its temporary file behind when an atomic write fails: clean up after a
    // retried or failed write.
    var retried = false
    var succeeded = false
    // Foundation's temporary files there already (another process's, perhaps) aren't touched.
    let directory = destination?.removingLastComponent()
    let before = Set(directory.flatMap { try? FileManager.default.contentsOfDirectory(atPath: $0.string) } ?? [])
    defer {
        if retried || !succeeded, let directory {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: directory.string)) ?? []
                where file.hasPrefix(".dat.nosync") && !before.contains(file)
            {
                // The other program may still have it open for a moment, too.
                for attempt in 1...10 {
                    do {
                        try FileManager.default.removeItem(atPath: (directory / file).string)
                        break
                    } catch {
                        Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
                    }
                }
            }
        }
    }
    for attempt in 1... {
        do {
            try write()
            succeeded = true
            return
        } catch where isInUse(error) && attempt < 10 {
            // These helpers are synchronous, so the waits stay short: about 2.5 s in all.
            retried = true
            Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
        }
    }
#else
    try write()
#endif
}

#if os(Windows)
/// The Win32 errors of a file that another program has open: sharing and lock violations, and a
/// pending delete.
private let inUseErrors: Set<Int> = [32, 33, 303] // ERROR_SHARING_VIOLATION, ERROR_LOCK_VIOLATION, ERROR_DELETE_PENDING

/// The domain of the Win32 error that `fs.create` records, which Foundation doesn't for createFile.
let win32ErrorDomain = "Win32"

/// Whether `error` comes from a Win32 error that means another program has the file open.
/// Foundation reports those as CocoaErrors with the Win32 error underneath (its `Win32Error`, or an
/// NSError in `win32ErrorDomain` from `fs.create`). Without a Win32 error under it, an error isn't
/// taken for one.
func isInUse(_ error: Error) -> Bool {
    let cocoa = error as NSError
    guard let underlying = cocoa.userInfo[NSUnderlyingErrorKey] else {
        return false
    }
    if let code = win32Code(underlying) {
        return inUseErrors.contains(code)
    }
    guard let next = underlying as? Error else {
        return false
    }
    return isInUse(next)
}

/// The Win32 error code of Foundation's `Win32Error` (read by reflection; the type isn't public)
/// or of an NSError in `win32ErrorDomain`.
func win32Code(_ error: Any) -> Int? {
    if let error = error as? NSError, error.domain == win32ErrorDomain {
        return error.code
    }
    guard String(describing: type(of: error)).hasSuffix("Win32Error") else {
        return nil
    }
    for child in Mirror(reflecting: error).children where child.label == "code" {
        if let code = child.value as? any BinaryInteger {
            return Int(code)
        }
    }
    return nil
}
#endif

extension Data {
    public func write(to path: FilePath, options: Data.WritingOptions = []) throws {
        try retryingSharingViolations(atomicWriteTo: options.contains(.atomic) ? path : nil) {
            try self.write(to: URL(fileURLWithPath: path.string), options: options)
        }
    }

    public init(contentsOf path: FilePath) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path.string))
    }
}

extension String {
    public func write(to path: FilePath, atomically: Bool, encoding enc: String.Encoding = .utf8) throws {
        try retryingSharingViolations(atomicWriteTo: atomically ? path : nil) {
            try self.write(to: URL(fileURLWithPath: path.string), atomically: atomically, encoding: enc)
        }
    }

    public init(contentsOf path: FilePath, encoding enc: String.Encoding = .utf8) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path.string), encoding: enc)
    }
}

extension FilePath {
    public static func / (left: FilePath, right: String) -> FilePath {
        left.appending(right)
    }

    public var parent: FilePath { self.removingLastComponent() }
}
