import XCTest
import AtlasApplication
import AtlasDomain
import AtlasProtocol
@testable import AtlasInfrastructure
final class AtlasXPCCompletionTests: XCTestCase {
    func testOnlyFirstCompletionWinsIncludingBeforeRegistration() async throws {
        let completion = AtlasXPCRequestCompletion()
        XCTAssertTrue(completion.finish(.success(Data("first".utf8))))
        XCTAssertFalse(completion.finish(.failure(AtlasXPCTransportError.invalidResponse)))
        let result = try await withCheckedThrowingContinuation { completion.install($0) }
        XCTAssertEqual(result, Data("first".utf8))
    }
    func testMutationsNeverRetryOrFallback() async {
        for command in [AtlasCommand.executePlan(planID: UUID()), .restoreItems(taskID: UUID(), itemIDs: [UUID()]), .settingsSet(AtlasScaffoldWorkspace.state().settings)] {
            let count = Counter()
            let client = AtlasXPCWorkerClient(requestConfiguration: .init(timeout: 0.1, retryCount: 3, retryDelay: 0), requestExecutor: { _ in
                await count.increment(); throw AtlasXPCTransportError.connectionUnavailable("lost reply")
            })
            do { _ = try await client.submit(.init(command: command)); XCTFail("lost result") } catch {}
            let actual = await count.value
            XCTAssertEqual(actual, 1)
        }
    }
    func testInvalidTimeoutNeverStartsTransport() async {
        let count = Counter()
        let client = AtlasXPCWorkerClient(requestConfiguration: .init(timeout: 0, retryCount: 0), requestExecutor: { _ in
            await count.increment(); try await Task.sleep(for: .seconds(5)); return Data()
        })
        let task = Task { try await client.submit(.init(command: .settingsGet)) }
        try? await Task.sleep(for: .milliseconds(30)); task.cancel()
        do { _ = try await task.value; XCTFail("invalid timeout") } catch {}
        let actual = await count.value
        XCTAssertEqual(actual, 0)
    }
    func testLateReplyIsIgnoredAndCleanupRunsOnce() async throws {
        let completion = AtlasXPCRequestCompletion(), counter = CleanupCounter()
        completion.onFinish { counter.increment() }
        XCTAssertTrue(completion.finish(.failure(AtlasXPCTransportError.timedOut(0.1))))
        XCTAssertFalse(completion.finish(.success(Data())))
        completion.onFinish { counter.increment() }
        XCTAssertEqual(counter.value, 2) // Each registered cleanup executes once, including late registration.
    }
    func testNeverReplyCallbackTimesOutAndCancellationCompletesOnce() async throws {
        let client = AtlasXPCWorkerClient(requestConfiguration: .init(timeout: 0.05, retryCount: 0), callbackExecutor: { _, _ in { } })
        let start = ContinuousClock.now
        do { _ = try await client.submit(.init(command: .settingsGet)); XCTFail("timeout") } catch {}
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let task = Task { try await client.submit(.init(command: .settingsGet)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("cancel") } catch {}
    }
}
private actor Counter { var value = 0; func increment() { value += 1 } }

private final class CleanupCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
}
