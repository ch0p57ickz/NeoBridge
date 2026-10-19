import Foundation
import NeoCore

/// Publishes every requested page as a JSON record, an SVG drawing, and a
/// Markdown page, replacing each target atomically.
///
/// The publisher is the portable half of export: it receives a resolved
/// directory path and never asks the platform for permission. On macOS the app
/// resolves the user's security-scoped bookmark first, then hands this type the
/// path.
public struct FilePenExportPublisher: PenExportPublisher {
    /// How many prior versions of each target file are kept.
    public static let backupDepth = 3

    /// The file manager used for directory checks and backup rotation.
    ///
    /// The shared instance is used rather than a stored one, because
    /// `FileManager` is not `Sendable` and this publisher is.
    private var fileManager: FileManager { .default }

    /// Creates a publisher.
    public init() {}

    public func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        let writer = AtomicFileWriter(fileManager: fileManager, backupDepth: Self.backupDepth)
        let directory = URL(fileURLWithPath: request.destinationDirectory, isDirectory: true)
        let directoryProblem = problemWithDirectory(directory)

        var artifacts: [PenExportArtifact] = []
        for page in content.sorted(by: { PageIdentity.canonicalOrder($0.page, $1.page) })
        where !page.isEmpty {
            let document = PageExportDocument(page: page.page, strokes: page.strokes)

            for format in request.formats {
                let bytes = Self.render(document, format: format)
                let target = directory.appendingPathComponent(document.fileName(for: format))
                let status: PenExportFileStatus = directoryProblem.map(PenExportFileStatus.failed)
                    ?? writer.publish(bytes: bytes, to: target)

                artifacts.append(
                    PenExportArtifact(
                        format: format,
                        path: target.path,
                        byteCount: bytes.count,
                        status: status
                    )
                )
            }
        }

        return PenExportReport(artifacts: artifacts)
    }

    /// The bytes one format renders to.
    public static func render(_ document: PageExportDocument, format: PenExportFormat) -> [UInt8] {
        switch format {
        case .json: return JSONPageRenderer.render(document)
        case .svg: return SVGPageRenderer.render(document)
        case .markdown: return MarkdownPageRenderer.render(document)
        }
    }

    /// A reason the destination directory cannot be written to, or `nil`.
    private func problemWithDirectory(_ directory: URL) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return "the destination directory \(directory.path) does not exist"
        }
        guard isDirectory.boolValue else {
            return "the destination \(directory.path) is not a directory"
        }
        return nil
    }
}
