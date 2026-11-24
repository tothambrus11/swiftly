import Foundation
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

    /// The System32 directory, where Windows' own tools are.
    static var system32: FilePath {
        var buffer = [WCHAR](repeating: 0, count: Int(MAX_PATH) + 1)
        let length = GetSystemDirectoryW(&buffer, UINT(buffer.count))
        guard length > 0, Int(length) < buffer.count else {
            return FilePath(#"C:\Windows\System32"#)
        }
        return FilePath(String(decoding: buffer[..<Int(length)], as: UTF16.self))
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
