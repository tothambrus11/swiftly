import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// An environment in the registry: the user's (HKCU\Environment), which new terminals start with
/// after the machine's. Windows has no shell profile; this is where swiftly puts its bin directory
/// on Path and records its SWIFTLY_*_DIR settings.
///
/// Values are read and written raw, keeping their type: entries such as `%USERPROFILE%\bin` stay
/// unexpanded in a REG_EXPAND_SZ value. (`setx` and .NET's SetEnvironmentVariable don't do that.)
/// (`@unchecked Sendable`: `root` is one of the predefined keys, which are constants.)
struct RegistryEnvironment: @unchecked Sendable {
    var root: HKEY
    var subkey: String

    static var user: Self { Self(root: HKEY_CURRENT_USER, subkey: "Environment") }
    static var machine: Self { Self(root: HKEY_LOCAL_MACHINE, subkey: #"SYSTEM\CurrentControlSet\Control\Session Manager\Environment"#) }

    func read(_ name: String) throws -> Win32.RegistryString? {
        try Win32.withKey(self.root, self.subkey, writable: false) { try Win32.readString($0, name) } ?? nil
    }

    func update<T>(_ body: (HKEY) throws -> T) throws -> T {
        guard let result = try Win32.withKey(self.root, self.subkey, writable: true, body) else {
            throw SwiftlyError(message: "The registry key \(self.subkey) doesn't exist.")
        }
        return result
    }

    // MARK: Path

    /// Adds `directory` to the front of Path, unless it's there already. Returns whether Path changed.
    func addToPath(_ directory: FilePath) throws -> Bool {
        try self.update { key in
            let current = try Win32.readString(key, "Path") ?? .init(value: "", expandable: true)
            guard !UserPath.contains(current, directory) else {
                return false
            }
            try Win32.writeString(key, "Path", .init(value: UserPath.adding(directory, to: current.value), expandable: current.expandable))
            return true
        }
    }

    /// Removes `directory` from Path, and Path itself if nothing else is left. Returns whether Path changed.
    func removeFromPath(_ directory: FilePath) throws -> Bool {
        try self.update { key in
            guard let current = try Win32.readString(key, "Path") else {
                return false
            }
            let updated = UserPath.removing(directory, from: current)
            guard updated != current.value else {
                return false
            }
            if updated.split(separator: ";").isEmpty {
                try Win32.deleteValue(key, "Path")
            } else {
                try Win32.writeString(key, "Path", .init(value: updated, expandable: current.expandable))
            }
            return true
        }
    }

    // MARK: swiftly's variables

    /// Records `variables` (name → value), leaving values that already say the same, also through
    /// a REG_EXPAND_SZ value that expands to it. Returns the names it wrote.
    func record(_ variables: [(String, String)]) throws -> [String] {
        try self.update { key in
            var written: [String] = []
            for (name, value) in variables {
                if let stored = try Win32.readString(key, name), UserPath.value(of: stored) == value {
                    continue
                }
                try Win32.writeString(key, name, .init(value: value, expandable: false))
                written.append(name)
            }
            return written
        }
    }

    /// Deletes the variables of `variables` whose value is the one given. Returns the names it deleted.
    func forget(_ variables: [(String, String)]) throws -> [String] {
        try self.update { key in
            var deleted: [String] = []
            for (name, value) in variables {
                if let stored = try Win32.readString(key, name), UserPath.value(of: stored) == value {
                    try Win32.deleteValue(key, name)
                    deleted.append(name)
                }
            }
            return deleted
        }
    }
}

/// Path entries, compared like Windows does.
enum UserPath {
    /// The variables that move swiftly's directories; init records them for new terminals, as the
    /// env.sh file does on Linux and macOS.
    static let swiftlyVariables = ["SWIFTLY_HOME_DIR", "SWIFTLY_BIN_DIR", "SWIFTLY_TOOLCHAINS_DIR"]

    /// What a variable's value means: expanded if it's REG_EXPAND_SZ. Windows doesn't expand REG_SZ values.
    static func value(of stored: Win32.RegistryString, expand: (String) -> String = Win32.expandEnvironmentStrings) -> String {
        stored.expandable ? expand(stored.value) : stored.value
    }

    /// A Path entry in a comparable form: backslashes, no quotes or trailing separator, lowercase
    /// (Windows paths are case-insensitive). Nil for an empty entry.
    static func normalized(_ entry: String) -> String? {
        var path = entry.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "\\")
        if path.hasPrefix("\""), path.hasSuffix("\""), path.count >= 2 {
            path = String(path.dropFirst().dropLast())
        }
        while path.count > 3, path.hasSuffix("\\") {
            path.removeLast()
        }
        return path.isEmpty ? nil : path.lowercased()
    }

    /// The entries of `path`, expanded if it's REG_EXPAND_SZ.
    static func entries(of path: Win32.RegistryString, expand: (String) -> String = Win32.expandEnvironmentStrings) -> [String] {
        path.value.split(separator: ";", omittingEmptySubsequences: false).map {
            path.expandable ? expand(String($0)) : String($0)
        }
    }

    static func contains(_ path: Win32.RegistryString, _ directory: FilePath, expand: (String) -> String = Win32.expandEnvironmentStrings) -> Bool {
        let wanted = self.normalized(directory.string)
        return self.entries(of: path, expand: expand).contains { self.normalized($0) == wanted }
    }

    /// `path` with `directory` in front.
    static func adding(_ directory: FilePath, to path: String) -> String {
        path.isEmpty ? directory.string : directory.string + ";" + path
    }

    /// `path` without any entry that is `directory`; the other entries stay exactly as written.
    static func removing(_ directory: FilePath, from path: Win32.RegistryString, expand: (String) -> String = Win32.expandEnvironmentStrings) -> String {
        let wanted = self.normalized(directory.string)
        return path.value.split(separator: ";", omittingEmptySubsequences: false)
            .filter { entry in
                let meaning = path.expandable ? expand(String(entry)) : String(entry)
                return self.normalized(meaning) != wanted
            }
            .joined(separator: ";")
    }

    /// The `swift.exe` that a new terminal would find ahead of `directory`, if any. The machine Path
    /// comes before the user's, so a Swift installed for all users wins over swiftly's proxies.
    /// Empty and relative entries are skipped.
    static func swiftAhead(of directory: FilePath, machine: Win32.RegistryString?, user: Win32.RegistryString?, exists: (FilePath) -> Bool) -> FilePath? {
        let wanted = self.normalized(directory.string)
        for path in [machine, user].compactMap({ $0 }) {
            for entry in self.entries(of: path) {
                guard let normalized = self.normalized(entry), FilePath(entry).isAbsolute else {
                    continue
                }
                if normalized == wanted {
                    return nil
                }
                let swift = FilePath(entry) / "swift.exe"
                if exists(swift) {
                    return swift
                }
            }
        }
        return nil
    }
}
