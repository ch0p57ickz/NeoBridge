import AppKit
import NeoBridgeMacCore
import SwiftUI

/// The optional details window.
///
/// The window shows the same state as the menu with room for the counts, the
/// notes read, and the failure detail.
struct PenSyncView: View {
    @Environment(\.dismissWindow) private var dismissWindow
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

            actions
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 400, alignment: .topLeading)
        .background(WindowRaiserView())
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            Text("No pen data has been read yet.")
                .foregroundStyle(.secondary)

        case .scanning, .connecting, .verifying, .syncing:
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

        case .complete(let result):
            completed(result)

        case .failed(let message, let diagnostic):
            failure(message, diagnostic)
        }
    }

    @ViewBuilder
    private func completed(_ result: PenSyncSummary) -> some View {
        if result.isEmpty {
            Text("The pen reported no offline note to read.")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: 28) {
                count("Strokes", result.strokeCount)
                count("Dots", result.dotCount)
                count("Pages", result.distinctPageCount)
            }

            Text("Notes read")
                .font(.headline)
            ForEach(result.notes) { note in
                Text("\(note.label) — \(note.strokeCount) strokes")
                    .font(.callout)
            }
        }

        Text(PenSyncController.notSavedNotice)
            .font(.callout)
            .foregroundStyle(.secondary)
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
    private var actions: some View {
        HStack {
            if controller.isBusy {
                Button("Cancel") { controller.cancel() }
            } else {
                Button(PenSyncController.readActionTitle) { controller.readPenData() }
            }

            Spacer()

            Button("Close") { dismissWindow(id: PenSyncScene.windowID) }
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
