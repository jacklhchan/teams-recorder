import XCTest
@testable import RecorderApp

final class VirtualMicPublisherTests: XCTestCase {
    func testStartUsesFixedBridgeContractAndBecomesReady() {
        let bridge = FakeVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge)

        publisher.start()

        XCTAssertEqual(bridge.startCalls, [
            .init(
                sharedMemoryName: "/lmr.virtual-mic.v1",
                capacityFrames: 96_000,
                sampleRate: 48_000
            )
        ])
        XCTAssertEqual(bridge.muteCalls, [false])
        XCTAssertEqual(publisher.state, .ready)
    }

    func testPublishDownmixesMicrophoneStereoWithoutIntermediateOverflow() {
        let bridge = FakeVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge, scratchCapacityFrames: 4)
        publisher.start()

        publisher.publishMicrophone(
            left: [1, 0, Float.greatestFiniteMagnitude],
            right: [0, 1, Float.greatestFiniteMagnitude]
        )

        XCTAssertEqual(bridge.writes.count, 1)
        XCTAssertEqual(bridge.writes[0][0], 0.5, accuracy: 0.000_001)
        XCTAssertEqual(bridge.writes[0][1], 0.5, accuracy: 0.000_001)
        XCTAssertTrue(bridge.writes[0][2].isFinite)
        XCTAssertEqual(
            bridge.writes[0][2],
            Float.greatestFiniteMagnitude,
            accuracy: Float.greatestFiniteMagnitude.ulp
        )
    }

    func testMuteIsSerializedAfterInFlightWriteAndFutureWritesAreSilent() {
        let bridge = BlockingVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge)
        publisher.start()

        let publishFinished = expectation(description: "publish finished")
        DispatchQueue.global().async {
            publisher.publishMicrophone(left: [0.8, -0.4], right: [0.2, 0.4])
            publishFinished.fulfill()
        }
        XCTAssertTrue(bridge.waitUntilWriteStarts(timeout: 1))

        let muteFinished = expectation(description: "mute finished")
        DispatchQueue.global().async {
            publisher.setMuted(true)
            muteFinished.fulfill()
        }
        XCTAssertFalse(bridge.waitUntilMuteIsCalled(timeout: 0.05))

        bridge.allowWriteToFinish()
        wait(for: [publishFinished, muteFinished], timeout: 1)
        XCTAssertEqual(
            bridge.events,
            [.muted(false), .writeStarted, .writeFinished, .muted(true)]
        )

        publisher.publishMicrophone(left: [0.7, -0.7], right: [0.3, 0.7])
        XCTAssertEqual(bridge.writes.last, [0, 0])
    }

    func testUnavailableBridgeFallsBackWithoutPublishingOrThrowing() {
        let bridge = FakeVirtualMicBridge()
        bridge.startResult = false
        let publisher = VirtualMicPublisher(bridge: bridge)

        publisher.start()
        publisher.setMuted(true)
        publisher.publishMicrophone(left: [1], right: [1])

        XCTAssertEqual(publisher.state, .unavailable)
        XCTAssertTrue(bridge.writes.isEmpty)
    }

    func testPublishUsesBoundedScratchBufferForLargeInput() {
        let bridge = FakeVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge, scratchCapacityFrames: 3)
        publisher.start()

        publisher.publishMicrophone(
            left: [1, 2, 3, 4, 5, 6, 7],
            right: [1, 2, 3, 4, 5, 6, 7]
        )

        XCTAssertEqual(bridge.writes, [[1, 2, 3], [4, 5, 6], [7]])
    }

    func testMismatchedChannelsAreIgnored() {
        let bridge = FakeVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge)
        publisher.start()

        publisher.publishMicrophone(left: [1, 2], right: [1])

        XCTAssertTrue(bridge.writes.isEmpty)
        XCTAssertEqual(publisher.state, .ready)
    }

    func testStopDisconnectsProducerAndReturnsToStopped() {
        let bridge = FakeVirtualMicBridge()
        let publisher = VirtualMicPublisher(bridge: bridge)
        publisher.start()

        publisher.stop()

        XCTAssertEqual(bridge.disconnectCallCount, 1)
        XCTAssertEqual(publisher.state, .stopped)
    }
}

private final class FakeVirtualMicBridge: VirtualMicBridgeAdapting {
    struct StartCall: Equatable {
        let sharedMemoryName: String
        let capacityFrames: UInt32
        let sampleRate: UInt32
    }

    var startResult = true
    private(set) var startCalls: [StartCall] = []
    private(set) var writes: [[Float]] = []
    private(set) var muteCalls: [Bool] = []
    private(set) var disconnectCallCount = 0

    func start(
        sharedMemoryName: String,
        capacityFrames: UInt32,
        sampleRate: UInt32
    ) -> Bool {
        startCalls.append(
            StartCall(
                sharedMemoryName: sharedMemoryName,
                capacityFrames: capacityFrames,
                sampleRate: sampleRate
            )
        )
        return startResult
    }

    func setMuted(_ muted: Bool) -> Bool {
        muteCalls.append(muted)
        return true
    }

    func write(_ frames: UnsafeBufferPointer<Float>, sampleRate: UInt32) -> Bool {
        writes.append(Array(frames))
        return true
    }

    func disconnect() {
        disconnectCallCount += 1
    }
}

private final class BlockingVirtualMicBridge: VirtualMicBridgeAdapting {
    enum Event: Equatable {
        case writeStarted
        case writeFinished
        case muted(Bool)
    }

    private let condition = NSCondition()
    private var writeMayFinish = false
    private var writeStarted = false
    private var muteCallCount = 0
    private var storedEvents: [Event] = []
    private var storedWrites: [[Float]] = []

    var events: [Event] {
        condition.withLock { storedEvents }
    }

    var writes: [[Float]] {
        condition.withLock { storedWrites }
    }

    func start(
        sharedMemoryName: String,
        capacityFrames: UInt32,
        sampleRate: UInt32
    ) -> Bool {
        true
    }

    func setMuted(_ muted: Bool) -> Bool {
        condition.lock()
        muteCallCount += 1
        storedEvents.append(.muted(muted))
        condition.broadcast()
        condition.unlock()
        return true
    }

    func write(_ frames: UnsafeBufferPointer<Float>, sampleRate: UInt32) -> Bool {
        condition.lock()
        writeStarted = true
        storedEvents.append(.writeStarted)
        storedWrites.append(Array(frames))
        condition.broadcast()
        while !writeMayFinish {
            condition.wait()
        }
        storedEvents.append(.writeFinished)
        condition.unlock()
        return true
    }

    func disconnect() {}

    func waitUntilWriteStarts(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { writeStarted }
    }

    func waitUntilMuteIsCalled(timeout: TimeInterval) -> Bool {
        wait(timeout: timeout) { muteCallCount > 1 }
    }

    func allowWriteToFinish() {
        condition.lock()
        writeMayFinish = true
        condition.broadcast()
        condition.unlock()
    }

    private func wait(timeout: TimeInterval, predicate: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if !condition.wait(until: deadline) {
                return predicate()
            }
        }
        return true
    }
}

private extension NSCondition {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
