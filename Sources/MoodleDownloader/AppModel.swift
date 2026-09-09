import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    let webSession = MoodleWebSession()
    @Published var courses: [MoodleCourse] = []
    @Published var selectedCourse: MoodleCourse?
    @Published var sections: [MoodleSection] = []
    @Published var selectedSectionIDs: Set<Int> = []
    @Published var state: DownloadState = .idle
    @Published var needsLogin = false
    @Published var isStarting = true
    @Published var createArchive = true
    @Published var statusMessage = "Подключаюсь к Innopolis Moodle…"
    @Published var destination: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]

    private var activeTask: Task<Void, Never>?
    private var handledCoursesPage = false

    init() {
        webSession.onNavigationFinished = { [weak self] url in
            self?.navigationFinished(url)
        }
        webSession.onNavigationFailed = { [weak self] error in
            self?.isStarting = false
            self?.statusMessage = "Не удалось открыть Moodle: \(error.localizedDescription)"
        }
        webSession.goHome()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.isStarting else { return }
            self.isStarting = false
            self.statusMessage = "Moodle не ответил. Проверьте российский IP и повторите подключение."
        }
    }

    private func navigationFinished(_ url: URL) {
        isStarting = false
        if url.path.contains("/login") {
            needsLogin = true
            handledCoursesPage = false
            return
        }
        if url.path.contains("/my/courses") {
            needsLogin = false
            guard !handledCoursesPage else { return }
            handledCoursesPage = true
            refreshCourses()
        }
    }

    func showLoginScreen() {
        needsLogin = true
    }

    func retrySession() {
        handledCoursesPage = false
        isStarting = true
        webSession.goHome()
    }

    func refreshCourses() {
        activeTask?.cancel()
        state = .preparing("Ищу доступные курсы…")
        activeTask = Task {
            do {
                let found = try await MoodleScraper(session: webSession).loadCourses()
                try Task.checkCancellation()
                courses = found
                if selectedCourse == nil || !found.contains(where: { $0.id == selectedCourse?.id }) {
                    selectedCourse = found.first
                }
                statusMessage = "Найдено курсов: \(found.count)"
                state = .idle
                if let selectedCourse { loadSections(for: selectedCourse) }
            } catch {
                if error.localizedDescription.contains("AUTH") { needsLogin = true }
                state = .failed(readable(error))
                statusMessage = readable(error)
            }
        }
    }

    func selectCourse(_ course: MoodleCourse?) {
        selectedCourse = course
        sections = []
        selectedSectionIDs = []
        guard let course else { return }
        loadSections(for: course)
    }

    func loadSections(for course: MoodleCourse) {
        activeTask?.cancel()
        state = .preparing("Загружаю уроки и темы…")
        activeTask = Task {
            do {
                let found = try await MoodleScraper(session: webSession).loadSections(course: course)
                try Task.checkCancellation()
                guard selectedCourse?.id == course.id else { return }
                sections = found.sorted { $0.index < $1.index }
                selectedSectionIDs = Set(found.map(\.id))
                statusMessage = "Найдено уроков и тем: \(found.count)"
                state = .idle
            } catch is CancellationError {
                return
            } catch {
                if error.localizedDescription.contains("AUTH") { needsLogin = true }
                state = .failed("Не удалось загрузить уроки: \(readable(error))")
            }
        }
    }

    func toggleSection(_ section: MoodleSection) {
        if selectedSectionIDs.contains(section.id) { selectedSectionIDs.remove(section.id) }
        else { selectedSectionIDs.insert(section.id) }
    }

    func selectAllSections() { selectedSectionIDs = Set(sections.map(\.id)) }
    func clearSectionSelection() { selectedSectionIDs.removeAll() }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Выбрать"
        panel.directoryURL = destination
        if panel.runModal() == .OK, let url = panel.url { destination = url }
    }

    func exportCurrentPageHTML() {
        activeTask = Task {
            do {
                let html = try await webSession.evaluate("document.documentElement.outerHTML")
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "moodle-course-page.html"
                panel.allowedContentTypes = [.html]
                panel.prompt = "Сохранить"
                if panel.runModal() == .OK, let url = panel.url {
                    try html.write(to: url, atomically: true, encoding: .utf8)
                    statusMessage = "HTML сохранён. Перед отправкой удалите личные данные."
                }
            } catch {
                state = .failed("Не удалось сохранить HTML: \(readable(error))")
            }
        }
    }

    func startDownload() {
        guard let course = selectedCourse, !selectedSectionIDs.isEmpty else { return }
        activeTask?.cancel()
        state = .preparing("Читаю структуру курса…")
        activeTask = Task {
            do {
                let scraper = MoodleScraper(session: webSession)
                let sectionsToDownload: [MoodleSection]
                if sections.isEmpty {
                    sectionsToDownload = try await scraper.loadSections(course: course)
                        .filter { selectedSectionIDs.contains($0.id) }
                } else {
                    sectionsToDownload = sections.filter { selectedSectionIDs.contains($0.id) }
                }
                var candidates: [DownloadCandidate] = []
                let totalActivities = sectionsToDownload.reduce(0) { $0 + $1.activities.count }
                var inspected = 0
                for section in sectionsToDownload {
                    for activity in section.activities {
                        try Task.checkCancellation()
                        inspected += 1
                        state = .preparing("Проверяю материалы: \(inspected) из \(totalActivities)")
                        let urls = try await scraper.discoverFiles(in: activity)
                        for url in urls {
                            candidates.append(DownloadCandidate(sectionIndex: section.index, sectionName: section.name, activityName: activity.name, url: url))
                        }
                    }
                }
                candidates = Array(Set(candidates)).sorted { $0.url.absoluteString < $1.url.absoluteString }
                guard !candidates.isEmpty else { throw NSError(domain: "MoodleDownloader", code: 1, userInfo: [NSLocalizedDescriptionKey: "В курсе не найдено доступных для скачивания файлов."]) }
                let cookies = await webSession.cookies()
                let downloader = FileDownloader(cookies: cookies)
                let (output, summary) = try await downloader.download(candidates: candidates, course: course, destination: destination, makeArchive: createArchive) { [weak self] done, total, current in
                    await MainActor.run { self?.state = .downloading(done: done, total: total, current: current) }
                }
                state = .finished(output, downloaded: summary.downloaded, skipped: summary.skipped)
                statusMessage = "Скачано файлов: \(summary.downloaded)"
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch is CancellationError {
                state = .idle
                statusMessage = "Загрузка отменена."
            } catch {
                state = .failed(readable(error))
                statusMessage = readable(error)
            }
        }
    }

    func cancel() { activeTask?.cancel() }

    private func readable(_ error: Error) -> String {
        let text = error.localizedDescription
        if text.contains("AUTH") { return "Сессия не авторизована. Войдите в Moodle и повторите попытку." }
        return text
    }
}
