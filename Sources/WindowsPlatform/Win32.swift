import Foundation
import Subprocess
import SwiftlyCore
import SystemPackage
import WinSDK

/// Small wrappers around the Win32 calls the Windows platform needs.
enum Win32 {
    /// The error of a failed Win32 call.
    static func error(_ operation: String, _ code: DWORD = GetLastError()) -> SwiftlyError {
        SwiftlyError(message: "\(operation) failed (Windows error \(code))")
    }

    /// The `System32` directory, where the tools that ship with Windows (expand.exe, tar.exe) live.
    static var system32: FilePath {
        let root = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        return FilePath(root) / "System32"
    }

    /// Runs one of the tools that ship with Windows and throws if it fails.
    static func runTool(_ name: String, _ arguments: [String]) async throws {
        let result = try await run(
            .path(self.system32 / name),
            arguments: Arguments(arguments),
            output: .string(limit: 1024 * 1024),
            error: .string(limit: 1024 * 1024)
        )
        guard result.terminationStatus.isSuccess else {
            let output = result.standardOutput + "\n" + result.standardError
            throw SwiftlyError(message: "\(name) \(arguments.joined(separator: " ")) failed: \(result.terminationStatus)\n\(output)")
        }
    }

    // MARK: Hashing

    /// A streaming hash through the Windows CryptoAPI.
    final class Hash {
        enum Algorithm: ALG_ID {
            case sha256 = 0x800C // CALG_SHA_256
            case sha512 = 0x800E // CALG_SHA_512
        }

        private var provider: HCRYPTPROV = 0
        private var hash: HCRYPTHASH = 0

        init(_ algorithm: Algorithm) throws {
            // PROV_RSA_AES (24) is the provider type that implements SHA-2; CRYPT_VERIFYCONTEXT
            // because no keys are involved.
            guard CryptAcquireContextW(&self.provider, nil, nil, 24, DWORD(0xF000_0000)) else {
                throw Win32.error("CryptAcquireContextW")
            }
            guard CryptCreateHash(self.provider, algorithm.rawValue, 0, 0, &self.hash) else {
                throw Win32.error("CryptCreateHash")
            }
        }

        deinit {
            if self.hash != 0 { CryptDestroyHash(self.hash) }
            if self.provider != 0 { CryptReleaseContext(self.provider, 0) }
        }

        func update(_ data: Data) throws {
            try data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress?.assumingMemoryBound(to: BYTE.self), buffer.count > 0 else {
                    return
                }
                guard CryptHashData(self.hash, base, DWORD(buffer.count), 0) else {
                    throw Win32.error("CryptHashData")
                }
            }
        }

        /// The digest as lowercase hex.
        func finish() throws -> String {
            var size: DWORD = 0
            var sizeLength = DWORD(MemoryLayout<DWORD>.size)
            guard withUnsafeMutableBytes(of: &size, { CryptGetHashParam(self.hash, 4 /* HP_HASHSIZE */, $0.baseAddress!.assumingMemoryBound(to: BYTE.self), &sizeLength, 0) }) else {
                throw Win32.error("CryptGetHashParam")
            }
            var digest = [BYTE](repeating: 0, count: Int(size))
            guard CryptGetHashParam(self.hash, 2 /* HP_HASHVAL */, &digest, &size, 0) else {
                throw Win32.error("CryptGetHashParam")
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

    // MARK: Files

    /// Creates a hard link at `link` to the existing file `target`. Unlike symbolic links, hard links
    /// need neither administrator rights nor Developer Mode, but both paths must be on one volume.
    static func createHardLink(at link: FilePath, to target: FilePath) throws {
        let ok = link.string.withCString(encodedAs: UTF16.self) { linkW in
            target.string.withCString(encodedAs: UTF16.self) { targetW in
                CreateHardLinkW(linkW, targetW, nil)
            }
        }
        guard ok else {
            throw Win32.error("Creating the hard link \(link) to \(target)")
        }
    }

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
}
