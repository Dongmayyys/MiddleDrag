import CoreFoundation
import XCTest

@testable import MiddleDragCore

/// Deterministic lifecycle tests. Fake CF objects model framework device owners;
/// no private hardware API is invoked except by the explicitly opt-in smoke test.
@unsafe final class DeviceMonitorTests: XCTestCase {
    func testEnumeratedDeviceLivesUntilStopReturns() {
        let framework = FakeMultitouchFramework()
        let monitor = unsafe DeviceMonitor(api: framework.api)
        defer { unsafe monitor.stop() }

        unsafe XCTAssertTrue(monitor.start())
        XCTAssertNotNil(framework.device, "The array must retain its borrowed device pointers")
        framework.onUnregister = { XCTAssertNotNil(framework.device) }
        framework.onStop = { XCTAssertNotNil(framework.device) }

        unsafe monitor.stop()
        XCTAssertEqual(framework.events, ["register", "start", "unregister", "isRunning", "stop"])
        XCTAssertNil(framework.device, "The owner should be released after teardown")
        XCTAssertEqual(framework.defaultCreations, 0, "Do not open another handle for the same trackpad")
    }

    func testDefaultDeviceIsOwnedWhenEnumerationFails() {
        let framework = FakeMultitouchFramework()
        framework.listAvailable = false
        let monitor = unsafe DeviceMonitor(api: framework.api)
        defer { unsafe monitor.stop() }

        unsafe XCTAssertTrue(monitor.start())
        XCTAssertEqual(framework.defaultCreations, 1)
        XCTAssertNotNil(framework.device)
        framework.onStop = { XCTAssertNotNil(framework.device) }
        unsafe monitor.stop()
        XCTAssertNil(framework.device)
    }

    func testEmptyEnumerationUsesDefaultDevice() {
        let framework = FakeMultitouchFramework()
        framework.emptyList = true
        let monitor = unsafe DeviceMonitor(api: framework.api)
        defer { unsafe monitor.stop() }

        unsafe XCTAssertTrue(monitor.start())
        XCTAssertEqual(framework.defaultCreations, 1)
    }

    func testDuplicateEntriesAreRegisteredAndStoppedOnce() {
        let framework = FakeMultitouchFramework()
        framework.duplicateEntry = true
        let monitor = unsafe DeviceMonitor(api: framework.api)
        unsafe XCTAssertTrue(monitor.start())
        unsafe monitor.stop()
        unsafe monitor.stop()
        XCTAssertEqual(framework.events, ["register", "start", "unregister", "isRunning", "stop"])
        XCTAssertNil(framework.device)
    }

    func testAlreadyStoppedDeviceIsNotStoppedAgain() {
        let framework = FakeMultitouchFramework()
        framework.running = false
        let monitor = unsafe DeviceMonitor(api: framework.api)
        unsafe XCTAssertTrue(monitor.start())
        unsafe monitor.stop()
        XCTAssertEqual(framework.events, ["register", "start", "unregister", "isRunning"])
        XCTAssertNil(framework.device)
    }

    func testFailedStartDoesNotReserveCallbackContext() {
        let missing = FakeMultitouchFramework()
        missing.listAvailable = false
        missing.defaultAvailable = false
        let first = unsafe DeviceMonitor(api: missing.api)
        unsafe XCTAssertFalse(first.start())

        let available = FakeMultitouchFramework()
        let second = unsafe DeviceMonitor(api: available.api)
        defer { unsafe second.stop() }
        unsafe XCTAssertTrue(second.start())
        // Stopping an inactive instance must not disable the active one.
        unsafe first.stop()
        let delegate = MockDeviceMonitorDelegate()
        unsafe second.delegate = delegate
        unsafe available.emitTouch()
        XCTAssertTrue(delegate.didReceiveTouchesCalled)
    }

    func testOnlyOneActiveMonitorCanOwnCallbacks() {
        let firstFramework = FakeMultitouchFramework()
        let secondFramework = FakeMultitouchFramework()
        let first = unsafe DeviceMonitor(api: firstFramework.api)
        let second = unsafe DeviceMonitor(api: secondFramework.api)
        defer { unsafe first.stop(); unsafe second.stop() }

        unsafe XCTAssertTrue(first.start())
        unsafe XCTAssertFalse(second.start())
        XCTAssertTrue(secondFramework.events.isEmpty)
        unsafe second.stop()
        let delegate = MockDeviceMonitorDelegate()
        unsafe first.delegate = delegate
        unsafe firstFramework.emitTouch()
        XCTAssertTrue(delegate.didReceiveTouchesCalled)

        unsafe first.stop()
        unsafe XCTAssertTrue(second.start())
        delegate.didReceiveTouchesCalled = false
        unsafe second.delegate = delegate
        unsafe secondFramework.emitTouch()
        XCTAssertTrue(delegate.didReceiveTouchesCalled)
    }

    func testCallbacksAreDisabledBeforeUnregistering() {
        let framework = FakeMultitouchFramework()
        let monitor = unsafe DeviceMonitor(api: framework.api)
        let delegate = MockDeviceMonitorDelegate()
        unsafe monitor.delegate = delegate
        unsafe XCTAssertTrue(monitor.start())
        unsafe framework.emitTouch()
        XCTAssertTrue(delegate.didReceiveTouchesCalled)
        delegate.didReceiveTouchesCalled = false

        framework.onUnregister = { unsafe framework.emitTouch() }
        framework.onStop = { unsafe framework.emitTouch() }
        unsafe monitor.stop()
        XCTAssertFalse(delegate.didReceiveTouchesCalled)
    }

    func testStopAllowsFrameworkWorkerToFinishCallback() {
        let framework = FakeMultitouchFramework()
        let monitor = unsafe DeviceMonitor(api: framework.api)
        unsafe XCTAssertTrue(monitor.start())
        let callback = unsafe framework.callback!
        let finished = DispatchSemaphore(value: 0)
        framework.onStop = {
            DispatchQueue.global().async {
                _ = unsafe callback(nil, nil, 0, 0, 0)
                finished.signal()
            }
            // Models MTDeviceStop waiting for its worker. Holding gCallbackLock
            // across stop would prevent this callback from returning.
            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        }
        unsafe monitor.stop()
    }

    func testStartWaitsForPreviousDeviceStopToFinish() {
        let previousFramework = FakeMultitouchFramework()
        let nextFramework = FakeMultitouchFramework()
        let previous = unsafe DeviceMonitor(api: previousFramework.api)
        let next = unsafe DeviceMonitor(api: nextFramework.api)
        defer { unsafe previous.stop(); unsafe next.stop() }
        unsafe XCTAssertTrue(previous.start())

        let enteredStop = DispatchSemaphore(value: 0)
        let releaseStop = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let attemptedStart = DispatchSemaphore(value: 0)
        let started = DispatchSemaphore(value: 0)
        previousFramework.onStop = {
            enteredStop.signal()
            XCTAssertEqual(releaseStop.wait(timeout: .now() + 3), .success)
            XCTAssertNotNil(previousFramework.device)
        }
        DispatchQueue.global().async {
            unsafe previous.stop()
            stopped.signal()
        }
        XCTAssertEqual(enteredStop.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            attemptedStart.signal()
            unsafe XCTAssertTrue(next.start())
            started.signal()
        }
        XCTAssertEqual(attemptedStart.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 0.05), .timedOut)
        releaseStop.signal()
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        XCTAssertNil(previousFramework.device)
        XCTAssertNotNil(nextFramework.device)
    }

    func testRepeatedRestartReacquiresCallbackContextWithoutLeaks() {
        let framework = FakeMultitouchFramework()
        let monitor = unsafe DeviceMonitor(api: framework.api)
        let delegate = MockDeviceMonitorDelegate()
        unsafe monitor.delegate = delegate
        for _ in 0..<50 {
            unsafe XCTAssertTrue(monitor.start())
            unsafe XCTAssertTrue(monitor.start())
            delegate.didReceiveTouchesCalled = false
            unsafe framework.emitTouch()
            XCTAssertTrue(delegate.didReceiveTouchesCalled)
            unsafe monitor.stop()
            XCTAssertNil(framework.device)
        }
        XCTAssertEqual(framework.events.filter { $0 == "start" }.count, 50)
        XCTAssertEqual(framework.events.filter { $0 == "stop" }.count, 50)
    }

    func testUnstartedAndStoppedMonitorsAreReleased() {
        let framework = FakeMultitouchFramework()
        weak var reference: DeviceMonitor?
        autoreleasepool {
            let monitor = unsafe DeviceMonitor(api: framework.api)
            unsafe reference = monitor
        }
        unsafe XCTAssertNil(reference)
        autoreleasepool {
            let monitor = unsafe DeviceMonitor(api: framework.api)
            unsafe reference = monitor
            unsafe XCTAssertTrue(monitor.start())
            unsafe monitor.stop()
        }
        unsafe XCTAssertNil(reference)
    }

    func testRealHardwareStartStop() throws {
        guard ProcessInfo.processInfo.environment["RUN_UNSAFE_MULTITOUCH_TESTS"] == "1" else {
            throw XCTSkip("Requires a physical trackpad; opt in with RUN_UNSAFE_MULTITOUCH_TESTS=1")
        }
        let monitor = unsafe DeviceMonitor()
        defer { unsafe monitor.stop() }
        guard unsafe monitor.start() else { throw XCTSkip("No multitouch device attached") }
        unsafe monitor.stop()
        unsafe XCTAssertTrue(monitor.start())
    }
}

private final class FakeMultitouchFramework: @unchecked Sendable {
    var listAvailable = true
    var emptyList = false
    var duplicateEntry = false
    var defaultAvailable = true
    var running = true
    weak var device: NSObject?
    var defaultCreations = 0
    var events: [String] = []
    var callback: MTContactCallbackFunction?
    var onUnregister: (() -> Void)?
    var onStop: (() -> Void)?

    var api: MultitouchDeviceAPI {
        unsafe MultitouchDeviceAPI(
            createList: {
                guard self.listAvailable else { return nil }
                guard !self.emptyList else { return [] as CFArray }
                let object = NSObject()
                self.device = object
                return (self.duplicateEntry ? [object, object] : [object]) as CFArray
            },
            createDefault: {
                self.defaultCreations += 1
                guard self.defaultAvailable else { return nil }
                let object = NSObject()
                self.device = object
                return object
            },
            register: { _, callback in
                unsafe self.callback = callback
                self.events.append("register")
            },
            unregister: { _, _ in
                self.events.append("unregister")
                self.onUnregister?()
            },
            start: { _ in self.events.append("start") },
            isRunning: { _ in
                self.events.append("isRunning")
                XCTAssertNotNil(self.device)
                return self.running
            },
            stop: { _ in
                self.onStop?()
                self.events.append("stop")
            }
        )
    }

    func emitTouch() {
        var byte: UInt8 = 0
        withUnsafeMutablePointer(to: &byte) { touches in
            _ = unsafe callback?(nil, UnsafeMutableRawPointer(touches), 3, 42, 0)
        }
    }
}

class MockDeviceMonitorDelegate: DeviceMonitorDelegate {
    var didReceiveTouchesCalled = false
    var receivedTouchCount: Int32 = 0
    var receivedTimestamp: Double = 0

    func deviceMonitor(
        _ monitor: DeviceMonitor,
        didReceiveTouches touches: UnsafeMutableRawPointer,
        count: Int32,
        timestamp: Double
    ) {
        didReceiveTouchesCalled = true
        receivedTouchCount = count
        receivedTimestamp = timestamp
    }
}
