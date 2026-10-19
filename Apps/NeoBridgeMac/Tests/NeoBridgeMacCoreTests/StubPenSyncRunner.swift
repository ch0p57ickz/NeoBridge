import Foundation
import NeoBridgeMacCore
import Synchronization

/// Records the stages one runner reports, in order.
final class StageRecorder: @unchecked Sendable {
    private let store = Mutex<[PenSyncStage]>([])

    /// Every stage reported so far.
    var values: [PenSyncStage] { store.withLock { $0 } }

    /// Records one stage.
    func record(_ stage: PenSyncStage) {
        store.withLock { $0.append(stage) }
    }
}

/// Counts how many runners a factory made.
final class RunnerCounter: @unchecked Sendable {
    private let store = Mutex(0)

    /// The number of runners made so far.
    var value: Int { store.withLock { $0 } }

    /// Records one runner.
    func increment() {
        store.withLock { $0 += 1 }
    }
}

/// Records the selection each attempt was built with.
final class SelectionRecorder: @unchecked Sendable {
    private let store = Mutex<[CoreBluetoothPenTransport.Selection]>([])

    /// Every selection recorded so far, in order.
    var values: [CoreBluetoothPenTransport.Selection] { store.withLock { $0 } }

    /// Records one selection.
    func record(_ selection: CoreBluetoothPenTransport.Selection) {
        store.withLock { $0.append(selection) }
    }
}

/// A runner that reports scripted stages and then produces a scripted outcome.
///
/// The runner is what makes the shell testable without a radio: the controller
/// cannot tell it from the real one. Its result carries both the counts the shell
/// presents and the strokes the library commits, so the shell tests exercise the
/// same complete read a real session produces.
struct StubPenSyncRunner: PenSyncRunning {
    /// What one attempt ends with.
    enum Outcome: Sendable {
        /// A completed read.
        case success(PenReadResult)

        /// A failure from the Bluetooth layer or the session.
        case failure(any Error & Sendable)

        /// Suspends until cancelled, like an attempt waiting on the radio.
        case waitsForCancellation
    }

    /// The stages to report, in order.
    let stages: [PenSyncStage]

    /// What the attempt ends with.
    let outcome: Outcome

    func run(report: @escaping @Sendable (PenSyncStage) -> Void) async throws -> PenReadResult {
        for stage in stages {
            report(stage)
            await Task.yield()
        }

        switch outcome {
        case .success(let read):
            return read
        case .failure(let error):
            throw error
        case .waitsForCancellation:
            // Sleeps in short steps so the wait stays cancellation-aware, which
            // is how a real attempt behaves while it waits for the pen.
            while true {
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }
}
