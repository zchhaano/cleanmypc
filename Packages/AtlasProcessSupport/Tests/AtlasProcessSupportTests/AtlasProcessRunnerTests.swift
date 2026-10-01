import XCTest
@testable import AtlasProcessSupport

final class AtlasProcessRunnerTests: XCTestCase {
    func testInstantExitAndInput() async throws {
        let result = try await AtlasProcessRunner().run(.init(executableURL: URL(fileURLWithPath: "/bin/cat"), stdin: Data("input".utf8)))
        XCTAssertEqual(result.exitStatus, 0)
        XCTAssertEqual(result.stdout, Data("input".utf8))
    }
    func testBothPipesDrainBeforeExit() async throws {
        let r = try await shell("for i in {1..12000}; do printf abcdefghijklmnop; printf abcdefghijklmnop >&2; done")
        XCTAssertEqual(r.stdout.count, 192000); XCTAssertEqual(r.stderr.count, 192000)
    }
    func testNoInputConsumptionAndIgnoredTERMHaveBoundedTimeout() async {
        let start = ContinuousClock.now
        do { _ = try await shell("trap '' TERM; sleep 10", stdin: Data(repeating: 65, count: 2_000_000), timeout: .milliseconds(100)); XCTFail("timeout") }
        catch { XCTAssertEqual(error as? AtlasProcessError, .timedOut) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
    }
    func testDescendantHoldingPipeDoesNotHoldCaller() async {
        do { _ = try await shell("sleep 10 & exit 0", timeout: .milliseconds(100)); XCTFail("timeout") }
        catch { XCTAssertEqual(error as? AtlasProcessError, .timedOut) }
    }
    func testOutputLimitsFailWithoutReturningTruncatedSuccess() async {
        do { _ = try await shell("printf 123456789", stdoutLimit: 8); XCTFail("limit") }
        catch { XCTAssertEqual(error as? AtlasProcessError, .outputLimitExceeded("stdout")) }
        do { _ = try await shell("printf 123456789 >&2", stderrLimit: 8); XCTFail("limit") }
        catch { XCTAssertEqual(error as? AtlasProcessError, .outputLimitExceeded("stderr")) }
    }
    func testCancellationStopsOwnedGroup() async {
        let task = Task { try await self.shell("trap '' TERM; sleep 10") }
        try? await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("cancel") }
        catch { XCTAssertEqual(error as? AtlasProcessError, .cancelled) }
    }
    private func shell(_ script: String, stdin: Data = Data(), timeout: Duration = .seconds(2), stdoutLimit: Int = 8*1024*1024, stderrLimit: Int = 1024*1024) async throws -> AtlasProcessResult {
        try await AtlasProcessRunner().run(.init(executableURL: URL(fileURLWithPath: "/bin/bash"), arguments: ["-c", script], stdin: stdin, timeout: timeout, terminationGrace: .milliseconds(50), stdoutLimit: stdoutLimit, stderrLimit: stderrLimit))
    }
}
