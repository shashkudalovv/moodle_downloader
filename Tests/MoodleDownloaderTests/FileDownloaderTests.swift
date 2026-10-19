import Foundation
import XCTest
@testable import MoodleDownloader

@MainActor
final class FileDownloaderTests: XCTestCase {
    private let course = MoodleCourse(
        id: "test",
        name: "Discrete Mathematics",
        url: URL(string: "https://example.invalid/course/view.php?id=test")!
    )

    func testRepeatedDownloadReplacesFileWithoutNumberedCopy() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        let downloader = FileDownloader(cookies: [])
        let candidate = fixture.candidate()

        for content in ["original PDF", "updated PDF", "latest PDF"] {
            try Data(content.utf8).write(to: fixture.body)
            let (_, summary) = try await downloader.download(
                candidates: [candidate], course: course,
                destination: fixture.output, makeArchive: false
            ) { _, _, _ in }
            XCTAssertEqual(summary.downloaded, 1)
            XCTAssertEqual(summary.skipped, 0)
            XCTAssertEqual(try String(contentsOf: fixture.material, encoding: .utf8), content)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.section.path), ["Lab 7.pdf"])
        }
    }

    func testFailedResponsesKeepPreviousFile() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        try FileManager.default.createDirectory(at: fixture.section, withIntermediateDirectories: true)
        try Data("previous PDF".utf8).write(to: fixture.material)
        let downloader = FileDownloader(cookies: [])

        for path in ["error.pdf", "login.pdf", "interrupted.pdf"] {
            let (_, summary) = try await downloader.download(
                candidates: [fixture.candidate(path: path)], course: course,
                destination: fixture.output, makeArchive: false
            ) { _, _, _ in }
            XCTAssertEqual(summary.downloaded, 0, path)
            XCTAssertEqual(summary.skipped, 1, path)
            XCTAssertEqual(try String(contentsOf: fixture.material, encoding: .utf8), "previous PDF")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.section.path), ["Lab 7.pdf"])
    }

    func testRepeatedCourseZIPReplacesArchiveAndIncludesUpdatedFile() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        let downloader = FileDownloader(cookies: [])
        let expectedArchive = fixture.output.appendingPathComponent("Discrete Mathematics.zip")

        for (index, content) in ["original PDF", "updated PDF"].enumerated() {
            try Data(content.utf8).write(to: fixture.body)
            let (archive, summary) = try await downloader.download(
                candidates: [fixture.candidate()], course: course,
                destination: fixture.output, makeArchive: true
            ) { _, _, _ in }
            XCTAssertEqual(archive, expectedArchive)
            XCTAssertEqual(summary.downloaded, 1)
            let extracted = try fixture.extract(archive, name: "course-\(index)")
            let material = extracted.appendingPathComponent("Discrete Mathematics/07 — Week 7/Lab 7.pdf")
            XCTAssertEqual(try String(contentsOf: material, encoding: .utf8), content)
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.output.path).sorted(),
            ["Discrete Mathematics", "Discrete Mathematics.zip"]
        )
    }

    func testRepeatedFullZIPHasNoStaleEntriesOrNumberedCopy() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        let source = fixture.root.appendingPathComponent("Moodle Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let removed = source.appendingPathComponent("old.pdf")
        let current = source.appendingPathComponent("Lecture 7.pdf")
        try Data("removed later".utf8).write(to: removed)
        try Data("original".utf8).write(to: current)
        let downloader = FileDownloader(cookies: [])
        let first = try await downloader.archive(folder: source, destination: fixture.output, filename: "Moodle Materials.zip")
        try FileManager.default.removeItem(at: removed)
        try Data("updated".utf8).write(to: current)
        let second = try await downloader.archive(folder: source, destination: fixture.output, filename: "Moodle Materials.zip")

        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path), ["Moodle Materials.zip"])
        let extracted = try fixture.extract(second, name: "full")
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("Moodle Materials/old.pdf").path))
        XCTAssertEqual(
            try String(contentsOf: extracted.appendingPathComponent("Moodle Materials/Lecture 7.pdf"), encoding: .utf8),
            "updated"
        )
    }

    func testFailedZIPKeepsPreviousArchive() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        let archive = fixture.output.appendingPathComponent("Moodle Materials.zip")
        let previous = Data("previous archive".utf8)
        try previous.write(to: archive)
        let downloader = FileDownloader(cookies: [])
        do {
            _ = try await downloader.archive(
                folder: fixture.root.appendingPathComponent("missing"),
                destination: fixture.output, filename: "Moodle Materials.zip"
            )
            XCTFail("Missing source must fail instead of replacing the previous ZIP")
        } catch {
            XCTAssertEqual(try Data(contentsOf: archive), previous)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.output.path), ["Moodle Materials.zip"])
    }

    func testDirectoryWithMatchingNameIsPreserved() async throws {
        let fixture = try DownloadFixture()
        defer { fixture.stop() }
        try FileManager.default.createDirectory(at: fixture.material, withIntermediateDirectories: true)
        let marker = fixture.material.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: marker)
        let downloader = FileDownloader(cookies: [])
        let (_, summary) = try await downloader.download(
            candidates: [fixture.candidate()], course: course,
            destination: fixture.output, makeArchive: false
        ) { _, _, _ in }
        XCTAssertEqual(summary.downloaded, 0)
        XCTAssertEqual(summary.skipped, 1)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.section.path), ["Lab 7.pdf"])
    }
}

@MainActor
private final class DownloadFixture {
    let root: URL
    let output: URL
    let body: URL
    let section: URL
    var material: URL { section.appendingPathComponent("Lab 7.pdf") }
    private let process = Process()
    private var baseURL: URL!

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MoodleDownloadTests-\(UUID().uuidString)", isDirectory: true)
        output = root.appendingPathComponent("output", isDirectory: true)
        body = root.appendingPathComponent("body")
        section = output.appendingPathComponent("Discrete Mathematics/07 — Week 7", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try Data("PDF".utf8).write(to: body)
        let port = root.appendingPathComponent("port")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", Self.server, root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<250 {
            if let text = try? String(contentsOf: port, encoding: .utf8), let portNumber = Int(text) {
                baseURL = URL(string: "http://127.0.0.1:\(portNumber)/")!
                return
            }
            if !process.isRunning { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        stop()
        throw NSError(domain: "DownloadFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local HTTP fixture failed to start"])
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    func candidate(path: String = "material.pdf") -> DownloadCandidate {
        DownloadCandidate(
            sectionIndex: 7, sectionName: "Week 7", activityName: "Lab 7",
            url: baseURL.appendingPathComponent(path)
        )
    }

    func extract(_ archive: URL, name: String) throws -> URL {
        let extracted = root.appendingPathComponent(name, isDirectory: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, extracted.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return extracted
    }

    private static let server = #"""
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    from pathlib import Path
    import sys

    root = Path(sys.argv[1])
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            data = (root / 'body').read_bytes()
            error = self.path == '/error.pdf'
            self.send_response(500 if error else 200)
            self.send_header('Content-Type', 'text/html' if self.path == '/login.pdf' else 'application/pdf')
            self.send_header('Content-Disposition', 'attachment; filename="material.pdf"')
            self.send_header('Content-Length', str(len(data) + (100 if self.path == '/interrupted.pdf' else 0)))
            self.end_headers()
            self.wfile.write(data)
            self.close_connection = True
        def log_message(self, *args):
            pass
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    (root / 'port').write_text(str(server.server_address[1]))
    server.serve_forever()
    """#
}
