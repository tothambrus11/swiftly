import _StringProcessing
import Foundation
import SwiftlyCore
import SystemPackage

/// The parts of a WiX Burn bundle's manifest that swiftly uses to unpack the swift.org installer.
///
/// The manifest is the file `0` in the bundle's first (UX) container. It's generated XML with one
/// element per container, package and payload, so it's read with a few regular expressions rather
/// than an XML parser (FoundationXML would add libxml2 to swiftly).
struct BurnManifest: Equatable {
    struct Container: Equatable {
        var id: String
        /// The position of the container among the bundle's containers (the UX container is 0).
        var attachedIndex: Int
        /// SHA-512 of the container, as uppercase hex.
        var hash: String?
    }

    struct Payload: Equatable {
        var id: String
        /// The file name the payload has when the bundle is laid out, such as "bld.asserts.msi".
        var filePath: String
        /// The name of the payload's file inside its container, such as "a3".
        var sourcePath: String
        var container: String?
    }

    struct Package: Equatable {
        /// The package's id, which for the swift.org installer is its MSI's file name.
        var id: String
        /// The payloads the package needs: the .msi and its .cab files.
        var payloads: [String]
    }

    var containers: [Container]
    var payloads: [String: Payload]
    var packages: [Package]

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
            self.payloads[id] = Payload(id: id, filePath: filePath, sourcePath: sourcePath, container: attributes["Container"])
        }

        for element in xml.matches(of: #/<MsiPackage\s([^>]*)>(.*?)</MsiPackage>/#.dotMatchesNewlines()) {
            guard let id = Self.attributes(element.output.1)["Id"] else {
                continue
            }
            let refs = element.output.2.matches(of: #/<PayloadRef\s+Id="([^"]*)"/#).map { Self.unescape($0.output.1) }
            self.packages.append(Package(id: id, payloads: refs))
        }

        guard !self.packages.isEmpty else {
            throw SwiftlyError(message: "The installer's bundle manifest lists no MSI packages.")
        }
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

/// Unpacks the payloads of a WiX (v4+) Burn bundle, such as the swift.org Windows installer,
/// without running it.
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

    /// Reads the `.wixburn` section of the bundle's PE header.
    static func layout(of header: Data) throws -> Layout {
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset + 2 <= header.count else { throw self.notABundle }
            return Int(header[header.startIndex + offset]) | Int(header[header.startIndex + offset + 1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            try u16(offset) | (u16(offset + 2) << 16)
        }

        let pe = try u32(0x3C)
        let sectionCount = try u16(pe + 6)
        let optionalHeaderSize = try u16(pe + 20)
        let sectionTable = pe + 24 + optionalHeaderSize
        var burnSection: Int?
        for i in 0..<sectionCount {
            let entry = sectionTable + 40 * i
            guard entry + 40 <= header.count else { throw self.notABundle }
            let name = header[(header.startIndex + entry)..<(header.startIndex + entry + 8)]
            if name.elementsEqual(Array(".wixburn".utf8)) {
                burnSection = try u32(entry + 20) // PointerToRawData
            }
        }
        guard let burn = burnSection, try u32(burn) == 0x00F1_4300 else {
            throw self.notABundle
        }
        // BURN_SECTION_HEADER: magic, version, bundle GUID, stub size, original checksum,
        // original signature offset/size, format, container count, container sizes.
        let stubSize = try u32(burn + 24)
        let count = try u32(burn + 44)
        guard count >= 1, count < 64 else { throw self.notABundle }
        let sizes = try (0..<count).map { try u32(burn + 48 + 4 * $0) }
        return Layout(stubSize: stubSize, containerSizes: sizes)
    }

    private static var notABundle: SwiftlyError {
        SwiftlyError(message: "The downloaded toolchain isn't a WiX Burn installer bundle.")
    }

    /// Unpacks the payloads of the packages `select` picks into `directory`, and returns the path of
    /// each extracted package's MSI by package id.
    static func extract(
        _ bundle: FilePath,
        into directory: FilePath,
        select: (BurnManifest) throws -> [String],
        verbose: Bool
    ) async throws -> (manifest: BurnManifest, msis: [String: FilePath]) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: bundle.string))
        defer { try? handle.close() }

        let layout = try self.layout(of: handle.read(upToCount: 64 * 1024) ?? Data())

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

        // The UX container holds the manifest.
        let uxDir = directory / "ux"
        try await self.extractContainer(handle, offset: offsets[0], size: layout.containerSizes[0], hash: nil, to: uxDir, scratch: directory)
        guard let manifestData = try? Data(contentsOf: URL(fileURLWithPath: (uxDir / "0").string)) else {
            throw SwiftlyError(message: "The installer has no bundle manifest.")
        }
        let manifest = try BurnManifest(xml: String(decoding: manifestData, as: UTF8.self))

        let packageIds = try select(manifest)
        let packages = manifest.packages.filter { packageIds.contains($0.id) }
        let payloads = packages.flatMap(\.payloads).compactMap { manifest.payloads[$0] }
        let containers = manifest.containers.filter { container in payloads.contains { $0.container == container.id } }

        let payloadDir = directory / "payloads"
        try await fs.mkdir(.parents, atPath: payloadDir)
        for container in containers {
            guard container.attachedIndex > 0, container.attachedIndex < offsets.count else {
                throw SwiftlyError(message: "The installer's manifest refers to a container (\(container.id)) it doesn't have.")
            }
            if verbose {
                print("Unpacking \(container.id)")
            }
            let containerDir = directory / "c\(container.attachedIndex)"
            try await self.extractContainer(
                handle,
                offset: offsets[container.attachedIndex],
                size: layout.containerSizes[container.attachedIndex],
                hash: container.hash,
                to: containerDir,
                scratch: directory
            )
            for payload in payloads where payload.container == container.id {
                try await fs.move(atPath: containerDir / payload.sourcePath, toPath: payloadDir / payload.filePath)
            }
            try await fs.remove(atPath: containerDir)
        }

        var msis: [String: FilePath] = [:]
        for package in packages {
            if let msi = package.payloads.compactMap({ manifest.payloads[$0] }).first(where: { $0.filePath.lowercased().hasSuffix(".msi") }) {
                msis[package.id] = payloadDir / msi.filePath
            }
        }
        return (manifest, msis)
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

    /// Copies one container out of the bundle, checks its hash and unpacks it with expand.exe.
    private static func extractContainer(
        _ handle: FileHandle, offset: Int, size: Int, hash expected: String?, to destination: FilePath, scratch: FilePath
    ) async throws {
        let cab = scratch / "container.cab"
        try await fs.create(file: cab, contents: nil)
        let output = try FileHandle(forWritingTo: URL(fileURLWithPath: cab.string))
        let hash = try Win32.Hash(.sha512)
        do {
            defer { try? output.close() }
            try handle.seek(toOffset: UInt64(offset))
            var left = size
            while left > 0 {
                guard let chunk = try handle.read(upToCount: min(left, 8 * 1024 * 1024)), !chunk.isEmpty else {
                    throw SwiftlyError(message: "The installer ends in the middle of a container.")
                }
                try output.write(contentsOf: chunk)
                try hash.update(chunk)
                left -= chunk.count
            }
        }
        if let expected, try hash.finish() != expected.lowercased() {
            throw SwiftlyError(message: "An installer container doesn't match the hash in the installer's manifest.")
        }

        try await fs.mkdir(.parents, atPath: destination)
        // expand.exe ships with Windows and handles the LZX-compressed multi-gigabyte cabinets.
        try await Win32.runTool("expand.exe", ["-F:*", cab.string, destination.string])
        try await fs.remove(atPath: cab)
    }
}
