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
        try FileManager.default.removeItem(atPath: atPath)
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

        _ = FileManager.default.createFile(atPath: file.string, contents: contents, attributes: attributes)
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

    /// Creates the proxy `atPath`, an executable that runs swiftly (`target`) under another name.
    ///
    /// Proxies are symbolic links, except on Windows, where creating a symbolic link needs Developer
    /// Mode or administrator rights. There they are hard links, which work for any user because
    /// the proxies live next to swiftly.exe, on the same volume.
    public static func createProxy(atPath: FilePath, to target: FilePath) async throws {
#if os(Windows)
        let created = atPath.string.withCString(encodedAs: UTF16.self) { link in
            target.string.withCString(encodedAs: UTF16.self) { CreateHardLinkW(link, $0, nil) }
        }
        guard created else {
            throw SwiftlyError(message: "Couldn't create \(atPath) as a hard link to \(target) (Windows error \(GetLastError())).")
        }
#else
        try await self.symlink(atPath: atPath, linkPath: target)
#endif
    }

    /// Whether `atPath` is a proxy for `target` that `createProxy` created.
    public static func isProxy(atPath: FilePath, to target: FilePath) async throws -> Bool {
#if os(Windows)
        guard let file = Self.fileIdentity(atPath), let swiftly = Self.fileIdentity(target) else {
            return false
        }
        return file == swiftly
#else
        try await self.readlink(atPath: atPath) == target
#endif
    }

#if os(Windows)
    /// The volume serial number and file index, which all hard links to a file share.
    private static func fileIdentity(_ path: FilePath) -> [UInt64]? {
        let handle = path.string.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            return nil
        }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else {
            return nil
        }
        return [UInt64(info.dwVolumeSerialNumber), UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)]
    }
#endif

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

extension Data {
    public func write(to path: FilePath, options: Data.WritingOptions = []) throws {
        try self.write(to: URL(fileURLWithPath: path.string), options: options)
    }

    public init(contentsOf path: FilePath) throws {
        try self.init(contentsOf: URL(fileURLWithPath: path.string))
    }
}

extension String {
    public func write(to path: FilePath, atomically: Bool, encoding enc: String.Encoding = .utf8) throws {
        try self.write(to: URL(fileURLWithPath: path.string), atomically: atomically, encoding: enc)
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
