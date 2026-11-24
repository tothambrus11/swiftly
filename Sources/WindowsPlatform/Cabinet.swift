import CMsi
import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// Extracts selected files from a cabinet (.cab) with the cabinet API that ships with Windows (FDI,
/// cabinet.dll), which handles the multi-gigabyte LZX cabinets in the swift.org installer.
///
/// The cabinet is read in place from a range of a larger file (a Burn bundle's container), and only
/// the wanted files are written. All file access goes through FileHandle with UTF-16 paths, so paths
/// with non-ASCII characters work; FDI itself only sees short ASCII tokens.
enum Cabinet {
    /// Extracts the files named in `files` (name in the cabinet → destination) from the cabinet at
    /// `offset ..< offset + length` of `source`. Throws if a wanted file isn't in the cabinet.
    static func extract(from source: FilePath, offset: Int, length: Int, files: [String: FilePath]) throws {
        // FDI's file callbacks take and return positions as 32-bit `long`s.
        guard length < Int(Int32.max) else {
            throw SwiftlyError(message: "A cabinet in the installer is 2 GB or larger, which the cabinet API of Windows can't read.")
        }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: source.string))
        defer { try? input.close() }
        let cabinet = Handles.shared.add(.input(input, base: UInt64(offset), length: UInt64(length)))
        defer { Handles.shared.remove(cabinet) }

        let context = Context(wanted: files)
        var error = ERF()
        guard let fdi = FDICreate(
            { size in malloc(Int(size)) },
            { pointer in free(pointer) },
            Self.open, Self.read, Self.write, Self.close, Self.seek,
            -1, // cpuUNKNOWN
            &error
        ) else {
            throw SwiftlyError(message: "Couldn't start the cabinet decompressor (FDI error \(error.erfOper)).")
        }
        defer { FDIDestroy(fdi) }

        // FDI opens "<path><name>"; the token is resolved by `open`.
        let ok = withExtendedLifetime(context) {
            "#\(cabinet)".withCString { name in
                "".withCString { path in
                    FDICopy(fdi, UnsafeMutablePointer(mutating: name), UnsafeMutablePointer(mutating: path), 0, Self.notify, nil, Unmanaged.passUnretained(context).toOpaque())
                }
            }
        }
        context.closeAll()
        if let failure = context.failure {
            throw failure
        }
        guard ok else {
            throw SwiftlyError(message: "Couldn't extract files from a cabinet in the installer (FDI error \(error.erfOper)).")
        }
        let missing = Set(files.keys).subtracting(context.extracted)
        guard missing.isEmpty else {
            throw SwiftlyError(message: "The installer is missing \(missing.sorted().joined(separator: ", ")).")
        }
    }

    /// What FDI's notifications work on.
    private final class Context {
        let wanted: [String: FilePath]
        var extracted: Set<String> = []
        var open: [INT_PTR] = []
        var failure: SwiftlyError?

        init(wanted: [String: FilePath]) {
            self.wanted = wanted
        }

        func closeAll() {
            for handle in self.open {
                Handles.shared.remove(handle)
            }
            self.open = []
        }
    }

    private static let notify: PFNFDINOTIFY = { type, notification in
        guard let notification, let user = notification.pointee.pv else {
            return 0
        }
        let context = Unmanaged<Context>.fromOpaque(user).takeUnretainedValue()
        switch type {
        case fdintCOPY_FILE:
            // Returning 0 skips the file.
            guard let name = notification.pointee.psz1.map({ String(cString: $0) }), let destination = context.wanted[name] else {
                return 0
            }
            do {
                try FileManager.default.createDirectory(atPath: destination.removingLastComponent().string, withIntermediateDirectories: true)
                guard FileManager.default.createFile(atPath: destination.string, contents: nil) else {
                    throw SwiftlyError(message: "Couldn't create \(destination).")
                }
                let output = try FileHandle(forWritingTo: URL(fileURLWithPath: destination.string))
                let handle = Handles.shared.add(.output(output))
                context.open.append(handle)
                context.extracted.insert(name)
                return handle
            } catch {
                context.failure = error as? SwiftlyError ?? SwiftlyError(message: "Couldn't write \(destination): \(error)")
                return -1
            }
        case fdintNEXT_CABINET:
            // The installer's cabinets are self-contained; a file that continues in another one
            // means it isn't the cabinet swiftly expects.
            context.failure = SwiftlyError(message: "A cabinet in the installer continues in another cabinet, which swiftly doesn't support.")
            return -1
        case fdintCLOSE_FILE_INFO:
            Handles.shared.remove(notification.pointee.hf)
            context.open.removeAll { $0 == notification.pointee.hf }
            return 1
        default:
            return 0
        }
    }

    // FDI's file callbacks. Handles are indices into `Handles`; 0 and -1 mean failure to FDI.

    private static let open: PFNOPEN = { name, _, _ in
        // The only file FDI opens itself is the cabinet, named "#<handle>".
        guard let name, case let token = String(cString: name), token.hasPrefix("#"), let handle = INT_PTR(token.dropFirst()) else {
            return -1
        }
        // FDI may have the cabinet open more than once at a time: each open gets its own position.
        return Handles.shared.open(handle) ?? -1
    }

    private static let read: PFNREAD = { handle, buffer, count in
        guard let buffer, let data = Handles.shared.read(handle, count: Int(count)) else {
            return UINT.max
        }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        return UINT(data.count)
    }

    private static let write: PFNWRITE = { handle, buffer, count in
        guard let buffer, Handles.shared.write(handle, Data(bytes: buffer, count: Int(count))) else {
            return UINT.max
        }
        return count
    }

    private static let close: PFNCLOSE = { handle in
        // FDI closes the cabinet handles it opened; the file itself stays open until `extract`
        // returns. Outputs are closed in fdintCLOSE_FILE_INFO.
        Handles.shared.closeInput(handle)
        return 0
    }

    private static let seek: PFNSEEK = { handle, distance, origin in
        Handles.shared.seek(handle, distance: Int(distance), origin: origin).map { CLong(clamping: $0) } ?? -1
    }

    /// The open files of all extractions. FDI's callbacks are C functions without a context
    /// argument, so they find their files through this table.
    private final class Handles: @unchecked Sendable {
        enum Entry {
            /// A cabinet stored in a range of a file.
            case input(FileHandle, base: UInt64, length: UInt64)
            case output(FileHandle)
        }

        static let shared = Handles()

        private let lock = NSLock()
        private var entries: [INT_PTR: Entry] = [:]
        private var positions: [INT_PTR: UInt64] = [:]
        private var next: INT_PTR = 1

        func add(_ entry: Entry) -> INT_PTR {
            self.lock.withLock {
                let handle = self.next
                self.next += 1
                self.entries[handle] = entry
                self.positions[handle] = 0
                return handle
            }
        }

        func remove(_ handle: INT_PTR) {
            self.lock.withLock {
                if case let .output(file) = self.entries.removeValue(forKey: handle) {
                    try? file.close()
                }
                self.positions[handle] = nil
            }
        }

        /// A new handle, with its own position, to the cabinet `template` refers to.
        func open(_ template: INT_PTR) -> INT_PTR? {
            self.lock.withLock {
                guard case let .input(file, base, length) = self.entries[template] else { return nil }
                let handle = self.next
                self.next += 1
                self.entries[handle] = .input(file, base: base, length: length)
                self.positions[handle] = 0
                return handle
            }
        }

        /// Forgets a handle of the cabinet that `open` made; the file stays open for the others.
        func closeInput(_ handle: INT_PTR) {
            self.lock.withLock {
                if case .input = self.entries[handle] {
                    self.entries[handle] = nil
                    self.positions[handle] = nil
                }
            }
        }

        func read(_ handle: INT_PTR, count: Int) -> Data? {
            self.lock.withLock {
                guard case let .input(file, base, length) = self.entries[handle], let position = self.positions[handle] else {
                    return nil
                }
                let wanted = Int(min(UInt64(count), length - min(position, length)))
                guard wanted > 0 else { return Data() }
                guard (try? file.seek(toOffset: base + position)) != nil, let data = try? file.read(upToCount: wanted) else {
                    return nil
                }
                self.positions[handle] = position + UInt64(data.count)
                return data
            }
        }

        func write(_ handle: INT_PTR, _ data: Data) -> Bool {
            self.lock.withLock {
                guard case let .output(file) = self.entries[handle] else { return false }
                return (try? file.write(contentsOf: data)) != nil
            }
        }

        func seek(_ handle: INT_PTR, distance: Int, origin: Int32) -> UInt64? {
            self.lock.withLock {
                guard case let .input(_, _, length) = self.entries[handle], let position = self.positions[handle] else {
                    return nil
                }
                let start: Int64 = switch origin {
                case 1: Int64(position) // SEEK_CUR
                case 2: Int64(length) // SEEK_END
                default: 0 // SEEK_SET
                }
                let target = start + Int64(distance)
                guard target >= 0, UInt64(target) <= length else { return nil }
                self.positions[handle] = UInt64(target)
                return UInt64(target)
            }
        }
    }
}
