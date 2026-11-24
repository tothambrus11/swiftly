import SwiftlyCore

/// Makes swiftly available in new sessions through the user's environment in the registry
/// (HKCU\Environment), which is what new Windows sessions start with. Not implemented yet: until
/// then, `swiftly init` leaves the environment alone.
struct UserEnvironment: SessionEnvironment {
    var noModifyProfileHelp: String {
        "Do not add swiftly's bin directory to the user's Path."
    }

    func initIntroduction(_: SwiftlyCoreContext) -> String {
        ""
    }

    func setUp(_: SwiftlyCoreContext, modifyPath _: Bool) async throws {}

    func currentSessionInstructions(_: SwiftlyCoreContext) -> String? {
        nil
    }

    func tearDown(_: SwiftlyCoreContext, verbose _: Bool) async throws {}
}
