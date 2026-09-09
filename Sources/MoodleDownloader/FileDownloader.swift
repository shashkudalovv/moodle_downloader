import Foundation

actor FileDownloader {
    struct Summary { let downloaded: Int; let skipped: Int }

    private let session: URLSession
    private let fileManager = FileManager.default

    init(cookies: [HTTPCookie]) {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 90
        configuration.httpAdditionalHeaders = ["User-Agent": "MoodleDownloader/1.0 macOS"]
        cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
        session = URLSession(configuration: configuration)
    }

    func download(
        candidates: [DownloadCandidate],
        course: MoodleCourse,
        destination: URL,
        makeArchive: Bool,
        progress: @Sendable @escaping (Int, Int, String) async -> Void
    ) async throws -> (URL, Summary) {
        let courseFolder = destination.appendingPathComponent(sanitize(course.name), isDirectory: true)
        try fileManager.createDirectory(at: courseFolder, withIntermediateDirectories: true)
        var downloaded = 0
        var skipped = 0

        for (offset, candidate) in candidates.enumerated() {
            await progress(offset, candidates.count, candidate.activityName)
            do {
                let (temporaryURL, response) = try await session.download(from: candidate.url)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    skipped += 1; continue
                }
                let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                if contentType.contains("text/html") { skipped += 1; continue }

                let sectionTitle = sectionFolderName(index: candidate.sectionIndex, title: candidate.sectionName)
                let sectionFolder = courseFolder.appendingPathComponent(sectionTitle, isDirectory: true)
                try fileManager.createDirectory(at: sectionFolder, withIntermediateDirectories: true)
                let serverName = suggestedFilename(response: response, url: candidate.url)
                let filename = smartFilename(activity: candidate.activityName, serverName: serverName)
                let output = uniqueURL(in: sectionFolder, filename: filename)
                try fileManager.moveItem(at: temporaryURL, to: output)
                downloaded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                skipped += 1
            }
        }
        await progress(candidates.count, candidates.count, "Готово")
        if makeArchive {
            let archive = uniqueURL(in: destination, filename: sanitize(course.name) + ".zip")
            try zip(folder: courseFolder, to: archive)
            return (archive, Summary(downloaded: downloaded, skipped: skipped))
        }
        return (courseFolder, Summary(downloaded: downloaded, skipped: skipped))
    }

    private func suggestedFilename(response: URLResponse, url: URL) -> String {
        if let name = response.suggestedFilename, !name.isEmpty { return name }
        return url.lastPathComponent.removingPercentEncoding ?? "material"
    }

    private func smartFilename(activity: String, serverName: String) -> String {
        let ext = (serverName as NSString).pathExtension
        let cleanActivity = sanitize(activity)
        let base: String
        if let match = cleanActivity.firstMatch(of: /(?i)\b(lab(?:oratory)?|lecture|seminar|tutorial|practice|assignment)\s*[-№#:]?\s*(\d+)/) {
            let kind = String(match.1).lowercased()
            let number = String(match.2)
            let canonical: String
            if kind.hasPrefix("lab") { canonical = "Lab" }
            else if kind == "lecture" { canonical = "Lecture" }
            else if kind == "seminar" { canonical = "Seminar" }
            else if kind == "tutorial" { canonical = "Tutorial" }
            else if kind == "practice" { canonical = "Practice" }
            else { canonical = "Assignment" }
            base = "\(canonical) \(number)"
        } else {
            base = cleanActivity
        }
        guard !ext.isEmpty else { return base }
        return base.lowercased().hasSuffix("." + ext.lowercased()) ? base : base + "." + ext
    }

    private func sectionFolderName(index: Int, title: String) -> String {
        let clean = sanitize(title)
        let prefix = String(format: "%02d", max(0, index))
        if clean.range(of: #"^\d+[\s._-]"#, options: .regularExpression) != nil { return clean }
        return "\(prefix) — \(clean)"
    }

    private func sanitize(_ input: String) -> String {
        var value = input.replacingOccurrences(of: #"[/:\\?%*|\"<>]"#, with: "-", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix(".") { value.removeLast() }
        return String(value.prefix(160)).isEmpty ? "Material" : String(value.prefix(160))
    }

    private func uniqueURL(in folder: URL, filename: String) -> URL {
        var result = folder.appendingPathComponent(filename)
        let ext = (filename as NSString).pathExtension
        let stem = (filename as NSString).deletingPathExtension
        var counter = 2
        while fileManager.fileExists(atPath: result.path) {
            let alternative = ext.isEmpty ? "\(stem) (\(counter))" : "\(stem) (\(counter)).\(ext)"
            result = folder.appendingPathComponent(alternative)
            counter += 1
        }
        return result
    }

    private func zip(folder: URL, to archive: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", folder.path, archive.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
