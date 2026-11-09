import AppKit

/// Every failure a user can run into has a stable code, so it can be looked up
/// on the public error list (ERRORS.md) or pasted into an LLM. Add new codes
/// here and to ERRORS.md together, and never show an error without one.
/// Codes are never reused or renumbered: 1xx updates, 2xx model files,
/// 3xx layouts and the library, 6xx installer scripts, 999 anything else.
enum ErrorCode: String, CaseIterable {
    case noUpdateSource = "SM-101"
    case badUpdateSource = "SM-102"
    case updateSourceUnreachable = "SM-103"
    case updateServerError = "SM-104"
    case updateInfoMalformed = "SM-105"
    case updateDownloadFailed = "SM-106"
    case updateUnpackFailed = "SM-107"
    case updateMissingApp = "SM-108"
    case updateWrongApp = "SM-109"
    case updateDamagedApp = "SM-110"
    case updateInstallerFailed = "SM-111"
    case updateSwapFailed = "SM-112"
    case modelUnreadable = "SM-201"
    case badSTL = "SM-202"
    case bad3MF = "SM-203"
    case empty3MF = "SM-204"
    case unsupportedModelType = "SM-205"
    case modelMissing = "SM-206"
    case layoutUnreadable = "SM-301"
    case layoutMalformed = "SM-302"
    case layoutWriteFailed = "SM-303"
    case autosaveFailed = "SM-304"
    case libraryUnreadable = "SM-305"
    case unexpected = "SM-999"

    var summary: String {
        switch self {
        case .noUpdateSource: return "No update source is set."
        case .badUpdateSource: return "The update source isn't a web link or a file path."
        case .updateSourceUnreachable: return "Couldn't reach the update source."
        case .updateServerError: return "The update server returned an error."
        case .updateInfoMalformed: return "The update information is damaged or in the wrong format."
        case .updateDownloadFailed: return "Couldn't download the update."
        case .updateUnpackFailed: return "Couldn't unpack the downloaded update."
        case .updateMissingApp: return "The downloaded update doesn't contain SkadisModeler."
        case .updateWrongApp: return "The downloaded update is a different app."
        case .updateDamagedApp: return "The downloaded update is damaged."
        case .updateInstallerFailed: return "Couldn't start installing the update."
        case .updateSwapFailed: return "Installing the update failed, so the previous version was kept."
        case .modelUnreadable: return "Couldn't open the model file."
        case .badSTL: return "That STL file is damaged or isn't an STL."
        case .bad3MF: return "That 3MF file is damaged or isn't a 3MF."
        case .empty3MF: return "That 3MF file has no 3D objects in it."
        case .unsupportedModelType: return "SkadisModeler can't open that kind of file."
        case .modelMissing: return "A model used by this layout couldn't be found."
        case .layoutUnreadable: return "Couldn't open the layout file."
        case .layoutMalformed: return "That file isn't a SkadisModeler layout, or it's damaged."
        case .layoutWriteFailed: return "Couldn't save the layout file."
        case .autosaveFailed: return "Couldn't remember the current layout for next time."
        case .libraryUnreadable: return "Couldn't read the library folder."
        case .unexpected: return "Something unexpected went wrong."
        }
    }

    var hint: String {
        switch self {
        case .noUpdateSource: return "Set one with “Update Source…” in the SkadisModeler menu, or leave it empty to use the built-in source."
        case .badUpdateSource: return "Set one with “Update Source…” in the SkadisModeler menu, or leave it empty to use the built-in source."
        case .updateSourceUnreachable: return "Check your internet connection and try again."
        case .updateServerError: return "Try again in a few minutes. If it keeps happening, download the latest version from GitHub."
        case .updateInfoMalformed: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateDownloadFailed: return "Try again in a few minutes. If it keeps happening, download the latest version from GitHub."
        case .updateUnpackFailed: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateMissingApp: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateWrongApp: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateDamagedApp: return "The published update is broken. Download the latest version from GitHub instead."
        case .updateInstallerFailed: return "Make sure SkadisModeler is in ~/Applications and that the folder isn't locked, then try again."
        case .updateSwapFailed: return "Make sure SkadisModeler is in ~/Applications and that the folder isn't locked, then try again."
        case .modelUnreadable: return "Check the file is still where it was and that its folder isn't locked. If it lives in a cloud folder, make sure it has finished downloading."
        case .badSTL: return "Export the STL again from your CAD program or slicer and add the new file."
        case .bad3MF: return "Save the 3MF again from your slicer or CAD program and add the new file. If it still fails, export an STL instead."
        case .empty3MF: return "Open it in your slicer to check it has at least one object, or add the STL instead."
        case .unsupportedModelType: return "Add STL or 3MF files. Export STEP, OBJ or CAD source files to STL first."
        case .modelMissing: return "The file was moved, renamed or deleted. Put it back, or remove the item and add the model again from its new place."
        case .layoutUnreadable: return "Check the file is still where it was and that its folder isn't locked."
        case .layoutMalformed: return "Open a .skadis file saved by SkadisModeler. If it was made by a newer version, update SkadisModeler first."
        case .layoutWriteFailed: return "Check the folder isn't locked and there's space on the disk, then try again."
        case .autosaveFailed: return "Check there's space on the disk and that ~/Library/Application Support/SkadisModeler isn't locked. Save the layout to a file so nothing is lost."
        case .libraryUnreadable: return "Pick the folder again with Choose Folder in the Library list, and allow access if macOS asks."
        case .unexpected: return "Try again. If it keeps happening, copy the details and ask for help."
        }
    }
}
struct AppError: LocalizedError {
    let code: ErrorCode
    /// Technical specifics (file names, system messages). Never file contents.
    let detail: String?

    init(_ code: ErrorCode, _ detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    init(wrapping error: Error, as code: ErrorCode = .unexpected) {
        if let e = error as? AppError { self = e } else { self.init(code, error.localizedDescription) }
    }

    var errorDescription: String? { "\(code.summary) (\(code.rawValue))" }
}

/// Logs every error to ~/Library/Application Support/SkadisModeler/errors.log and
/// shows it with its code.
final class ErrorReporter {
    enum Surface { case alert, logOnly }

    static let shared = ErrorReporter()
    static let helpURL = "https://github.com/\(AppVersion.repo)/blob/main/ERRORS.md"
    static let plainTextHelpURL = "https://raw.githubusercontent.com/\(AppVersion.repo)/main/ERRORS.md"
    static let tooltip = "Look up this error code on the SkadisModeler error list: \(helpURL)\n"
        + "You can also give that page and the copied error details to an AI assistant for help."

    private var lastLogged: [ErrorCode: Date] = [:]

    static let logURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkadisModeler", isDirectory: true)
            .appendingPathComponent("errors.log")
    }()

    func report(_ error: AppError, surface: Surface, title: String = "SkadisModeler ran into a problem") {
        DispatchQueue.main.async {
            self.log(error)
            if surface == .alert { self.present(error, title: title) }
        }
    }

    @discardableResult
    func present(_ error: AppError, title: String, actions: [String] = []) -> Int? {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        var text = error.code.summary
        if let d = error.detail, !d.isEmpty { text += "\n\n\(d)" }
        text += "\n\n\(error.code.hint)\n\nError code: \(error.code.rawValue)"
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        for a in actions { alert.addButton(withTitle: a) }
        alert.addButton(withTitle: "Copy Error Details")
        alert.addButton(withTitle: "Open Error List")
        Self.addTooltips(to: alert)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if response == actions.count + 1 {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(Self.details(error), forType: .string)
            return nil
        }
        if response == actions.count + 2 {
            if let url = URL(string: Self.helpURL) { NSWorkspace.shared.open(url) }
            return nil
        }
        if response >= 1 && response <= actions.count { return response - 1 }
        return nil
    }

    static func addTooltips(to alert: NSAlert) {
        alert.layout()
        func walk(_ view: NSView) {
            if view is NSTextField { view.toolTip = tooltip }
            view.subviews.forEach(walk)
        }
        if let content = alert.window.contentView {
            content.toolTip = tooltip
            walk(content)
        }
    }

    static func details(_ error: AppError) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = "Apple Silicon"
        #else
        let arch = "Intel"
        #endif
        var lines = ["SkadisModeler error \(error.code.rawValue): \(error.code.summary)"]
        if let d = error.detail, !d.isEmpty { lines.append("Details: \(d)") }
        lines.append("Suggested fix: \(error.code.hint)")
        lines.append("SkadisModeler v\(AppVersion.version) (built \(AppVersion.built)), macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(arch)")
        lines.append("Time: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("Error code list: \(helpURL)")
        lines.append("Plain-text error list for AI assistants: \(plainTextHelpURL)")
        return lines.joined(separator: "\n")
    }

    func log(_ error: AppError) {
        let now = Date()
        if let last = lastLogged[error.code], now.timeIntervalSince(last) < 60 { return }
        lastLogged[error.code] = now
        let line = "\(ISO8601DateFormatter().string(from: now)) \(error.code.rawValue) v\(AppVersion.version) "
            + error.code.summary + (error.detail.map { " — \($0)" } ?? "") + "\n"
        let url = Self.logURL
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
