import Foundation
import VirtualMicBridge

enum VirtualMicPublisherState: Equatable {
    case stopped
    case ready
    case unavailable
}

protocol VirtualMicPublishing: AnyObject {
    var state: VirtualMicPublisherState { get }

    func start()
    func publishMicrophone(left: [Float], right: [Float])
    func setMuted(_ muted: Bool)
    func stop()
}

protocol VirtualMicBridgeAdapting: AnyObject {
    func start(
        sharedMemoryName: String,
        capacityFrames: UInt32,
        sampleRate: UInt32
    ) -> Bool
    func setMuted(_ muted: Bool) -> Bool
    func write(_ frames: UnsafeBufferPointer<Float>, sampleRate: UInt32) -> Bool
    func disconnect()
}

final class VirtualMicPublisher: VirtualMicPublishing {
    static let sharedMemoryName = "/lmr.virtual-mic.v1"
    static let sampleRate: UInt32 = 48_000
    static let bridgeCapacityFrames: UInt32 = 96_000

    private let bridge: VirtualMicBridgeAdapting
    private let lock = NSLock()
    private var scratch: [Float]
    private var isMuted = false
    private var currentState = VirtualMicPublisherState.stopped

    init(
        bridge: VirtualMicBridgeAdapting = CBridgeVirtualMicAdapter(),
        scratchCapacityFrames: Int = 4_096
    ) {
        self.bridge = bridge
        scratch = Array(
            repeating: 0,
            count: max(1, scratchCapacityFrames)
        )
    }

    var state: VirtualMicPublisherState {
        lock.withLock { currentState }
    }

    func start() {
        lock.withLock {
            guard currentState != .ready else { return }
            let started = bridge.start(
                sharedMemoryName: Self.sharedMemoryName,
                capacityFrames: Self.bridgeCapacityFrames,
                sampleRate: Self.sampleRate
            )
            guard started else {
                currentState = .unavailable
                return
            }

            if !bridge.setMuted(isMuted) {
                currentState = .unavailable
                return
            }
            currentState = .ready
        }
    }

    func publishMicrophone(left: [Float], right: [Float]) {
        lock.withLock {
            guard currentState == .ready,
                  left.count == right.count,
                  !left.isEmpty else {
                return
            }

            var offset = 0
            while offset < left.count {
                let frameCount = min(scratch.count, left.count - offset)
                if isMuted {
                    for index in 0..<frameCount {
                        scratch[index] = 0
                    }
                } else {
                    for index in 0..<frameCount {
                        let sourceIndex = offset + index
                        scratch[index] = (left[sourceIndex] * 0.5) + (right[sourceIndex] * 0.5)
                    }
                }

                let didWrite = scratch.withUnsafeBufferPointer { buffer in
                    let frames = UnsafeBufferPointer(
                        start: buffer.baseAddress,
                        count: frameCount
                    )
                    return bridge.write(frames, sampleRate: Self.sampleRate)
                }
                guard didWrite else {
                    currentState = .unavailable
                    return
                }
                offset += frameCount
            }
        }
    }

    func setMuted(_ muted: Bool) {
        lock.withLock {
            isMuted = muted
            guard currentState == .ready else { return }
            if !bridge.setMuted(muted) {
                currentState = .unavailable
            }
        }
    }

    func stop() {
        lock.withLock {
            guard currentState != .stopped else { return }
            bridge.disconnect()
            currentState = .stopped
        }
    }
}

private final class CBridgeVirtualMicAdapter: VirtualMicBridgeAdapting {
    private var producer: OpaquePointer?

    func start(
        sharedMemoryName: String,
        capacityFrames: UInt32,
        sampleRate: UInt32
    ) -> Bool {
        if producer != nil {
            return true
        }

        var newProducer: OpaquePointer?
        let status = sharedMemoryName.withCString { name in
            VMProducerCreate(
                name,
                capacityFrames,
                sampleRate,
                &newProducer
            )
        }
        guard status == VM_STATUS_OK, newProducer != nil else {
            return false
        }
        producer = newProducer
        return true
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard let producer else { return false }
        return VMProducerSetMuted(producer, muted) == VM_STATUS_OK
    }

    func write(_ frames: UnsafeBufferPointer<Float>, sampleRate: UInt32) -> Bool {
        guard let producer else { return false }
        var framesWritten: UInt32 = 0
        let status = VMProducerWriteFrames(
            producer,
            frames.baseAddress,
            UInt32(frames.count),
            sampleRate,
            &framesWritten
        )
        return status == VM_STATUS_OK && framesWritten == frames.count
    }

    func disconnect() {
        guard let producer else { return }
        _ = VMProducerDisconnect(producer)
        VMProducerDestroy(producer)
        self.producer = nil
    }

    deinit {
        disconnect()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
