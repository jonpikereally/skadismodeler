import AppKit
import SwiftUI

@main
struct SkadisModelerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared
    @StateObject private var updates = UpdateState.shared

    var body: some Scene {
        Window("SkadisModeler", id: "main") {
            ContentView()
                .environmentObject(model)
                .navigationTitle(model.fileURL.map { $0.deletingPathExtension().lastPathComponent } ?? "SkadisModeler")
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(updates.title) { delegate.checkForUpdates() }
                    .disabled(updates.installing)
                Button("Update Source…") { delegate.editUpdateSource() }
                Button("SkadisModeler on GitHub") {
                    if let url = URL(string: "https://github.com/\(AppVersion.repo)") { NSWorkspace.shared.open(url) }
                }
                Button("Error Code List") {
                    if let url = URL(string: ErrorReporter.helpURL) { NSWorkspace.shared.open(url) }
                }
                Text("Version \(AppVersion.version) (built \(AppVersion.built))")
            }
            CommandGroup(replacing: .newItem) {
                Button("New Layout") { model.newLayout() }.keyboardShortcut("n")
                Button("Open Layout…") { model.chooseLayout() }.keyboardShortcut("o")
                Divider()
                Button("Add Models…") { model.chooseModels() }.keyboardShortcut("i")
                Divider()
                Button("Save Layout") { model.saveLayout() }.keyboardShortcut("s")
                Button("Save Layout As…") { model.saveLayout(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo.undo(); model.objectWillChange.send() }
                    .keyboardShortcut("z").disabled(!model.undo.canUndo)
                Button("Redo") { model.undo.redo(); model.objectWillChange.send() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.undo.canRedo)
            }
            CommandMenu("Model") {
                Button("Duplicate") { model.selection.map(model.duplicate) }.keyboardShortcut("d").disabled(model.selection == nil)
                Button("Spin a Quarter Turn") { model.selection.map { model.turn($0, about: 2) } }
                    .keyboardShortcut("r").disabled(model.selection == nil)
                Button("Find Hooks Again") { model.selection.map(model.resetOrientation) }.disabled(model.selection == nil)
                Divider()
                Button("Remove from Board") { model.selection.map(model.remove) }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(model.selection == nil)
            }
            CommandGroup(before: .toolbar) {
                Button("Front View") { model.scene.rig.set(.front) }.keyboardShortcut("1")
                Button("Side View") { model.scene.rig.set(.side) }.keyboardShortcut("2")
                Button("Top View") { model.scene.rig.set(.top) }.keyboardShortcut("3")
                Button("3D View") { model.scene.rig.set(.threeD) }.keyboardShortcut("4")
                Button("Fit Board") { model.scene.rig.fit(model.board) }.keyboardShortcut("0")
                Toggle("Snap to Slots", isOn: $model.snapToSlots)
                Divider()
            }
        }
    }
}

/// Update menu state shown in the app menu.
final class UpdateState: ObservableObject {
    static let shared = UpdateState()
    @Published var title = "Check for Updates…"
    @Published var installing = false

    func refresh(checking: Bool = false) {
        if installing { title = "Installing Update…" }
        else if checking { title = "Checking for Updates…" }
        else if let m = Updater.shared.available { title = "⬆︎ Install Update to v\(m.version)…" }
        else { title = "Check for Updates…" }
        if let tile = NSApp?.dockTile { tile.badgeLabel = Updater.shared.available != nil ? "↑" : nil }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.onChange = { UpdateState.shared.refresh() }
        Updater.shared.startAutomaticChecks()
        reportFailedUpdateIfAny()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Layouts and models opened from Finder or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addFiles(urls)
    }

    func checkForUpdates() {
        if let m = Updater.shared.available { offerInstall(m); return }
        UpdateState.shared.refresh(checking: true)
        Updater.shared.check { [weak self] result in
            UpdateState.shared.refresh()
            switch result {
            case .success(let m?):
                self?.offerInstall(m)
            case .success(nil):
                let alert = NSAlert()
                alert.messageText = "SkadisModeler is up to date"
                alert.informativeText = "You're running v\(AppVersion.version), the newest version available."
                alert.runModal()
            case .failure(let error):
                self?.showUpdateError(error)
            }
        }
    }

    private func offerInstall(_ m: UpdateManifest) {
        let alert = NSAlert()
        alert.messageText = "Update to SkadisModeler v\(m.version)?"
        var info = "You have v\(AppVersion.version)."
        if let notes = m.notes, !notes.isEmpty { info += "\n\nWhat's new:\n\(notes)" }
        info += "\n\nSkadisModeler will quit, update itself and reopen. The board you're working on, your saved layouts and your settings are kept."
            + "\n\nNo permissions need granting again: SkadisModeler uses none."
        alert.informativeText = info
        alert.addButton(withTitle: "Install and Relaunch")
        alert.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        UpdateState.shared.installing = true
        UpdateState.shared.refresh()
        Updater.shared.install(m) { [weak self] error in
            UpdateState.shared.installing = false
            UpdateState.shared.refresh()
            self?.showUpdateError(error)
        }
    }

    private func showUpdateError(_ error: Error) {
        let e = AppError(wrapping: error)
        ErrorReporter.shared.log(e)
        let sourceProblem = e.code == .noUpdateSource || e.code == .badUpdateSource
        let picked = ErrorReporter.shared.present(e, title: "Couldn't update SkadisModeler",
                                                  actions: sourceProblem ? ["Set Update Source…"] : [])
        if picked == 0 { editUpdateSource() }
    }

    private func reportFailedUpdateIfAny() {
        let marker = Updater.swapFailureMarker
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: marker)
        let parts = text.split(separator: "|", maxSplits: 1).map(String.init)
        let code = parts.first.flatMap { ErrorCode(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            ?? .updateSwapFailed
        ErrorReporter.shared.report(AppError(code, parts.count > 1 ? parts[1] : nil),
                                    surface: .alert, title: "Couldn't install the update")
    }

    func editUpdateSource() {
        let alert = NSAlert()
        alert.messageText = "Update Source"
        alert.informativeText = "Where SkadisModeler looks for new versions: a web link or a file path to a latest.json feed. "
            + "Leave it empty to use the built-in source"
            + (AppVersion.updateFeed.isEmpty ? " (none in this build)." : ":\n\(AppVersion.updateFeed)")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 380, height: 24))
        field.stringValue = UserDefaults.standard.string(forKey: "updateFeed") ?? ""
        field.placeholderString = AppVersion.updateFeed.isEmpty ? "https://…/latest.json" : AppVersion.updateFeed
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty && Updater.url(from: value) == nil {
            showUpdateError(AppError(.badUpdateSource, value))
            return
        }
        Updater.shared.feed = value
        Updater.shared.check { _ in }
    }
}
