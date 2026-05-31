import XCTest
@testable import MyTimer

final class MyTimerTests: XCTestCase {
    func testCreateVersionEcho() throws {
        let node = try TimerNode(name: "ios-demo")

        XCTAssertEqual(try node.version(), "nim-timer v0.1.0")

        let r = try node.echo("hello from Swift", delayMs: 2)
        XCTAssertEqual(r.echoed, "hello from Swift")
        XCTAssertEqual(r.timerName, "ios-demo") // proves the lib's own state round-tripped
    }

    func testManyEchoes() throws {
        let node = try TimerNode(name: "loop")
        for i in 0..<200 {
            let r = try node.echo("m\(i)")
            XCTAssertEqual(r.echoed, "m\(i)")
        }
    }
}
