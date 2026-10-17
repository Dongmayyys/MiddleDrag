import CoreFoundation
import Foundation
import os

// MARK: - Debug Touch Counter (Debug builds only)

#if DEBUG
    nonisolated(unsafe) private var touchCount = 0
#endif

// MARK: - Global Callback Storage

// The active monitor owns the C callback context until stop(). A callback copies
// this reference under gCallbackLock, so an in-flight call keeps its context alive.
@unsafe nonisolated(unsafe) private var gDeviceMonitor: DeviceMonitor?

/// Flag to control whether callbacks should be processed.
/// Access to this flag must be synchronized using `gCallbackLock`; it is *not* atomic by itself.
/// This is checked FIRST in the callback, while holding the lock, before accessing gDeviceMonitor,
/// to prevent race conditions during teardown where gDeviceMonitor might be nil or pointing to
/// a deallocated object.
@unsafe nonisolated(unsafe) private var gCallbackEnabled: Bool = false

/// Lock to synchronize callback processing with stop/deinit operations.
/// Uses os_unfair_lock for minimal overhead in high-frequency C callbacks.
/// This is Apple's recommended lock for performance-critical short critical sections.
/// Note: os_unfair_lock must not be moved in memory after initialization - safe here as a global.
@unsafe nonisolated(unsafe) private var gCallbackLock = os_unfair_lock()

// MARK: - C Callback Function

@unsafe private let deviceContactCallback: MTContactCallbackFunction = {
    device, touches, numTouches, timestamp, frame in

    // CRITICAL: Check the enabled flag FIRST, before accessing gDeviceMonitor.
    // This prevents accessing a nil or dangling pointer during teardown.
    // We use the lock to synchronize with stop() which sets the flag to false.
    unsafe os_unfair_lock_lock(&gCallbackLock)
    guard unsafe gCallbackEnabled else {
        unsafe os_unfair_lock_unlock(&gCallbackLock)
        return 0
    }
    // Copy the monitor reference while holding the lock
    guard let monitor = unsafe gDeviceMonitor,
          let touches = unsafe touches
    else {
        unsafe os_unfair_lock_unlock(&gCallbackLock)
        return 0
    }
    unsafe os_unfair_lock_unlock(&gCallbackLock)

    // Additional safety check: Verify the monitor instance is still valid and running.
    unsafe monitor.stateLock.lock()
    let monitorIsRunning = unsafe monitor.isRunning
    unsafe monitor.stateLock.unlock()

    guard monitorIsRunning else { return 0 }

    #if DEBUG
        unsafe touchCount += 1
        // Log sparingly to avoid performance impact
        if unsafe touchCount <= 5 || touchCount % 500 == 0 {
            Log.debug(unsafe "Touch callback #\(touchCount): \(numTouches) touches", category: .device)
        }
    #endif

    let shouldConsume = unsafe monitor.handleContact(
        device: device,
        touches: touches,
        count: numTouches,
        timestamp: timestamp
    )

    // Return 1 to attempt to suppress system gesture handling for 3+ fingers
    return shouldConsume ? 1 : 0
}

// MARK: - DeviceMonitor

/// Injectable boundary for testing device ownership and teardown without hardware.
@unsafe struct MultitouchDeviceAPI {
    var createList: () -> CFArray?
    var createDefault: () -> CFTypeRef?
    var register: (MTDeviceRef, MTContactCallbackFunction) -> Void
    var unregister: (MTDeviceRef, MTContactCallbackFunction) -> Void
    var start: (MTDeviceRef) -> Void
    var isRunning: (MTDeviceRef) -> Bool
    var stop: (MTDeviceRef) -> Void

    static var live: Self {
        unsafe Self(
            createList: { MTDeviceCreateList() },
            createDefault: {
                guard let pointer = unsafe MTDeviceCreateDefault() else { return nil }
                // The raw-pointer binding does not apply ARC's Core Foundation
                // Create rule. Adopt the reference returned by CreateDefault.
                return unsafe Unmanaged<CFTypeRef>.fromOpaque(pointer).takeRetainedValue()
            },
            register: { unsafe MTRegisterContactFrameCallback($0, $1) },
            unregister: { unsafe MTUnregisterContactFrameCallback($0, $1) },
            start: { unsafe MTDeviceStart($0, 0) },
            isRunning: { unsafe MTDeviceIsRunning($0) },
            stop: { unsafe MTDeviceStop($0) }
        )
    }
}

/// Monitors multitouch devices and reports touch events
///
/// Note: This class uses unsafe pointer types (UnsafeMutableRawPointer) to interface
/// with the private MultitouchSupport C framework. The unsafe usage is intentional
/// and necessary for low-level touch device access. Properties are marked with
/// `nonisolated(unsafe)` to indicate they store unsafe pointers that are managed
/// outside of Swift's memory safety system.
@unsafe @preconcurrency
class DeviceMonitor: TouchDeviceProviding {

    // MARK: - Properties

    /// Delegate to receive touch events
    weak var delegate: DeviceMonitorDelegate?

    private let api: MultitouchDeviceAPI
    // CFArrayGetValueAtIndex returns borrowed pointers. Keep their owning array
    // alive until every MTDeviceStop has returned, including across sleep/wake.
    private var deviceListOwner: CFArray?
    private var defaultDeviceOwner: CFTypeRef?
    nonisolated(unsafe) private var registeredDevices: Set<UnsafeMutableRawPointer> = unsafe []
    fileprivate var isRunning = false

    /// Lock to protect concurrent access to device state during stop/start operations
    fileprivate let stateLock = NSLock()

    /// Global lifecycle lock to serialize start/stop across instances.
    /// This prevents concurrent MTDeviceStart/MTDeviceStop calls, which can crash
    /// the MultitouchSupport framework under parallel test execution.
    private static let lifecycleLock = NSLock()

    // MARK: - Lifecycle

    init(api: MultitouchDeviceAPI = unsafe .live) {
        unsafe self.api = api
    }

    deinit {
        unsafe stop()
    }

    // MARK: - Public Interface

    /// Start monitoring enumerated devices, falling back to the default device.
    @unsafe @discardableResult
    func start() -> Bool {
        unsafe DeviceMonitor.lifecycleLock.lock()
        defer { unsafe DeviceMonitor.lifecycleLock.unlock() }

        unsafe stateLock.lock()
        defer { unsafe stateLock.unlock() }

        guard unsafe !isRunning else { return true }

        unsafe os_unfair_lock_lock(&gCallbackLock)
        guard unsafe gDeviceMonitor == nil else {
            unsafe os_unfair_lock_unlock(&gCallbackLock)
            Log.warning("Another DeviceMonitor is already active", category: .device)
            return false
        }
        unsafe gDeviceMonitor = self
        unsafe gCallbackEnabled = false
        unsafe os_unfair_lock_unlock(&gCallbackLock)

        Log.info("DeviceMonitor starting...", category: .device)

        unsafe deviceListOwner = api.createList()
        if let deviceList = unsafe deviceListOwner {
            let count = CFArrayGetCount(deviceList)
            Log.info("Found \(count) multitouch device(s)", category: .device)

            for i in 0..<count {
                let devicePtr = unsafe CFArrayGetValueAtIndex(deviceList, i)
                if let dev = unsafe devicePtr {
                    let deviceRef = unsafe UnsafeMutableRawPointer(mutating: dev)
                    if unsafe registeredDevices.insert(deviceRef).inserted {
                        unsafe api.register(deviceRef, deviceContactCallback)
                        unsafe api.start(deviceRef)
                    }
                }
            }
        } else {
            Log.warning("MTDeviceCreateList returned nil, trying default device", category: .device)
        }

        // CreateDefault can return a different handle for the same physical
        // trackpad. Only use it if enumeration did not supply any devices.
        if unsafe registeredDevices.isEmpty, let owner = unsafe api.createDefault() {
            unsafe defaultDeviceOwner = owner
            let defaultDevice = unsafe Unmanaged.passUnretained(owner).toOpaque()
            unsafe registeredDevices.insert(defaultDevice)
            unsafe api.register(defaultDevice, deviceContactCallback)
            unsafe api.start(defaultDevice)
        }

        guard unsafe !registeredDevices.isEmpty else {
            unsafe deviceListOwner = nil
            unsafe os_unfair_lock_lock(&gCallbackLock)
            unsafe gDeviceMonitor = nil
            unsafe os_unfair_lock_unlock(&gCallbackLock)
            Log.warning(
                "No multitouch device found. MiddleDrag requires a built-in trackpad or Magic Trackpad.",
                category: .device)
            return false
        }

        Log.info(unsafe "DeviceMonitor started with \(registeredDevices.count) device(s)", category: .device)

        unsafe isRunning = true

        // Enable callbacks AFTER all devices are registered.
        // This ensures gDeviceMonitor is fully set up before callbacks can access it.
        unsafe os_unfair_lock_lock(&gCallbackLock)
        unsafe gCallbackEnabled = true
        unsafe os_unfair_lock_unlock(&gCallbackLock)

        return true
    }

    /// Stop monitoring
    /// Safe to call even if start() was never called
    @unsafe func stop() {
        unsafe DeviceMonitor.lifecycleLock.lock()
        defer { unsafe DeviceMonitor.lifecycleLock.unlock() }
        unsafe stateLock.lock()

        guard unsafe isRunning else {
            unsafe stateLock.unlock()
            return
        }

        // Mark as not running FIRST to prevent callbacks from processing new events
        unsafe isRunning = false

        let devicesToStop = unsafe registeredDevices
        let owners = unsafe (deviceListOwner, defaultDeviceOwner)
        unsafe registeredDevices.removeAll()
        unsafe deviceListOwner = nil
        unsafe defaultDeviceOwner = nil

        unsafe stateLock.unlock()

        unsafe os_unfair_lock_lock(&gCallbackLock)
        if unsafe gDeviceMonitor === self {
            unsafe gCallbackEnabled = false
            unsafe gDeviceMonitor = nil
        }
        unsafe os_unfair_lock_unlock(&gCallbackLock)

        // The framework worker must not be the last owner while MTDeviceStop is
        // executing: its final CFRelease would enter __MTDeviceRelease and stop
        // the same device concurrently. Release our owners only after stop returns.
        // Do not hold gCallbackLock here: MTDeviceStop may wait for a worker that
        // is finishing a callback and needs that lock. Keep lifecycleLock held so
        // another start cannot overlap this teardown.
        withExtendedLifetime(owners) {
            for unsafe deviceRef in unsafe devicesToStop {
                unsafe api.unregister(deviceRef, deviceContactCallback)
            }
            for unsafe deviceRef in unsafe devicesToStop {
                if unsafe api.isRunning(deviceRef) {
                    unsafe api.stop(deviceRef)
                }
            }
        }

        Log.info("DeviceMonitor stopped", category: .device)
    }

    // MARK: - Internal

    /// Handle contact from callback and return whether to consume the event
    @unsafe @preconcurrency
    fileprivate func handleContact(
        device: MTDeviceRef?,
        touches: UnsafeMutableRawPointer,
        count: Int32,
        timestamp: Double
    ) -> Bool {
        // Check if we're still running before processing - this prevents processing
        // events during shutdown, which could cause race conditions with the
        // MultitouchSupport framework's internal thread
        unsafe stateLock.lock()
        let stillRunning = unsafe isRunning
        unsafe stateLock.unlock()

        guard stillRunning else { return false }

        // Pass touch data to delegate for gesture processing
        unsafe delegate?.deviceMonitor(
            self, didReceiveTouches: touches, count: count, timestamp: timestamp)

        // Never consume at the device level - let all touches through to the system
        // Event suppression is handled by the CGEventTap in MultitouchManager
        // This ensures 4-finger gestures (Mission Control) and 2-finger scrolling work
        return false
    }
}

// MARK: - Delegate Protocol

/// Protocol for receiving touch events from the device monitor
@unsafe protocol DeviceMonitorDelegate: AnyObject {
    /// Called when new touch data is received
    /// - Parameters:
    ///   - monitor: The device monitor
    ///   - touches: Raw pointer to touch data array
    ///   - count: Number of touches
    ///   - timestamp: Timestamp of the touch frame
    func deviceMonitor(
        _ monitor: DeviceMonitor,
        didReceiveTouches touches: UnsafeMutableRawPointer,
        count: Int32,
        timestamp: Double
    )
}
