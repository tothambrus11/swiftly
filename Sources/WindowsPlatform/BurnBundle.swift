import _StringProcessing
import Foundation
import SwiftlyCore
import SystemPackage

/// The parts of a WiX Burn bundle's manifest that swiftly uses to unpack the swift.org installer.
///
/// The manifest is the file `0` in the bundle's first (UX) container. It's generated XML with one
/// element per container, package and payload, so it's read with a few regular expressions rather
/// than an XML parser (FoundationXML would add libxml2 to swiftly). This follows the format as the
/// swift.org bundles have it; no WiX code is used.
struct BurnManifest: Equatable {
    struct Container: Equatable {
        var id: String
        /// The position of the container among the bundle's containers (the UX container is 0).
        var attachedIndex: Int
        /// The container's hash as hex (SHA-512 in WiX 4 and later).
        var hash: String?
    }

    struct Payload: Equatable {
        var id: String
        /// The file name the payload has when the bundle is laid out, such as "bld.asserts.msi".
        var filePath: String
        /// The name of the payload's file inside its container, such as "a3".
        var sourcePath: String
        var container: String?
        /// The payload's size and hash (hex), as the manifest lists them.
        var fileSize: Int?
        var hash: String?
    }

    struct Package: Equatable {
        /// The package's id, which for the swift.org installer is its MSI's file name.
        var id: String
        /// The payloads the package needs: the .msi and its .cab files.
        var payloads: [String]
        /// When the installer installs the package (Burn's condition syntax), if not always.
        var installCondition: String?
    }

    var containers: [Container]
    var payloads: [String: Payload]
    var packages: [Package]
    /// The bundle's variables and their default values (`<Variable Id= Value=>`).
    var variables: [String: String] = [:]
    /// The variables whose type is numeric (`Type="numeric"`); the others compare as strings.
    var numericVariables: Set<String> = []
    /// The bundle's registration (`<Registration Version= ...>`) and add/remove programs entry
    /// (`<Arp DisplayName= DisplayVersion= ...>`) attributes.
    var registration: [String: String] = [:]

    init(xml: String) throws {
        self.containers = []
        self.payloads = [:]
        self.packages = []

        for element in xml.matches(of: #/<Container\s([^>]*)>/#) {
            let attributes = Self.attributes(element.output.1)
            guard let id = attributes["Id"], let index = attributes["AttachedIndex"].flatMap(Int.init) else {
                continue
            }
            self.containers.append(Container(id: id, attachedIndex: index, hash: attributes["Hash"]))
        }

        for element in xml.matches(of: #/<Payload\s([^>]*)>/#) {
            let attributes = Self.attributes(element.output.1)
            guard let id = attributes["Id"], let filePath = attributes["FilePath"], let sourcePath = attributes["SourcePath"] else {
                continue
            }
            guard Self.isSafeRelativePath(filePath), Self.isSafeRelativePath(sourcePath) else {
                throw SwiftlyError(message: "The installer's manifest has an invalid payload name: \(filePath).")
            }
            self.payloads[id] = Payload(
                id: id, filePath: filePath, sourcePath: sourcePath, container: attributes["Container"],
                fileSize: attributes["FileSize"].flatMap(Int.init), hash: attributes["Hash"]
            )
        }

        for element in xml.matches(of: #/<MsiPackage\s([^>]*)>(.*?)</MsiPackage>/#.dotMatchesNewlines()) {
            let attributes = Self.attributes(element.output.1)
            guard let id = attributes["Id"] else {
                continue
            }
            let refs = element.output.2.matches(of: #/<PayloadRef\s+Id="([^"]*)"/#).map { Self.unescape($0.output.1) }
            self.packages.append(Package(id: id, payloads: refs, installCondition: attributes["InstallCondition"].flatMap { $0.isEmpty ? nil : $0 }))
        }

        for element in xml.matches(of: #/<Variable\s([^>]*)>/#) {
            let attributes = Self.attributes(element.output.1)
            if let id = attributes["Id"] {
                self.variables[id] = attributes["Value"] ?? ""
                if attributes["Type"]?.lowercased() == "numeric" {
                    self.numericVariables.insert(id)
                }
            }
        }
        for element in xml.matches(of: #/<(?:Registration|Arp)\s([^>]*)>/#) {
            self.registration.merge(Self.attributes(element.output.1)) { first, _ in first }
        }

        guard !self.packages.isEmpty else {
            throw SwiftlyError(message: "The installer's bundle manifest lists no MSI packages.")
        }
    }

    /// Whether `path` stays inside the directory it's extracted to and names a file Windows can
    /// create there: relative, no drive or `..`, no reserved device names (CON, NUL, COM1, ...)
    /// and no components ending in a dot or a space (which Windows drops).
    static func isSafeRelativePath(_ path: String) -> Bool {
        let components = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
        let reserved = Set(["con", "prn", "aux", "nul"])
            .union((1...9).flatMap { ["com\($0)", "lpt\($0)"] })
        return !path.isEmpty && !path.contains(":") && !path.hasPrefix("\\") && !path.hasPrefix("/")
            && !components.isEmpty && !components.contains { $0 == ".." || $0 == "." }
            && !components.contains { $0.hasSuffix(".") || $0.hasSuffix(" ") }
            && !components.contains { reserved.contains(String($0.split(separator: ".").first ?? "").lowercased()) }
    }

    private static func attributes(_ text: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for match in text.matches(of: #/([A-Za-z]+)="([^"]*)"/#) {
            result[String(match.output.1)] = Self.unescape(match.output.2)
        }
        return result
    }

    private static func unescape(_ value: Substring) -> String {
        value.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Unpacks payloads of a WiX (4+) Burn bundle, such as the swift.org Windows installer, without
/// running it.
///
/// A bundle is the Burn engine followed by its containers, which are cabinet files: the UX container
/// (the bundle's UI and manifest) and the attached containers with the payloads. `installer.exe /layout`
/// can't be used because the swift.org bundle only copies itself on layout.
enum BurnBundle {
    /// Where each container starts and how long it is.
    struct Layout: Equatable {
        var stubSize: Int
        var containerSizes: [Int]
    }

    /// Reads the `.wixburn` section the PE header of the bundle points to. `read` returns up to
    /// `count` bytes of the bundle at `offset`.
    static func layout(read: (_ offset: Int, _ count: Int) throws -> Data) throws -> Layout {
        func u16(_ data: Data, _ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= data.count else { throw self.notABundle }
            return Int(data[data.startIndex + offset]) | Int(data[data.startIndex + offset + 1]) << 8
        }
        func u32(_ data: Data, _ offset: Int) throws -> Int {
            try u16(data, offset) | (u16(data, offset + 2) << 16)
        }

        let header = try read(0, 64 * 1024)
        let pe = try u32(header, 0x3C)
        let sectionCount = try u16(header, pe + 6)
        let optionalHeaderSize = try u16(header, pe + 20)
        let sectionTable = pe + 24 + optionalHeaderSize
        var burnSection: Int?
        for i in 0..<sectionCount {
            let entry = sectionTable + 40 * i
            guard entry + 40 <= header.count else { throw self.notABundle }
            let name = header[(header.startIndex + entry)..<(header.startIndex + entry + 8)]
            if name.elementsEqual(Array(".wixburn".utf8)) {
                burnSection = try u32(header, entry + 20) // PointerToRawData
            }
        }
        guard let burnSection else {
            throw self.notABundle
        }
        // BURN_SECTION_HEADER: magic, version, bundle GUID, stub size, original checksum,
        // original signature offset/size, format, container count, container sizes.
        let burn = try read(burnSection, 48 + 4 * 64)
        guard try u32(burn, 0) == 0x00F1_4300 else {
            throw self.notABundle
        }
        let version = try u32(burn, 4)
        guard version == 2 else {
            throw SwiftlyError(message: "The installer is a Burn bundle of an unsupported format (version \(version)); swiftly reads the format of the WiX 4 and later installers swift.org publishes.")
        }
        let stubSize = try u32(burn, 24)
        let count = try u32(burn, 44)
        guard count >= 1, count < 64 else { throw self.notABundle }
        let sizes = try (0..<count).map { try u32(burn, 48 + 4 * $0) }
        return Layout(stubSize: stubSize, containerSizes: sizes)
    }

    private static var notABundle: SwiftlyError {
        SwiftlyError(message: "The downloaded toolchain isn't a WiX Burn installer bundle.")
    }

    /// The hash algorithm a hex digest in a Burn manifest was made with, by its length.
    static func hashAlgorithm(ofHexDigest digest: String) throws -> Win32.Hash.Algorithm {
        switch digest.count {
        case 128: .sha512
        case 64: .sha256
        default:
            throw SwiftlyError(message: "The installer's manifest uses an unsupported hash (\(digest.count) hex digits); it's probably from an older installer swiftly can't read.")
        }
    }

    /// Unpacks the payloads of the packages `select` picks into `directory` and returns the path of
    /// each package's MSI by package id (lowercased).
    static func extract(
        _ ctx: SwiftlyCoreContext,
        _ bundle: FilePath,
        into directory: FilePath,
        select: (BurnManifest) throws -> [String],
        verbose: Bool
    ) async throws -> [String: FilePath] {
        try await fs.mkdir(.parents, atPath: directory)
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: bundle.string))
        defer { try? handle.close() }

        let layout = try self.layout { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }

        // The containers follow the engine. The bundle's original Authenticode signature can sit
        // between the UX container and the attached ones, so look for each cabinet header (with the
        // expected size) near where the container should start.
        var offsets: [Int] = []
        var offset = layout.stubSize
        for size in layout.containerSizes {
            try handle.seek(toOffset: UInt64(offset))
            let window = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard let found = self.findCabinet(in: window, size: size) else {
                throw SwiftlyError(message: "The installer's container at offset \(offset) is missing or damaged.")
            }
            offset += found
            offsets.append(offset)
            offset += size
        }

        // The UX container holds the manifest, the file "0".
        let manifestFile = directory / "manifest.xml"
        try Cabinet.extract(from: bundle, offset: offsets[0], length: layout.containerSizes[0], files: ["0": manifestFile])
        let manifest = try BurnManifest(xml: String(decoding: Data(contentsOf: manifestFile), as: UTF8.self))

        let selected = Set(try select(manifest).map { $0.lowercased() })
        let packages = manifest.packages.filter { selected.contains($0.id.lowercased()) }
        let payloads = packages.flatMap(\.payloads).compactMap { manifest.payloads[$0] }
        // Two payloads written to one file would overwrite each other (names are case-insensitive).
        var destinations: Set<String> = []
        for payload in payloads where !destinations.insert(payload.filePath.lowercased()).inserted {
            throw SwiftlyError(message: "The installer's manifest has two payloads named \(payload.filePath).")
        }
        let containers = manifest.containers.filter { container in payloads.contains { $0.container == container.id } }

        for container in containers {
            guard container.attachedIndex > 0, container.attachedIndex < offsets.count else {
                throw SwiftlyError(message: "The installer's manifest refers to a container (\(container.id)) it doesn't have.")
            }
            let start = offsets[container.attachedIndex]
            let length = layout.containerSizes[container.attachedIndex]
            if verbose {
                await ctx.message("Unpacking \(container.id)...")
            }
            // The bundle's signature covers the manifest, and the manifest's hashes the containers.
            guard let expected = container.hash else {
                throw SwiftlyError(message: "The installer's manifest has no hash for its container \(container.id).")
            }
            try self.verify(handle, offset: start, length: length, expected: expected, name: container.id)
            // Only the payloads of the selected packages are written; the Android SDK, the debugger
            // and so on in the same containers are skipped.
            var files: [String: FilePath] = [:]
            for payload in payloads where payload.container == container.id {
                files[payload.sourcePath] = directory / payload.filePath
            }
            try Cabinet.extract(from: bundle, offset: start, length: length, files: files)
            // The payloads too have a size and a hash in the manifest.
            for payload in payloads where payload.container == container.id {
                try self.verify(payload, at: directory / payload.filePath)
            }
        }

        var msis: [String: FilePath] = [:]
        for package in packages {
            if let msi = package.payloads.compactMap({ manifest.payloads[$0] }).first(where: { $0.filePath.lowercased().hasSuffix(".msi") }) {
                msis[package.id.lowercased()] = directory / msi.filePath
            }
        }
        return msis
    }

    /// Checks an extracted payload against the size and hash the manifest lists for it.
    static func verify(_ payload: BurnManifest.Payload, at path: FilePath) throws {
        if let size = payload.fileSize,
           let actual = (try? FileManager.default.attributesOfItem(atPath: path.string))?[.size] as? NSNumber,
           actual.intValue != size
        {
            throw SwiftlyError(message: "The installer's payload \(payload.filePath) has \(actual) bytes, not the \(size) its manifest lists.")
        }
        if let expected = payload.hash {
            guard try Win32.hash(self.hashAlgorithm(ofHexDigest: expected), file: path) == expected.lowercased() else {
                throw SwiftlyError(message: "The installer's payload \(payload.filePath) doesn't match the hash in its manifest.")
            }
        }
    }

    /// Checks a container against its hash in the manifest, which the bundle's signature covers.
    private static func verify(_ handle: FileHandle, offset: Int, length: Int, expected: String, name: String) throws {
        let hash = try Win32.Hash(self.hashAlgorithm(ofHexDigest: expected))
        try handle.seek(toOffset: UInt64(offset))
        var left = length
        while left > 0 {
            guard let chunk = try handle.read(upToCount: min(left, 8 * 1024 * 1024)), !chunk.isEmpty else {
                throw SwiftlyError(message: "The installer ends in the middle of its container \(name).")
            }
            try hash.update(chunk)
            left -= chunk.count
        }
        guard try hash.finish() == expected.lowercased() else {
            throw SwiftlyError(message: "The installer's container \(name) doesn't match the hash in its manifest.")
        }
    }

    /// The offset of a cabinet header ("MSCF" with the given cabinet size) in `data`.
    static func findCabinet(in data: Data, size: Int) -> Int? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12 else { return nil }
        for i in 0...(bytes.count - 12) where bytes[i] == 0x4D && bytes[i + 1] == 0x53 && bytes[i + 2] == 0x43 && bytes[i + 3] == 0x46 {
            let cabSize = Int(bytes[i + 8]) | Int(bytes[i + 9]) << 8 | Int(bytes[i + 10]) << 16 | Int(bytes[i + 11]) << 24
            if cabSize == size {
                return i
            }
        }
        return nil
    }
}

/// Burn's install conditions, for the simple forms the swift.org bundle uses: variables, numbers
/// and strings, compared with = <> < > <= >=, combined with NOT, AND, OR and parentheses. A
/// variable alone is true when it's set and not 0. Anything else is an error, not a guess.
struct BurnCondition {
    enum Token: Equatable {
        case word(String), number(Int), string(String), op(String), open, close
    }

    let tokens: [Token]
    var position = 0
    let variables: [String: String]
    let numeric: Set<String>

    init(_ text: String, variables: [String: String], numeric: Set<String>) throws {
        var tokens: [Token] = []
        var rest = Substring(text)
        while let first = rest.first {
            if first.isWhitespace {
                rest = rest.dropFirst()
            } else if first == "(" || first == ")" {
                tokens.append(first == "(" ? .open : .close)
                rest = rest.dropFirst()
            } else if first == "\"" {
                guard let end = rest.dropFirst().firstIndex(of: "\"") else {
                    throw SwiftlyError(message: "The installer's condition \(text) has an unterminated string.")
                }
                tokens.append(.string(String(rest[rest.index(after: rest.startIndex)..<end])))
                rest = rest[rest.index(after: end)...]
            } else if let match = rest.prefixMatch(of: #/<>|<=|>=|=|<|>/#) {
                tokens.append(.op(String(match.output)))
                rest = rest[match.range.upperBound...]
            } else if let match = rest.prefixMatch(of: #/[0-9]+/#) {
                guard let number = Int(match.output) else {
                    throw SwiftlyError(message: "The installer's condition \(text) has a number swiftly can't read.")
                }
                tokens.append(.number(number))
                rest = rest[match.range.upperBound...]
            } else if let match = rest.prefixMatch(of: #/[A-Za-z_][A-Za-z0-9_.]*/#) {
                tokens.append(.word(String(match.output)))
                rest = rest[match.range.upperBound...]
            } else {
                throw SwiftlyError(message: "swiftly can't evaluate the installer's condition \(text).")
            }
        }
        self.tokens = tokens
        self.variables = variables
        self.numeric = numeric
    }

    /// Evaluates `text` with `variables`.
    /// Evaluates `text` with `variables`, of which those in `numeric` are numbers (as their
    /// `Type="numeric"` says) and the others strings, even if they're digits.
    static func evaluate(_ text: String, variables: [String: String], numeric: Set<String>) throws -> Bool {
        var condition = try BurnCondition(text, variables: variables, numeric: numeric)
        let result = try condition.or()
        guard condition.position == condition.tokens.count else {
            throw SwiftlyError(message: "swiftly can't evaluate the installer's condition \(text).")
        }
        return result
    }

    private mutating func next() -> Token? {
        guard self.position < self.tokens.count else { return nil }
        defer { self.position += 1 }
        return self.tokens[self.position]
    }

    private func peekWord(_ word: String) -> Bool {
        if self.position < self.tokens.count, case let .word(w) = self.tokens[self.position] {
            return w.lowercased() == word
        }
        return false
    }

    private mutating func or() throws -> Bool {
        var value = try self.and()
        while self.peekWord("or") {
            self.position += 1
            value = try self.and() || value
        }
        return value
    }

    private mutating func and() throws -> Bool {
        var value = try self.not()
        while self.peekWord("and") {
            self.position += 1
            value = try self.not() && value
        }
        return value
    }

    private mutating func not() throws -> Bool {
        if self.peekWord("not") {
            self.position += 1
            return try !self.not()
        }
        return try self.comparison()
    }

    enum Value: Equatable {
        case number(Int), string(String)
    }

    private mutating func value(_ token: Token?) throws -> Value {
        switch token {
        case let .number(n): return .number(n)
        case let .string(s): return .string(s)
        case let .word(name):
            guard let raw = self.variables[name] else {
                throw SwiftlyError(message: "The installer's condition uses \(name), which swiftly doesn't know.")
            }
            guard self.numeric.contains(name) else {
                return .string(raw)
            }
            guard let number = Int(raw) else {
                throw SwiftlyError(message: "The installer's numeric variable \(name) has the value \(raw).")
            }
            return .number(number)
        default:
            throw SwiftlyError(message: "swiftly can't evaluate one of the installer's conditions.")
        }
    }

    private mutating func comparison() throws -> Bool {
        if self.position < self.tokens.count, self.tokens[self.position] == .open {
            self.position += 1
            let value = try self.or()
            guard self.next() == .close else {
                throw SwiftlyError(message: "One of the installer's conditions has unbalanced parentheses.")
            }
            return value
        }
        let left = try self.value(self.next())
        guard self.position < self.tokens.count, case let .op(op) = self.tokens[self.position] else {
            // A variable alone: set and not 0.
            switch left {
            case let .number(n): return n != 0
            case let .string(s): return !s.isEmpty
            }
        }
        self.position += 1
        let right = try self.value(self.next())
        switch (left, right) {
        case let (.number(a), .number(b)):
            return Self.compare(a, b, op)
        case let (.string(a), .string(b)):
            return Self.compare(a, b, op)
        case let (.number(a), .string(b)):
            // As Burn does, a number and a string compare as strings.
            return Self.compare(String(a), b, op)
        case let (.string(a), .number(b)):
            return Self.compare(a, String(b), op)
        }
    }

    private static func compare<T: Comparable>(_ a: T, _ b: T, _ op: String) -> Bool {
        switch op {
        case "=": a == b
        case "<>": a != b
        case "<": a < b
        case ">": a > b
        case "<=": a <= b
        default: a >= b
        }
    }
}
