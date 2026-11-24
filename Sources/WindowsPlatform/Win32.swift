import CWinSDKExtras
import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage
import WinSDK

/// Small wrappers around the Win32 calls the Windows platform needs.
enum Win32 {
    /// The error of a failed Win32 call. `code` must be captured right after the call (GetLastError
    /// changes with later calls), so the wrappers below return it from inside their closures.
    static func error(_ operation: String, _ code: DWORD) -> SwiftlyError {
        SwiftlyError(message: "\(operation) failed: \(Self.describe(code)) (Windows error \(code))")
    }

    /// A failed Win32 call, with its error code.
    struct Failure: Error, CustomStringConvertible, LocalizedError {
        var operation: String
        var code: DWORD

        var description: String {
            "\(self.operation) failed: \(Win32.describe(self.code)) (Windows error \(self.code))"
        }

        var errorDescription: String? {
            self.description
        }
    }

    /// The errors of a file that another program has open: access denied (for a directory with an
    /// open file in it), sharing and lock violations, and a pending delete.
    static let inUse: Set<DWORD> = [DWORD(ERROR_ACCESS_DENIED), DWORD(ERROR_SHARING_VIOLATION), DWORD(ERROR_LOCK_VIOLATION), DWORD(ERROR_DELETE_PENDING)]

    /// The system's text for a Win32 error code.
    static func describe(_ code: DWORD) -> String {
        var buffer: LPWSTR?
        let flags = DWORD(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS)
        // With FORMAT_MESSAGE_ALLOCATE_BUFFER, the buffer argument receives a pointer to the text.
        let length = withUnsafeMutablePointer(to: &buffer) {
            $0.withMemoryRebound(to: WCHAR.self, capacity: 1) {
                FormatMessageW(flags, nil, code, 0, $0, 0, nil)
            }
        }
        guard length > 0, let buffer else {
            return "unknown error"
        }
        defer { LocalFree(buffer) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: Int(length)), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a Win32 call that returns false on failure, and returns its error code (0 on success).
    private static func call(_ body: () -> Bool) -> DWORD {
        body() ? 0 : GetLastError()
    }

    // MARK: Files

    /// Win32 errors that mean the volume can't have hard links: FAT and exFAT volumes, and some
    /// network shares.
    static let hardLinksUnsupported: Set<DWORD> = [DWORD(ERROR_INVALID_FUNCTION), DWORD(ERROR_NOT_SUPPORTED), DWORD(ERROR_NOT_SAME_DEVICE)]

    /// Creates a hard link at `link` to the existing file `target`. Unlike symbolic links, hard links
    /// need neither administrator rights nor Developer Mode, but both paths must be on one volume
    /// that supports them (NTFS or ReFS).
    static func createHardLink(at link: FilePath, to target: FilePath) throws {
        let code = link.string.withCString(encodedAs: UTF16.self) { linkW in
            target.string.withCString(encodedAs: UTF16.self) { targetW in
                Self.call { CreateHardLinkW(linkW, targetW, nil) }
            }
        }
        if Self.hardLinksUnsupported.contains(code) {
            throw SwiftlyError(message: """
            swiftly's proxies are hard links, and the volume of \(link.removingLastComponent()) doesn't \
            support them (FAT, exFAT and some network shares don't). Set SWIFTLY_BIN_DIR to a directory \
            on an NTFS or ReFS volume, such as the default, %LOCALAPPDATA%\\swiftly\\bin.
            """)
        }
        guard code == 0 else {
            throw Win32.error("Creating the hard link \(link) to \(target)", code)
        }
    }

    /// Renames `source` to `destination` on the same volume, replacing it if `replace`. A running
    /// executable can be renamed, though not deleted or replaced. Unlike FileManager's moveItem,
    /// this never falls back to copying.
    static func move(_ source: FilePath, to destination: FilePath, replace: Bool = false) throws {
        let flags = DWORD(replace ? MOVEFILE_REPLACE_EXISTING : 0)
        let code = source.string.withCString(encodedAs: UTF16.self) { sourceW in
            destination.string.withCString(encodedAs: UTF16.self) { destinationW in
                Self.call { MoveFileExW(sourceW, destinationW, flags) }
            }
        }
        guard code == 0 else {
            throw Failure(operation: "Renaming \(source) to \(destination)", code: code)
        }
    }

    /// Deletes the file `path`.
    static func deleteFile(_ path: FilePath) throws {
        let code = path.string.withCString(encodedAs: UTF16.self) { pathW in
            Self.call { DeleteFileW(pathW) }
        }
        guard code == 0 else {
            throw Win32.error("Deleting \(path)", code)
        }
    }

    /// Whether the machine is an ARM64 one, whatever architecture this process runs as (an x64
    /// process runs emulated there).
    static var machineIsARM64: Bool {
        var process: USHORT = 0
        var machine: USHORT = 0
        guard IsWow64Process2(GetCurrentProcess(), &process, &machine) else {
            return false
        }
        return machine == USHORT(IMAGE_FILE_MACHINE_ARM64)
    }

    /// The System32 directory, where Windows' own tools are.
    static var system32: FilePath {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let length = GetSystemDirectoryW(&buffer, UINT(buffer.count))
        guard length > 0, Int(length) < buffer.count else {
            return FilePath(#"C:\Windows\System32"#)
        }
        return FilePath(String(decoding: buffer[..<Int(length)], as: UTF16.self))
    }

    /// Starts `commandLine` without waiting for it. Returns whether it started.
    static func startProcess(_ commandLine: String, flags: DWORD) -> Bool {
        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var process = PROCESS_INFORMATION()
        var command = Array(commandLine.utf16) + [0]
        guard CreateProcessW(nil, &command, nil, nil, false, flags, nil, nil, &startup, &process) else {
            return false
        }
        CloseHandle(process.hThread)
        CloseHandle(process.hProcess)
        return true
    }

    /// Identifies a file or directory: the volume and the 128-bit file id (FileIdInfo), which all
    /// names (hard links, different spellings of a path) of one file share.
    struct FileIdentity: Equatable {
        var volume: UInt64
        var id: [UInt8]
    }

    static func fileIdentity(of path: FilePath) -> FileIdentity? {
        // FILE_FLAG_BACKUP_SEMANTICS opens directories too; no access rights are needed to read the id.
        let handle = path.string.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING), DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            return nil
        }
        defer { CloseHandle(handle) }
        var info = FILE_ID_INFO()
        guard GetFileInformationByHandleEx(handle, FileIdInfo, &info, DWORD(MemoryLayout<FILE_ID_INFO>.size)) else {
            return nil
        }
        let id = withUnsafeBytes(of: info.FileId.Identifier) { Array($0) }
        return FileIdentity(volume: info.VolumeSerialNumber, id: id)
    }
}

// MARK: Tools and hashes

extension Win32 {
    /// The application manifest embedded in an executable, if it has one.
    static func embeddedManifest(of executable: FilePath) -> String? {
        let flags = DWORD(LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE)
        guard let module = executable.string.withCString(encodedAs: UTF16.self, { LoadLibraryExW($0, nil, flags) }) else {
            return nil
        }
        defer { FreeLibrary(module) }
        // MAKEINTRESOURCE(1) / RT_MANIFEST (24)
        let id = UnsafePointer<WCHAR>(bitPattern: 1)
        let type = UnsafePointer<WCHAR>(bitPattern: 24)
        guard let resource = FindResourceW(module, id, type),
              let loaded = LoadResource(module, resource),
              let bytes = LockResource(loaded)
        else {
            return nil
        }
        let size = Int(SizeofResource(module, resource))
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: size), as: UTF8.self)
    }

    /// Runs one of the tools that ship with Windows in `directory` and throws if it fails. Paths are
    /// passed relative to `directory`: some of these tools mangle non-ASCII command-line arguments.
    static func runTool(_ name: String, _ arguments: [String], in directory: FilePath) async throws {
        let result = try await run(
            .path(self.system32 / name),
            arguments: Arguments(arguments),
            workingDirectory: directory,
            output: .string(limit: 1024 * 1024),
            error: .string(limit: 1024 * 1024)
        )
        guard result.terminationStatus.isSuccess else {
            let output = [result.standardOutput, result.standardError].joined(separator: "\n")
            throw SwiftlyError(message: "\(name) \(arguments.joined(separator: " ")) failed: \(result.terminationStatus)\n\(output)")
        }
    }

    // MARK: Hashing

    /// A streaming hash through Windows' CNG (BCrypt) API.
    final class Hash {
        enum Algorithm: String {
            case sha256 = "SHA256" // BCRYPT_SHA256_ALGORITHM
            case sha512 = "SHA512" // BCRYPT_SHA512_ALGORITHM
        }

        private var provider: BCRYPT_ALG_HANDLE?
        private var hash: BCRYPT_HASH_HANDLE?
        private let length: Int

        init(_ algorithm: Algorithm) throws {
            self.length = algorithm == .sha256 ? 32 : 64
            var provider: BCRYPT_ALG_HANDLE?
            var status = algorithm.rawValue.withCString(encodedAs: UTF16.self) {
                BCryptOpenAlgorithmProvider(&provider, $0, nil, 0)
            }
            self.provider = provider
            guard status >= 0 else {
                throw SwiftlyError(message: "Starting a \(algorithm.rawValue) hash failed (NTSTATUS \(String(UInt32(bitPattern: status), radix: 16)))")
            }
            var hash: BCRYPT_HASH_HANDLE?
            status = BCryptCreateHash(provider, &hash, nil, 0, nil, 0, 0)
            self.hash = hash
            guard status >= 0 else {
                throw SwiftlyError(message: "Starting a \(algorithm.rawValue) hash failed (NTSTATUS \(String(UInt32(bitPattern: status), radix: 16)))")
            }
        }

        deinit {
            if let hash { BCryptDestroyHash(hash) }
            if let provider { BCryptCloseAlgorithmProvider(provider, 0) }
        }

        func update(_ data: Data) throws {
            let status = data.withUnsafeBytes { buffer -> NTSTATUS in
                guard let base = buffer.baseAddress, buffer.count > 0 else {
                    return 0
                }
                return BCryptHashData(self.hash, UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UCHAR.self)), ULONG(buffer.count), 0)
            }
            guard status >= 0 else {
                throw SwiftlyError(message: "Hashing failed (NTSTATUS \(String(UInt32(bitPattern: status), radix: 16)))")
            }
        }

        /// The digest as lowercase hex.
        func finish() throws -> String {
            var digest = [UCHAR](repeating: 0, count: self.length)
            let status = BCryptFinishHash(self.hash, &digest, ULONG(digest.count), 0)
            guard status >= 0 else {
                throw SwiftlyError(message: "Hashing failed (NTSTATUS \(String(UInt32(bitPattern: status), radix: 16)))")
            }
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    /// The hex digest of a file's contents.
    static func hash(_ algorithm: Hash.Algorithm, file: FilePath) throws -> String {
        let hash = try Hash(algorithm)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: file.string))
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try hash.update(chunk)
        }
        return try hash.finish()
    }
}

// MARK: Environment and registry

extension Win32 {
    /// Expands `%NAME%` references with this process's environment.
    static func expandEnvironmentStrings(_ value: String) -> String {
        value.withCString(encodedAs: UTF16.self) { valueW in
            let length = ExpandEnvironmentStringsW(valueW, nil, 0)
            guard length > 0 else { return value }
            var buffer = [WCHAR](repeating: 0, count: Int(length))
            guard ExpandEnvironmentStringsW(valueW, &buffer, length) > 0 else { return value }
            return String(decodingCString: buffer, as: UTF16.self)
        }
    }

    /// A string value in the registry, with its type (REG_SZ or REG_EXPAND_SZ), read without expanding it.
    struct RegistryString: Equatable {
        var value: String
        var expandable: Bool
    }

    /// Opens `root\subkey` for reading, or for reading and writing. Returns nil if the key doesn't exist.
    static func withKey<T>(_ root: HKEY, _ subkey: String, writable: Bool, _ body: (HKEY) throws -> T) throws -> T? {
        var key: HKEY?
        let access = REGSAM(writable ? KEY_QUERY_VALUE | KEY_SET_VALUE : KEY_QUERY_VALUE)
        let status = subkey.withCString(encodedAs: UTF16.self) {
            RegOpenKeyExW(root, $0, 0, access, &key)
        }
        if status == ERROR_FILE_NOT_FOUND {
            return nil
        }
        guard status == ERROR_SUCCESS, let key else {
            throw Win32.error("Opening the registry key \(subkey)", DWORD(status))
        }
        defer { RegCloseKey(key) }
        return try body(key)
    }

    /// Creates `root\subkey` if needed.
    static func createKey(_ root: HKEY, _ subkey: String) throws {
        var key: HKEY?
        let status = subkey.withCString(encodedAs: UTF16.self) {
            RegCreateKeyExW(root, $0, 0, nil, 0, REGSAM(KEY_QUERY_VALUE | KEY_SET_VALUE), nil, &key, nil)
        }
        guard status == ERROR_SUCCESS, let key else {
            throw Win32.error("Creating the registry key \(subkey)", DWORD(status))
        }
        RegCloseKey(key)
    }

    /// Deletes `root\subkey` and everything in it.
    static func deleteKey(_ root: HKEY, _ subkey: String) {
        _ = subkey.withCString(encodedAs: UTF16.self) { RegDeleteTreeW(root, $0) }
        _ = subkey.withCString(encodedAs: UTF16.self) { RegDeleteKeyW(root, $0) }
    }

    static func readString(_ key: HKEY, _ name: String) throws -> RegistryString? {
        try name.withCString(encodedAs: UTF16.self) { nameW in
            var type: DWORD = 0
            var size: DWORD = 0
            let flags = DWORD(RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND)
            var status = RegGetValueW(key, nil, nameW, flags, &type, nil, &size)
            if status == ERROR_FILE_NOT_FOUND {
                return nil
            }
            guard status == ERROR_SUCCESS else {
                throw Win32.error("Reading the registry value \(name)", DWORD(status))
            }
            var buffer = [WCHAR](repeating: 0, count: Int(size) / MemoryLayout<WCHAR>.size + 1)
            status = RegGetValueW(key, nil, nameW, flags, &type, &buffer, &size)
            guard status == ERROR_SUCCESS else {
                throw Win32.error("Reading the registry value \(name)", DWORD(status))
            }
            return RegistryString(value: String(decodingCString: buffer, as: UTF16.self), expandable: type == DWORD(REG_EXPAND_SZ))
        }
    }

    static func writeString(_ key: HKEY, _ name: String, _ value: RegistryString) throws {
        let units = Array(value.value.utf16) + [0]
        let status = name.withCString(encodedAs: UTF16.self) { nameW in
            units.withUnsafeBufferPointer { buffer in
                let size = buffer.count * MemoryLayout<WCHAR>.size
                return buffer.baseAddress!.withMemoryRebound(to: BYTE.self, capacity: size) {
                    RegSetValueExW(key, nameW, 0, DWORD(value.expandable ? REG_EXPAND_SZ : REG_SZ), $0, DWORD(size))
                }
            }
        }
        guard status == ERROR_SUCCESS else {
            throw Win32.error("Writing the registry value \(name)", DWORD(status))
        }
    }

    static func deleteValue(_ key: HKEY, _ name: String) throws {
        let status = name.withCString(encodedAs: UTF16.self) { RegDeleteValueW(key, $0) }
        guard status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND else {
            throw Win32.error("Deleting the registry value \(name)", DWORD(status))
        }
    }

    /// HWND_BROADCAST, which isn't imported (it's a cast in a macro): the message goes to every
    /// top-level window.
    private static var broadcast: HWND? {
        HWND(bitPattern: 0xFFFF)
    }

    /// How long to wait for each window to handle the message.
    private static let broadcastTimeoutMilliseconds: UINT = 5000

    /// Tells running programs (Explorer, and so the terminals started from now on) that the
    /// environment in the registry changed.
    static func broadcastEnvironmentChange() {
        _ = "Environment".withCString(encodedAs: UTF16.self) {
            SendMessageTimeoutW(Self.broadcast, UINT(WM_SETTINGCHANGE), 0, LPARAM(Int(bitPattern: $0)), UINT(SMTO_ABORTIFHUNG), Self.broadcastTimeoutMilliseconds, nil)
        }
    }
}
