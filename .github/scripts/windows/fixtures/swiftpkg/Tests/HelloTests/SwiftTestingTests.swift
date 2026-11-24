#if canImport(Testing)
import Testing
@testable import HelloLib

@Test func addWithSwiftTesting() { #expect(add(40, 2) == 42) }
#endif
