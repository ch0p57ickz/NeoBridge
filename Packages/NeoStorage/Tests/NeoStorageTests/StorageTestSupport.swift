import Foundation
import NeoCore
import XCTest

@testable import NeoStorage

/// Creates and removes a temporary directory for one test.
struct TemporaryDirectory {
    /// The directory the test may write to.
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("neostorage-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// A file URL inside the directory.
    func file(_ name: String) -> URL {
        url.appendingPathComponent(name)
    }

    /// Removes the directory and its contents.
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// A failure a test injects into the store.
enum InjectedFailure: Error, Hashable {
    case stopped
}

/// A publisher whose per-format outcomes a test scripts.
struct StubExportPublisher: PenExportPublisher {
    /// The formats that fail, and why.
    var failures: [PenExportFormat: String] = [:]

    /// Every publication the publisher was asked for.
    let calls: PublicationCalls

    init(failures: [PenExportFormat: String] = [:], calls: PublicationCalls = PublicationCalls()) {
        self.failures = failures
        self.calls = calls
    }

    func publish(_ request: PenExportRequest, content: [PenPageContent]) async -> PenExportReport {
        await calls.record(request: request, content: content)
        return PenExportReport(
            artifacts: request.formats.map { format in
                PenExportArtifact(
                    format: format,
                    path: "\(request.destinationDirectory)/page.\(format.rawValue)",
                    byteCount: content.reduce(0) { $0 + $1.dotCount },
                    status: failures[format].map { .failed(reason: $0) } ?? .published
                )
            }
        )
    }
}

/// Records the publications a stub publisher was asked for.
actor PublicationCalls {
    private var requests: [PenExportRequest] = []
    private var contents: [[PenPageContent]] = []

    /// Records one publication.
    func record(request: PenExportRequest, content: [PenPageContent]) {
        requests.append(request)
        contents.append(content)
    }

    /// Every publication request, in order.
    var allRequests: [PenExportRequest] { requests }

    /// Every publication's page content, in order.
    var allContent: [[PenPageContent]] { contents }
}
