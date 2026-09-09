import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            mainInterface
                .opacity(model.needsLogin ? 0 : 1)
                .allowsHitTesting(!model.needsLogin)

            if model.needsLogin {
                loginInterface.transition(.opacity)
            } else {
                MoodleWebView(session: model.webSession)
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)
            }

            if model.isStarting { startupOverlay }
        }
        .animation(.easeInOut(duration: 0.2), value: model.needsLogin)
        .alert("Ошибка", isPresented: Binding(get: {
            if case .failed = model.state { return true }; return false
        }, set: { if !$0 { model.state = .idle } })) {
            Button("OK") { model.state = .idle }
        } message: {
            if case .failed(let message) = model.state { Text(message) }
        }
    }

    private var mainInterface: some View {
        NavigationSplitView {
            courseSidebar.navigationSplitViewColumnWidth(min: 270, ideal: 320, max: 390)
        } detail: {
            lessonPane
        }
        .toolbar {
            ToolbarItemGroup {
                Button { model.refreshCourses() } label: {
                    Label("Обновить", systemImage: "arrow.clockwise")
                }
                .disabled(model.state.isRunning)
            }
        }
    }

    private var courseSidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Moodle Downloader").font(.title2.bold())
                Text("Выберите предмет").font(.caption).foregroundStyle(.secondary)
            }

            if model.courses.isEmpty && model.state.isRunning {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Загружаю предметы…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.courses.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "wifi.exclamationmark").font(.title).foregroundStyle(.secondary)
                    Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Повторить") { model.retrySession() }
                    Button("Открыть вход") { model.showLoginScreen() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.courses, selection: Binding(
                    get: { model.selectedCourse },
                    set: { model.selectCourse($0) }
                )) { course in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(course.name).lineLimit(3)
                        Text("ID \(course.id)").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 3)
                    .tag(course)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Сохранить в").font(.caption).foregroundStyle(.secondary)
                Button { model.chooseDestination() } label: {
                    HStack {
                        Image(systemName: "folder")
                        Text(model.destination.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                    }
                }
                .buttonStyle(.bordered)
                Toggle("Создать ZIP-архив", isOn: $model.createArchive)
            }
        }
        .padding()
    }

    private var lessonPane: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.selectedCourse?.name ?? "Уроки и темы")
                        .font(.title2.bold()).lineLimit(2)
                    Text(selectionDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Выбрать все") { model.selectAllSections() }.disabled(model.sections.isEmpty)
                Button("Снять выбор") { model.clearSectionSelection() }.disabled(model.sections.isEmpty)
            }
            .padding()
            Divider()

            if model.selectedCourse == nil {
                emptyPane(icon: "books.vertical", title: "Выберите предмет", detail: "После этого здесь появятся доступные уроки и темы.")
            } else if model.sections.isEmpty && model.state.isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Читаю структуру курса…").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.sections.isEmpty {
                emptyPane(icon: "doc.questionmark", title: "Уроки не найдены", detail: "Обновите список; если ошибка повторится, откройте аккаунт и сохраните HTML курса.")
            } else {
                List(model.sections) { section in
                    Button { model.toggleSection(section) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedSectionIDs.contains(section.id) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(model.selectedSectionIDs.contains(section.id) ? Color.accentColor : .secondary)
                                .font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(sectionTitle(section)).font(.headline)
                                Text("Материалов: \(section.activities.count)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 5)
                }
            }

            Divider()
            downloadBar
        }
    }

    private var downloadBar: some View {
        VStack(spacing: 9) {
            if case .downloading(let done, let total, let current) = model.state {
                HStack {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                    Text("\(done) / \(total) — \(current)").font(.caption).lineLimit(1)
                    Button("Отменить") { model.cancel() }
                }
            } else if case .preparing(let text) = model.state {
                HStack { ProgressView().controlSize(.small); Text(text).font(.caption) }
            } else if case .finished(let url, let downloaded, let skipped) = model.state {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("Скачано: \(downloaded)" + (skipped > 0 ? ", пропущено: \(skipped)" : "")).font(.caption)
                    Spacer()
                    Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }

            Button { model.startDownload() } label: {
                Label("Скачать выбранные уроки", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selectedCourse == nil || model.selectedSectionIDs.isEmpty || model.state.isRunning)
        }
        .padding()
    }

    private var loginInterface: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill").foregroundStyle(Color.accentColor).font(.title2)
                VStack(alignment: .leading) {
                    Text("Вход в Innopolis Moodle").font(.headline)
                    Text("Войдите один раз — сессия сохранится на этом Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.webSession.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.webSession.webView.canGoBack)
                Button { model.webSession.reload() } label: { Image(systemName: "arrow.clockwise") }
                Button { model.webSession.goHome() } label: { Image(systemName: "house") }
                Button { model.exportCurrentPageHTML() } label: { Label("Сохранить HTML", systemImage: "doc.badge.arrow.up") }
                if !model.courses.isEmpty { Button("Закрыть") { model.needsLogin = false } }
            }
            .padding()
            Divider()
            MoodleWebView(session: model.webSession)
        }
        .background(.background)
    }

    private var startupOverlay: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Открываю сохранённую сессию Moodle…").foregroundStyle(.secondary)
            }
        }
    }

    private func emptyPane(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var selectionDescription: String {
        guard !model.sections.isEmpty else { return "Выберите нужные части курса" }
        return "Выбрано: \(model.selectedSectionIDs.count) из \(model.sections.count)"
    }

    private func sectionTitle(_ section: MoodleSection) -> String {
        let number = section.index > 0 ? "\(section.index). " : ""
        return number + section.name
    }
}
