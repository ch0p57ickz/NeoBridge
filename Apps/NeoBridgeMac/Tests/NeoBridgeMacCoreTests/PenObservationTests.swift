import Foundation
import NeoBridgeMacCore
import Synchronization
import XCTest

/// Tests for the two scans the adapter runs.
///
/// The bounded selection scan and the continuous observation scan answer different
/// questions — "which pen should this read use" and "is the pen still there" — and
/// the radio runs only one of them at a time. These tests cover the observation
/// side and the handoff rules the schedule depends on.
@MainActor
final class PenObservationTests: XCTestCase {
    private let penName = CoreBluetoothPenTransport.advertisedName

    func testObservationReportsRepeatedAdvertisementsAndStaysOpen() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [pen])
        let collected = StreamCollector<PenPeripheral>()

        let observation = central.observe()
        let task = Task {
            do {
                for try await peripheral in observation { collected.append(peripheral) }
            } catch {
                XCTFail("the observation ended with an error: \(error)")
            }
        }

        try await waitUntil("the first advertisement") { collected.values.count == 1 }
        XCTAssertTrue(central.isObserving)

        // The observation asks for duplicates, so a pen that stays in range keeps
        // reporting. That is what lets the schedule measure how long it has been
        // silent, and it is the difference from the selection scan.
        central.emit(pen)
        central.emit(pen)
        try await waitUntil("the repeated advertisements") { collected.values.count == 3 }
        XCTAssertEqual(collected.values, [pen, pen, pen])

        await central.stopObservation()
        await task.value

        XCTAssertFalse(central.isObserving)
        XCTAssertTrue(central.didStopObservation)
        XCTAssertEqual(central.events, ["observe", "stopObservation"])
    }

    func testAnAdapterErrorEndsTheObservation() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let central = FakePenBluetoothCentral(
            advertisedPeripherals: [pen],
            observationFailure: .adapterUnavailable(.poweredOff)
        )

        var caught: PenBluetoothError?
        do {
            for try await _ in central.observe() {}
        } catch let error as PenBluetoothError {
            caught = error
        }

        XCTAssertEqual(caught, .adapterUnavailable(.poweredOff))
    }

    func testStoppingObservationLeavesTheSelectionScanRunning() async throws {
        let pen = PenPeripheral(id: UUID(), name: penName)
        let central = FakePenBluetoothCentral(advertisedPeripherals: [pen])
        let collected = StreamCollector<PenPeripheral>()

        let scan = central.scan()
        let task = Task {
            do {
                for try await peripheral in scan { collected.append(peripheral) }
            } catch {
                XCTFail("the scan ended with an error: \(error)")
            }
        }
        try await waitUntil("the scan to report") { collected.values.count == 1 }

        // The schedule stops its observation around a read, so a stop that also
        // ended the read's own scan would make every read report "no pen found".
        await central.stopObservation()

        XCTAssertTrue(central.didScan)
        XCTAssertFalse(central.didStopScan, "an observation stop must leave the read's scan alone")
        XCTAssertFalse(central.isObserving)
        XCTAssertEqual(central.events, ["scan"], "no observation was running, so none was stopped")

        await central.stopScan()
        await task.value
        XCTAssertEqual(central.events, ["scan", "stopScan"])
    }

    // MARK: - Helpers

    /// Collects the elements a stream reports.
    private final class StreamCollector<Element: Sendable>: @unchecked Sendable {
        private let store = Mutex<[Element]>([])

        var values: [Element] { store.withLock { $0 } }

        func append(_ element: Element) {
            store.withLock { $0.append(element) }
        }
    }

    private func waitUntil(
        _ description: String,
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("the fake adapter never reached: \(description)")
    }
}
