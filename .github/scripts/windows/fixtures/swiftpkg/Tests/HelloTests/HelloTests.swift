import XCTest
@testable import HelloLib

final class HelloTests: XCTestCase {
  func testAdd() { XCTAssertEqual(HelloLib.add(2, 3), 5) }
  func testGreeting() { XCTAssertTrue(greeting("x").hasPrefix("Hello, x")) }
}
