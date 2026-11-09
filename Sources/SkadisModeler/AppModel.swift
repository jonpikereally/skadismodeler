import AppKit
import Combine
import simd

struct AnalysisKey: Hashable {
    let path: String
    let part: Int
    let orientation: Orientation
}

struct LibraryGroup: Identifiable {
    let id: String
    let name: String
    let files: [URL]
}

/// The board, what's hung on it, and everything the window can do to them.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var board = Board.standard
    @Published private(set) var items: [PlacedItem] = []
    @Published var selection: UUID? { didSet { if selection != oldValue { scene.sync(self) } } }
    @Published private(set) var issues: [UUID: [Issue]] = [:]
    /// Items whose model file couldn't be loaded (moved, deleted, damaged).
    @Published private(set) var missing: Set<UUID> = []
    @Published private(set) var loading = 0
    @Published var lastError: AppError?
    @Published var snapToSlots = true
    @Published private(set) var library: [LibraryGroup] = []
    @Published private(set) var libraryFolder: URL?
    @Published private(set) var fileURL: URL?

    let scene = BoardScene()
    let undo = UndoManager()

    private var meshes: [String: [NamedMesh]] = [:]
    private var analyses: [AnalysisKey: Analysis] = [:]
    private let work = DispatchQueue(label: "com.jonpike.skadismodeler.load", qos: .userInitiated)
    private var autosave: DispatchWorkItem?
    private var dragStart: (Board, [PlacedItem])?
    private let persists: Bool

    static let supportFolder: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkadisModeler", isDirectory: true)
    }()
    static let autosaveURL = supportFolder.appendingPathComponent("autosave.skadis")

    /// `persists: false` (tests, snapshots) neither restores nor writes the remembered layout.
    init(persists: Bool = true) {
        self.persists = persists
        if persists {
            if let path = UserDefaults.standard.string(forKey: "libraryFolder") {
                libraryFolder = URL(fileURLWithPath: path)
                scanLibrary(reportErrors: false)
            }
            if let data = try? Data(contentsOf: Self.autosaveURL),
               let layout = try? JSONDecoder().decode(Layout.self, from: data), layout.version <= Layout.currentVersion {
                apply(layout)
            }
        }
        scene.sync(self)
    }

    // MARK: Looking things up

    func item(_ id: UUID?) -> PlacedItem? { id.flatMap { id in items.first { $0.id == id } } }
    var selected: PlacedItem? { item(selection) }

    func analysis(for item: PlacedItem) -> Analysis? {
        analyses[AnalysisKey(path: item.path, part: item.part, orientation: item.orientation)]
    }

    var checker: LayoutChecker { LayoutChecker(board: board) }

    func position(of item: PlacedItem) -> V3 { checker.position(item) }

    var problemCount: Int { issues.values.reduce(0) { $0 + $1.filter(\.isProblem).count } + missing.count }

    func hasProblem(_ id: UUID) -> Bool { missing.contains(id) || (issues[id] ?? []).contains(where: \.isProblem) }

    var summary: String {
        if loading > 0 { return "Loading \(loading) model\(loading == 1 ? "" : "s")…" }
        if items.isEmpty { return "Add STL or 3MF models with the + button, or drop them on the board." }
        let n = problemCount
        let count = "\(items.count) model\(items.count == 1 ? "" : "s") on \(board.label)"
        return n == 0 ? "\(count). Everything fits." : "\(count). \(n) problem\(n == 1 ? "" : "s") to look at."
    }

    // MARK: Errors

    func report(_ error: Error, alert: Bool = true) {
        let e = AppError(wrapping: error)
        lastError = e
        ErrorReporter.shared.report(e, surface: alert ? .alert : .logOnly)
    }

    // MARK: Changes and undo

    private func registerUndo(_ before: (Board, [PlacedItem]), _ name: String) {
        undo.registerUndo(withTarget: self) { m in
            let now = (m.board, m.items)
            m.board = before.0
            m.items = before.1
            if let s = m.selection, !m.items.contains(where: { $0.id == s }) { m.selection = nil }
            m.registerUndo(now, name)
            m.prepareAnalyses { m.refresh() }
        }
        undo.setActionName(name)
    }

    private func mutate(_ name: String, _ change: () -> Void) {
        let before = (board, items)
        change()
        guard before.0 != board || before.1 != items else { return }
        registerUndo(before, name)
        refresh()
    }

    /// Recheck every item, redraw, and remember the layout.
    func refresh() {
        let c = checker
        let placed: [(PlacedItem, Analysis)] = items.compactMap { i in analysis(for: i).map { (i, $0) } }
        var out: [UUID: [Issue]] = [:]
        for (item, a) in placed { out[item.id] = c.issues(for: item, analysis: a, others: placed) }
        issues = out
        scene.sync(self)
        guard persists else { return }
        autosave?.cancel()
        let task = DispatchWorkItem { [weak self] in self?.writeAutosave() }
        autosave = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
    }

    private func writeAutosave() {
        do {
            try FileManager.default.createDirectory(at: Self.supportFolder, withIntermediateDirectories: true)
            try JSONEncoder().encode(Layout(board: board, items: items)).write(to: Self.autosaveURL, options: .atomic)
        } catch {
            report(AppError(.autosaveFailed, error.localizedDescription), alert: false)
        }
    }

    func update(_ id: UUID, _ name: String, _ change: (inout PlacedItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        mutate(name) { change(&items[i]) }
    }

    // MARK: Board

    func setBoard(preset id: String) {
        guard let p = Board.presets.first(where: { $0.id == id }) else { return }
        var b = p.make()
        b.finish = board.finish
        replaceBoard(b)
    }

    func setCustomBoard(width: Float, height: Float) {
        var b = Board.centred("custom", width: width, height: height)
        b.finish = board.finish
        replaceBoard(b)
    }

    func setFinish(_ f: Board.Finish) { mutate("Change Board Colour") { board.finish = f } }

    private func replaceBoard(_ b: Board) {
        let sizeChanged = b.width != board.width || b.height != board.height
        mutate("Change Board") {
            // Keep every item where it was, measured from the top-left corner like you'd hang it.
            let old = checker
            let moved = items.map { item -> PlacedItem in
                var item = item
                let p = old.position(item)
                let s = b.nearestSlot(to: V2(p.x - item.dx, b.height - (board.height - (p.y - item.dy))))
                item.column = s.0
                item.level = s.1
                return item
            }
            board = b
            items = moved
        }
        if sizeChanged { scene.rig.fit(board) }
    }

    // MARK: Adding models

    func addFiles(_ urls: [URL]) {
        let models = urls.filter(ModelFile.isModel)
        if let layout = urls.first(where: { $0.pathExtension.lowercased() == "skadis" }) { open(layout) }
        if models.isEmpty, let odd = urls.first(where: { $0.pathExtension.lowercased() != "skadis" }) {
            report(AppError(.unsupportedModelType, odd.lastPathComponent))
        }
        for url in models {
            let path = url.path
            let cached = meshes[path]
            loading += 1
            work.async {
                let result = Result { () -> ([NamedMesh], [(Orientation, Analysis)]) in
                    let parts = try cached ?? ModelFile.load(url)
                    return (parts, parts.map { part in
                        let o = Analysis.bestOrientation(for: part.mesh)
                        return (o, Analysis(mesh: part.mesh, orientation: o))
                    })
                }
                DispatchQueue.main.async {
                    self.loading -= 1
                    switch result {
                    case .failure(let error): self.report(error)
                    case .success(let (parts, analysed)): self.place(path: path, parts: parts, analysed: analysed)
                    }
                }
            }
        }
    }

    private func place(path: String, parts: [NamedMesh], analysed: [(Orientation, Analysis)]) {
        meshes[path] = parts
        mutate(parts.count == 1 ? "Add Model" : "Add Models") {
            for (n, part) in parts.enumerated() {
                let (o, a) = analysed[n]
                analyses[AnalysisKey(path: path, part: n, orientation: o)] = a
                let others: [(PlacedItem, Analysis)] = items.compactMap { i in analysis(for: i).map { (i, $0) } }
                let slot = checker.freeSlot(for: a, among: others)
                let item = PlacedItem(path: path, part: n, name: part.name.replacingOccurrences(of: "_", with: " "), orientation: o, column: slot.0, level: slot.1,
                                      color: RGB.palette[items.count % RGB.palette.count])
                items.append(item)
                selection = item.id
            }
        }
    }

    /// Make sure every item has its model loaded and measured (after opening a layout or an undo).
    private func prepareAnalyses(then done: @escaping () -> Void) {
        let needed = items.filter { analysis(for: $0) == nil }
        guard !needed.isEmpty else { done(); return }
        let cached = meshes
        loading += 1
        work.async {
            var loaded: [String: [NamedMesh]] = [:]
            var made: [(AnalysisKey, Analysis)] = []
            var failed: [String: AppError] = [:]
            for item in needed {
                let key = AnalysisKey(path: item.path, part: item.part, orientation: item.orientation)
                if made.contains(where: { $0.0 == key }) || failed[item.path] != nil { continue }
                do {
                    let parts: [NamedMesh]
                    if let p = cached[item.path] ?? loaded[item.path] { parts = p } else {
                        guard FileManager.default.fileExists(atPath: item.path) else {
                            throw AppError(.modelMissing, (item.path as NSString).abbreviatingWithTildeInPath)
                        }
                        parts = try ModelFile.load(URL(fileURLWithPath: item.path))
                        loaded[item.path] = parts
                    }
                    guard item.part < parts.count else {
                        throw AppError(.modelMissing, "\((item.path as NSString).lastPathComponent) no longer has an object \(item.part + 1)")
                    }
                    made.append((key, Analysis(mesh: parts[item.part].mesh, orientation: item.orientation)))
                } catch {
                    failed[item.path] = AppError(wrapping: error)
                }
            }
            DispatchQueue.main.async {
                self.loading -= 1
                for (path, parts) in loaded { self.meshes[path] = parts }
                for (key, a) in made { self.analyses[key] = a }
                self.missing = Set(self.items.filter { self.analysis(for: $0) == nil }.map(\.id))
                if let first = failed.values.first {
                    let extra = failed.count > 1 ? " (and \(failed.count - 1) more)" : ""
                    self.report(AppError(first.code, (first.detail ?? "") + extra))
                }
                done()
            }
        }
    }

    // MARK: Editing items

    func remove(_ id: UUID) {
        mutate("Remove Model") {
            items.removeAll { $0.id == id }
            missing.remove(id)
            if selection == id { selection = nil }
        }
    }

    func duplicate(_ id: UUID) {
        guard let src = item(id), let a = analysis(for: src) else { return }
        mutate("Duplicate Model") {
            let others: [(PlacedItem, Analysis)] = items.compactMap { i in analysis(for: i).map { (i, $0) } }
            let slot = checker.freeSlot(for: a, among: others)
            var copy = src
            copy.id = UUID()
            copy.column = slot.0
            copy.level = slot.1
            copy.dx = 0; copy.dy = 0; copy.dz = 0
            copy.color = RGB.palette[items.count % RGB.palette.count]
            items.append(copy)
            selection = copy.id
        }
    }

    /// Quarter turn about a board axis: 0 tips it (x), 1 swings it (y), 2 spins it flat against the board (z).
    func turn(_ id: UUID, about axis: Int) { reorient(id) { $0.turned(about: axis) } }

    func resetOrientation(_ id: UUID) {
        guard let it = item(id), let mesh = meshes[it.path]?[safe: it.part]?.mesh else { return }
        reorient(id) { _ in Analysis.bestOrientation(for: mesh) }
    }

    private func reorient(_ id: UUID, _ change: (Orientation) -> Orientation) {
        guard let it = item(id), let mesh = meshes[it.path]?[safe: it.part]?.mesh else { return }
        let o = change(it.orientation)
        let key = AnalysisKey(path: it.path, part: it.part, orientation: o)
        if analyses[key] == nil { analyses[key] = Analysis(mesh: mesh, orientation: o) }
        update(id, "Turn Model") { $0.orientation = o }
    }

    /// Step the selected item across the slots: dc columns (40 mm each) and dl slots up (40 mm each).
    /// `half` moves a single column instead, which also shifts it 20 mm down or up to the stagger.
    func step(_ id: UUID, dc: Int, dl: Int, half: Bool = false) {
        guard let it = item(id) else { return }
        var c = it.column + dc * (half ? 1 : 2), l = it.level + dl * 2
        if half && dc != 0 { l += board.hasSlot(c, l - 1) ? -1 : 1 }
        c = min(max(c, 0), board.columns - 1)
        l = min(max(l, 0), board.levels - 1)
        guard board.hasSlot(c, l) else { return }
        update(id, "Move Model") { $0.column = c; $0.level = l }
    }

    // MARK: Dragging

    func beginDrag() { dragStart = (board, items) }

    /// Move an item's anchor to a point on the board, snapping to the nearest slot.
    func drag(_ id: UUID, to p: V2) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var it = items[i]
        if snapToSlots {
            let s = board.nearestSlot(to: p)
            (it.column, it.level, it.dx, it.dy) = (s.0, s.1, 0, 0)
        } else {
            let s = board.nearestSlot(to: p)
            let c = board.slotCentre(s.0, s.1)
            (it.column, it.level) = s
            it.dx = (p.x - c.x).rounded()
            it.dy = (p.y - c.y).rounded()
        }
        guard it != items[i] else { return }
        items[i] = it
        refresh()
    }

    func endDrag() {
        if let before = dragStart, before.1 != items { registerUndo(before, "Move Model") }
        dragStart = nil
    }

    // MARK: Layout files

    private func apply(_ layout: Layout) {
        board = layout.board
        items = layout.items.filter { $0.orientation.isValid }
        selection = nil
        missing = []
        undo.removeAllActions()
        scene.rig.fit(board)
        prepareAnalyses { self.refresh() }
    }

    func newLayout() {
        fileURL = nil
        apply(Layout(board: board, items: []))
        refresh()
    }

    func open(_ url: URL) {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            report(AppError(.layoutUnreadable, "\(url.lastPathComponent) — \(error.localizedDescription)")); return
        }
        guard let layout = try? JSONDecoder().decode(Layout.self, from: data) else {
            report(AppError(.layoutMalformed, url.lastPathComponent)); return
        }
        guard layout.version <= Layout.currentVersion else {
            report(AppError(.layoutMalformed, "\(url.lastPathComponent) is layout version \(layout.version); this SkadisModeler reads up to \(Layout.currentVersion)")); return
        }
        fileURL = url
        apply(layout)
    }

    func save(to url: URL) {
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(Layout(board: board, items: items)).write(to: url, options: .atomic)
            fileURL = url
        } catch {
            report(AppError(.layoutWriteFailed, "\(url.lastPathComponent) — \(error.localizedDescription)"))
        }
    }

    // MARK: Panels

    func chooseModels() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ModelFile.extensions
        panel.message = "Choose STL or 3MF models to hang on the board"
        panel.prompt = "Add"
        if let folder = libraryFolder { panel.directoryURL = folder }
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }

    func chooseLayout() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["skadis"]
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func saveLayout(asNew: Bool = false) {
        if !asNew, let url = fileURL { save(to: url); return }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["skadis"]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Board layout.skadis"
        if panel.runModal() == .OK, let url = panel.url { save(to: url) }
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder that holds your SKÅDIS designs"
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryFolder = url
        UserDefaults.standard.set(url.path, forKey: "libraryFolder")
        scanLibrary(reportErrors: true)
    }

    /// Every STL and 3MF under the library folder, grouped by the folder it's in. Superseded
    /// designs, loose parts and sliced files are left out, and an STL is hidden when a 3MF of
    /// the same name sits next to it.
    func scanLibrary(reportErrors: Bool = true) {
        guard let root = libraryFolder else { library = []; return }
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]),
              (try? root.checkResourceIsReachable()) == true else {
            library = []
            if reportErrors { report(AppError(.libraryUnreadable, (root.path as NSString).abbreviatingWithTildeInPath)) }
            return
        }
        let skipped: Set<String> = ["earlier designs", "parts", "old", "archive"]
        var byFolder: [String: [URL]] = [:]
        for case let url as URL in e {
            if skipped.contains(url.lastPathComponent.lowercased()) { e.skipDescendants(); continue }
            if e.level > 4 { e.skipDescendants(); continue }
            if ModelFile.isModel(url) { byFolder[url.deletingLastPathComponent().path, default: []].append(url) }
        }
        library = byFolder.map { folder, files in
            let threeMFs = Set(files.filter { $0.pathExtension.lowercased() == "3mf" }.map { $0.deletingPathExtension().lastPathComponent })
            let kept = files.filter { $0.pathExtension.lowercased() == "3mf" || !threeMFs.contains($0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let name = folder == root.path ? root.lastPathComponent : String(folder.dropFirst(root.path.count + 1))
            return LibraryGroup(id: folder, name: name, files: kept)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

extension BoardScene {
    func sync(_ model: AppModel) {
        show(board: model.board, items: model.items.compactMap { item in
            model.analysis(for: item).map {
                Shown(item: item, analysis: $0, position: model.position(of: item),
                      selected: model.selection == item.id, problem: model.hasProblem(item.id))
            }
        })
    }
}
