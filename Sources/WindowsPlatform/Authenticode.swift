import CWinSDKExtras
import Foundation
import SwiftlyCore
import SystemPackage
import WinSDK

/// Checks Authenticode signatures, which is how swift.org signs its Windows installers.
enum Authenticode {
    /// Who signed a file: the parts of the signing certificate and of the root of its chain that
    /// swiftly checks, and the certificate's extended key usages.
    struct Signer: Equatable {
        var commonName: String
        var organization: String
        var locality: String = ""
        var state: String = ""
        var country: String
        var rootCommonName: String
        var rootOrganization: String
        var keyUsages: [String]
        /// The chain's trust errors (CERT_TRUST_STATUS.dwErrorStatus), as WinVerifyTrust built it.
        var chainErrors: DWORD = 0

        var summary: String {
            "CN=\(self.commonName), O=\(self.organization), L=\(self.locality), S=\(self.state), C=\(self.country) (root: CN=\(self.rootCommonName), O=\(self.rootOrganization))"
        }
    }

    /// What swiftly requires of a signer. The signing certificates are renewed every year, and the
    /// intermediate CA can change too; the organization and the root stay.
    struct Requirement {
        var organization: String
        var locality: String
        var state: String
        var country: String
        /// The roots the chain may end in, as (common name, organization).
        var roots: [(commonName: String, organization: String)]

        var summary: String {
            "O=\(self.organization), L=\(self.locality), S=\(self.state), C=\(self.country) (root: \(self.roots.map { "CN=\($0.commonName), O=\($0.organization)" }.joined(separator: " or ")))"
        }

        /// Why `signer` doesn't meet this requirement, or nil if it does.
        func mismatch(_ signer: Signer) -> String? {
            var problems: [String] = []
            if signer.organization != self.organization || signer.locality != self.locality || signer.state != self.state || signer.country != self.country {
                problems.append("its signer isn't \(self.organization) (\(self.locality), \(self.state), \(self.country))")
            }
            if !self.roots.contains(where: { $0.commonName == signer.rootCommonName && $0.organization == signer.rootOrganization }) {
                problems.append("its certificate chain doesn't end in an expected root")
            }
            if !signer.keyUsages.contains(Authenticode.codeSigningUsage) {
                problems.append("its certificate isn't for code signing")
            }
            guard !problems.isEmpty else {
                return nil
            }
            return "\(problems.joined(separator: ", and ")): it's signed by \(signer.summary), and swiftly expects \(self.summary)."
        }
    }

    /// The signer of the swift.org Windows installers: Apple, through DigiCert.
    static let swiftOrg = Requirement(
        organization: "Apple Inc.", locality: "Cupertino", state: "California", country: "US",
        roots: [("DigiCert Trusted Root G4", "DigiCert Inc")]
    )

    /// The chain errors a revocation check that couldn't reach the CA leaves (and nothing else):
    /// CERT_TRUST_REVOCATION_STATUS_UNKNOWN and CERT_TRUST_IS_OFFLINE_REVOCATION.
    static let offlineRevocationErrors: DWORD = 0x0000_0040 | 0x0100_0000

    /// Whether a chain's trust errors are only those of a revocation check that couldn't be done.
    static func onlyRevocationUnknown(_ errors: DWORD) -> Bool {
        errors != 0 && errors & ~self.offlineRevocationErrors == 0
    }

    /// szOID_PKIX_KP_CODE_SIGNING.
    static let codeSigningUsage = "1.3.6.1.5.5.7.3.3"

    /// WINTRUST_ACTION_GENERIC_VERIFY_V2 (SoftPub.h), a GUID initializer macro Swift can't import.
    static let genericVerifyV2 = GUID(
        Data1: 0x00AA_C56B, Data2: 0xCD44, Data3: 0x11D0,
        Data4: (0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE)
    )

    /// With this set to 1, a signature whose certificates' revocation can't be checked (because
    /// the revocation servers can't be reached) fails rather than passing with a warning.
    static let strictRevocationVariable = "SWIFTLY_REQUIRE_REVOCATION_CHECK"

    /// Files that passed `verify`, held open without write or delete sharing until `release`, so
    /// they can't be changed, renamed or deleted between the check and their use.
    private final class Pinned: @unchecked Sendable {
        static let shared = Pinned()
        let lock = NSLock()
        var handles: [String: HANDLE] = [:]
    }

    /// Verifies `file`'s Authenticode signature: trusted by the system, and from a signer that meets
    /// `requirement`. Keeps the file open so that it can't be replaced before it's used; call
    /// `release` when done with it.
    ///
    /// Revocation is checked online. If the revocation servers can't be reached (offline, or a proxy
    /// in the way), and that is the chain's only problem, the signature still passes, with a
    /// warning, as it does for Windows itself. That doesn't protect against an attacker on the
    /// network, who can block the revocation servers; SWIFTLY_REQUIRE_REVOCATION_CHECK=1 makes it
    /// an error. WinVerifyTrust reports it only once the signature and the file's hash are valid.
    /// The file is hashed once.
    static func verify(_ ctx: SwiftlyCoreContext, _ file: FilePath, signer requirement: Requirement) async throws {
        let (handle, openError) = file.string.withCString(encodedAs: UTF16.self) { path in
            let handle = CreateFileW(path, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ), nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            return (handle, GetLastError())
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw Win32.error("Opening \(file)", openError)
        }
        var keep = false
        defer {
            if !keep { CloseHandle(handle) }
        }

        let (status, signer) = self.check(file, handle)
        if status != 0 {
            // Accept a revocation check that couldn't be done only if that's the chain's only problem.
            guard self.isRevocationOffline(status), let signer, self.onlyRevocationUnknown(signer.chainErrors) else {
                throw SwiftlyError(message: "The toolchain installer's Authenticode signature isn't valid: \(self.describe(status)).")
            }
            if ProcessInfo.processInfo.environment[self.strictRevocationVariable] == "1" {
                throw SwiftlyError(message: "Couldn't check whether the toolchain installer's signing certificate was revoked (\(self.describe(status))), and \(self.strictRevocationVariable) is set.")
            }
            await ctx.message("Warning: couldn't check whether the toolchain installer's signing certificate was revoked (\(self.describe(status))).")
        }
        guard let signer else {
            throw SwiftlyError(message: "The toolchain installer's Authenticode signature has no signer.")
        }
        if let mismatch = requirement.mismatch(signer) {
            throw SwiftlyError(message: "The toolchain installer isn't swift.org's: \(mismatch)")
        }

        Pinned.shared.lock.withLock {
            if let old = Pinned.shared.handles.updateValue(handle, forKey: file.string) {
                CloseHandle(old)
            }
        }
        keep = true
    }

    /// Closes the file `verify` kept open.
    static func release(_ file: FilePath) {
        Pinned.shared.lock.withLock {
            if let handle = Pinned.shared.handles.removeValue(forKey: file.string) {
                CloseHandle(handle)
            }
        }
    }

    /// Runs WinVerifyTrust on the open file, checking revocation online, and reads the signer from
    /// its state, which it has whenever the signature itself was read.
    static func check(_ file: FilePath, _ handle: HANDLE) -> (status: Int32, signer: Signer?) {
        file.string.withCString(encodedAs: UTF16.self) { path in
            var fileInfo = WINTRUST_FILE_INFO()
            fileInfo.cbStruct = DWORD(MemoryLayout<WINTRUST_FILE_INFO>.size)
            fileInfo.pcwszFilePath = path
            fileInfo.hFile = handle

            return withUnsafeMutablePointer(to: &fileInfo) { fileInfoPointer in
                var data = WINTRUST_DATA()
                data.cbStruct = DWORD(MemoryLayout<WINTRUST_DATA>.size)
                data.dwUIChoice = DWORD(WTD_UI_NONE)
                data.dwUnionChoice = DWORD(WTD_CHOICE_FILE)
                data.pFile = fileInfoPointer
                data.dwStateAction = DWORD(WTD_STATEACTION_VERIFY)
                data.fdwRevocationChecks = DWORD(WTD_REVOKE_WHOLECHAIN)
                data.dwProvFlags = DWORD(WTD_REVOCATION_CHECK_CHAIN_EXCLUDE_ROOT)

                var action = self.genericVerifyV2
                // INVALID_HANDLE_VALUE as the window: no UI.
                let window = HWND(OpaquePointer(INVALID_HANDLE_VALUE))
                let status = WinVerifyTrust(window, &action, &data)
                defer {
                    data.dwStateAction = DWORD(WTD_STATEACTION_CLOSE)
                    _ = WinVerifyTrust(window, &action, &data)
                }
                return (status, self.signer(data.hWVTStateData))
            }
        }
    }

    /// The signing certificate and the root of its chain, from WinVerifyTrust's state.
    private static func signer(_ state: HANDLE?) -> Signer? {
        guard let provider = WTHelperProvDataFromStateData(state),
              let signer = WTHelperGetProvSignerFromChain(provider, 0, false, 0),
              signer.pointee.csCertChain > 0,
              let certificate = WTHelperGetProvCertFromChain(signer, 0)?.pointee.pCert,
              let root = WTHelperGetProvCertFromChain(signer, signer.pointee.csCertChain - 1)?.pointee.pCert
        else {
            return nil
        }
        return Signer(
            commonName: self.attribute("2.5.4.3", of: certificate),
            organization: self.attribute("2.5.4.10", of: certificate),
            locality: self.attribute("2.5.4.7", of: certificate),
            state: self.attribute("2.5.4.8", of: certificate),
            country: self.attribute("2.5.4.6", of: certificate),
            rootCommonName: self.attribute("2.5.4.3", of: root),
            rootOrganization: self.attribute("2.5.4.10", of: root),
            keyUsages: self.keyUsages(of: certificate),
            chainErrors: signer.pointee.pChainContext?.pointee.TrustStatus.dwErrorStatus ?? 0
        )
    }

    /// An attribute (by OID: CN, O, C) of a certificate's subject, parsed by CertGetNameString.
    private static func attribute(_ oid: String, of certificate: PCCERT_CONTEXT) -> String {
        oid.withCString { oidPointer in
            let type = DWORD(CERT_NAME_ATTR_TYPE)
            let parameter = UnsafeMutableRawPointer(mutating: oidPointer)
            let length = CertGetNameStringW(certificate, type, 0, parameter, nil, 0)
            guard length > 1 else { return "" }
            var buffer = [WCHAR](repeating: 0, count: Int(length))
            _ = CertGetNameStringW(certificate, type, 0, parameter, &buffer, length)
            return String(decodingCString: buffer, as: UTF16.self)
        }
    }

    /// The OIDs of a certificate's extended key usages.
    private static func keyUsages(of certificate: PCCERT_CONTEXT) -> [String] {
        var size: DWORD = 0
        guard CertGetEnhancedKeyUsage(certificate, 0, nil, &size), size > 0 else {
            return []
        }
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<CERT_ENHKEY_USAGE>.alignment)
        defer { buffer.deallocate() }
        let usage = buffer.bindMemory(to: CERT_ENHKEY_USAGE.self, capacity: 1)
        guard CertGetEnhancedKeyUsage(certificate, 0, usage, &size), let identifiers = usage.pointee.rgpszUsageIdentifier else {
            return []
        }
        return (0..<Int(usage.pointee.cUsageIdentifier)).compactMap { identifiers[$0].map { String(cString: $0) } }
    }

    /// Errors that mean revocation couldn't be checked, not that something was revoked.
    static func isRevocationOffline(_ code: Int32) -> Bool {
        [0x8009_2013, 0x8009_2012, 0x800B_010E].map { Int32(bitPattern: $0) }.contains(code)
    }

    /// The common WinVerifyTrust errors in words.
    static func describe(_ code: Int32) -> String {
        let hex = "0x" + String(UInt32(bitPattern: code), radix: 16, uppercase: true)
        let text: String? = switch UInt32(bitPattern: code) {
        case 0x800B_0100: "the file isn't signed"
        case 0x8009_6010: "the file was changed after it was signed"
        case 0x800B_0109: "the certificate chain ends in a root the system doesn't trust"
        case 0x800B_010C: "the signing certificate was revoked"
        case 0x800B_0101: "the signing certificate expired and the signature has no valid timestamp"
        case 0x800B_0111: "the signer is explicitly distrusted on this machine"
        case 0x800B_0004: "the signature isn't trusted for this purpose"
        case 0x800B_0003: "the file isn't of a type that can be signed"
        case 0x8009_2013, 0x800B_010E: "the revocation server is offline"
        case 0x8009_2012: "the revocation function couldn't check revocation"
        default: nil
        }
        return text.map { "\($0) (\(hex))" } ?? "error \(hex)"
    }
}
