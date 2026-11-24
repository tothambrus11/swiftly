import CWinTrust
import SwiftlyCore
import SystemPackage
import WinSDK

/// Checks Authenticode signatures, which is how swift.org signs its Windows installers.
enum Authenticode {
    /// Throws unless `file` has a valid Authenticode signature, trusted by the system, from `signer`.
    static func verify(_ file: FilePath, signer expected: String) throws {
        var signer = [WCHAR](repeating: 0, count: 256)
        let status = file.string.withCString(encodedAs: UTF16.self) {
            swiftly_verify_authenticode($0, &signer, UInt32(signer.count))
        }
        guard status == 0 else {
            let code = String(UInt32(bitPattern: Int32(truncatingIfNeeded: status)), radix: 16, uppercase: true)
            throw SwiftlyError(message: """
            The toolchain installer's Authenticode signature isn't valid (WinVerifyTrust error 0x\(code)). \
            You can skip the check with `--no-verify`, at your own risk.
            """)
        }
        let actual = String(decodingCString: signer, as: UTF16.self)
        guard actual == expected else {
            throw SwiftlyError(message: "The toolchain installer is signed by \"\(actual)\", not by \"\(expected)\".")
        }
    }
}
