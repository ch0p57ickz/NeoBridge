import AppKit
import NeoBridgeMacCore
import NeoCore
import SwiftUI

/// The optional details window.
///
/// The window is where the information lives that the menu deliberately leaves
/// out: the saved settings and what they mean, the export folder, the counts and
/// notes a read found, each file's publication result, and the failure detail.
struct PenSyncView: View {
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var folderMessage: String?
    let controller: PenSyncController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NeoBridge")
                    .font(.title2)
                    .bold()
                Text(controller.statusLabel)
                    .foregroundStyle(.secondary)
            }

            Divider()

            content

            Spacer(minLength: 0)

            Divider()

            settings

            Divider()

            destination

            Divider()

            actions
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
        .background(WindowRaiserView())
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            Text("No pen data has been read yet.")
                .foregroundStyle(.secondary)

        case .scanning, .connecting, .verifying, .syncing, .saving, .exporting:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(controller.statusLabel)
            }
            // A running read shows progress rather than the counts of an
            // earlier read, so the row can never be mistaken for a result.
            Text("Counts from an earlier read are not shown while a read is running.")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .choosingPen(let candidates):
            Text("More than one pen advertises the expected name. Choose the pen to read.")
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, pen in
                Button("Read \(pen.name ?? "Pen") (pen \(index + 1))") {
                    controller.choosePen(pen)
                }
            }

        case .complete(let outcome):
            completed(outcome)

        case .failed(let message, let diagnostic):
            failure(message, diagnostic)
        }
    }

    @ViewBuilder
    private func completed(_ outcome: PenReadOutcome) -> some View {
        if let state = controller.penState {
            Text("Battery: \(state.batteryLevel)% · \(state.isCharging ? "Charging" : "Not charging")")
            Text("Pen storage used: \(state.memoryUsed)%")
        }
        if outcome.isEmpty {
            Text("The pen reported no stroke to save.")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 28) {
                count("Strokes", outcome.summary.strokeCount)
                count("Dots", outcome.summary.dotCount)
                count("Pages", outcome.summary.distinctPageCount)
            }

            Text("Notes read")
                .font(.headline)
            ForEach(outcome.summary.notes) { note in
                Text("\(note.label) — \(note.strokeCount) strokes")
                    .font(.callout)
            }
        }

        Text(outcome.notice)
            .font(.callout)

        Text(outcome.cleanupNotice)
            .font(.callout)
            .foregroundStyle(.secondary)

        if let export = outcome.export, !export.artifacts.isEmpty {
            Text("Files")
                .font(.headline)
            ForEach(export.artifacts, id: \.path) { artifact in
                Label(Self.description(of: artifact), systemImage: Self.symbol(for: artifact))
                    .font(.callout)
                    .foregroundStyle(artifact.failureReason == nil ? Color.secondary : Color.primary)
            }
        }
    }

    @ViewBuilder
    private func failure(_ message: String, _ diagnostic: String?) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.primary)

        if let diagnostic {
            Text(diagnostic)
                .font(.callout)
                .foregroundStyle(.secondary)
        }

        // Partial counts are diagnostics, so the window states plainly that no
        // completed result exists.
        Text("No counts are shown because the read did not complete.")
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func count(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(.system(.title, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var destination: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Export folder")
                .font(.headline)
            Text(controller.exportDirectoryPath ?? "No folder chosen. Reads are saved to the library only.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let folderMessage {
                Text(folderMessage)
                    .font(.callout)
            }
        }
    }

    /// The saved sync settings, which the menu offers too.
    ///
    /// The two surfaces write the same saved setting, so a change here is what the
    /// next automatic attempt uses, and the mode and interval the menu shows agree
    /// with what this window shows.
    @ViewBuilder
    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync settings")
                .font(.headline)

            Picker("Mode", selection: modeBinding) {
                ForEach(PenSyncMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Picker("Interval", selection: intervalBinding) {
                ForEach(PenSyncInterval.allCases, id: \.self) { interval in
                    Text(interval.title).tag(interval)
                }
            }

            Text(controller.syncModeLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(controller.syncIntervalLine)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(PenSyncController.automaticCleanupStatement)
                .font(.callout)
                .foregroundStyle(.secondary)

            // The mode never stands in for a transfer gate, so the gate that is
            // closed is named here rather than left for the user to infer from a
            // read that kept the pen's copy.
            if let reason = controller.cleanupUnavailableReason {
                Text("Cleanup is unavailable: \(reason)")
                    .font(.callout)
            }
        }
    }

    /// The saved mode the picker shows and writes.
    private var modeBinding: Binding<PenSyncMode> {
        Binding(
            get: { controller.syncMode },
            set: { controller.selectSyncMode($0) }
        )
    }

    /// The saved interval the picker shows and writes.
    private var intervalBinding: Binding<PenSyncInterval> {
        Binding(
            get: { controller.syncInterval },
            set: { controller.selectSyncInterval($0) }
        )
    }

    @ViewBuilder
    private var actions: some View {
        HStack {
            if controller.isBusy {
                Button("Cancel") { controller.cancel() }
            } else {
                Button("Choose Export Folder…") {
                    folderMessage = PenExportFolderChooser.choose(into: controller)
                }
                if controller.canRetryExport {
                    Button(PenSyncController.retryExportActionTitle) { controller.retryExport() }
                }
            }

            Spacer()

            Button("Close") { dismissWindow(id: PenSyncScene.windowID) }
        }
    }

    /// A one-line description of one file's outcome.
    private static func description(of artifact: PenExportArtifact) -> String {
        let name = URL(fileURLWithPath: artifact.path).lastPathComponent
        switch artifact.status {
        case .unchanged: return "\(name) — already up to date"
        case .published: return "\(name) — written"
        case .failed(let reason): return "\(name) — failed: \(reason)"
        }
    }

    /// A symbol for one file's outcome.
    private static func symbol(for artifact: PenExportArtifact) -> String {
        switch artifact.status {
        case .unchanged: return "equal.circle"
        case .published: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
}

/// An invisible view that makes the details window key and front within the app.
///
/// Bringing the app itself forward is `PenSyncActivation`'s job, from the menu
/// command: the measurement recorded there shows a window cannot take activation
/// from another app by itself. This view covers the other half, making the window
/// key as soon as it joins a window, which is the first moment it exists.
private struct WindowRaiserView: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowRaiser {
        WindowRaiser()
    }

    func updateNSView(_ nsView: WindowRaiser, context: Context) {}
}

/// Makes its window key and front whenever the view joins a window.
private final class WindowRaiser: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Ordering is idempotent, so a reopened window is raised again without a
        // flag tracking whether this view already raised one.
        window?.makeKeyAndOrderFront(nil)
    }
}
