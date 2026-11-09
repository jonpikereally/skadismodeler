import AppKit
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

struct BoardViewport: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> BoardView {
        let v = BoardView(frame: .zero, options: nil)
        v.model = model
        v.scene = model.scene.scene
        v.pointOfView = model.scene.rig.node
        v.allowsCameraControl = false
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .clear
        return v
    }

    func updateNSView(_ v: BoardView, context: Context) {}
}

extension RGB {
    var color: Color { Color(red: r, green: g, blue: b) }

    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .gray
        self.init(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent))
    }
}

private func mm(_ v: Float) -> String {
    abs(v - v.rounded()) < 0.05 ? String(format: "%.0f", v) : String(format: "%.1f", v)
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                Sidebar()
                    .frame(minWidth: 210, idealWidth: 250, maxWidth: 360)
                ZStack(alignment: .topLeading) {
                    BoardViewport(model: model)
                    ViewButtons()
                        .padding(10)
                    if model.items.isEmpty && model.loading == 0 {
                        EmptyHint()
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 28)
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                Inspector()
                    .frame(width: 280)
            }
            Divider()
            StatusBar()
        }
        .frame(minWidth: 980, minHeight: 600)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { model.addFiles([url]) } }
                }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.chooseModels() } label: { Label("Add Models", systemImage: "plus") }
                    .help("Add STL or 3MF models to the board")
            }
            ToolbarItemGroup {
                Toggle(isOn: $model.snapToSlots) { Label("Snap to Slots", systemImage: "square.grid.3x3.square") }
                    .help("While dragging, keep models on the board's slots. Turn off to place them freely, to the millimetre.")
                Button { model.scene.rig.fit(model.board) } label: { Label("Fit Board", systemImage: "arrow.up.left.and.arrow.down.right") }
                    .help("Frame the whole board")
            }
        }
    }
}

struct EmptyHint: View {
    var body: some View {
        Text("Drop STL or 3MF models here, or click + to add them.\nDrag a model to move it between slots. Drag the board to look around, scroll to zoom.")
            .font(.callout)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
    }
}

struct ViewButtons: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            button("Front", .front, "Look straight at the board (⌘1)")
            button("Side", .side, "Look along the board to see how far things stick out (⌘2)")
            button("Top", .top, "Look down from above (⌘3)")
            button("3D", .threeD, "Angled view (⌘4)")
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func button(_ title: String, _ preset: CameraRig.Preset, _ help: String) -> some View {
        Button(title) { model.scene.rig.set(preset) }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(help)
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            Section("On the board") {
                if model.items.isEmpty {
                    Text("Nothing yet").foregroundStyle(.secondary)
                }
                ForEach(model.items) { item in
                    ItemRow(item: item)
                }
            }
            Section {
                if model.libraryFolder == nil {
                    Text("Choose the folder that holds your designs to list them here.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if model.library.isEmpty {
                    Text("No STL or 3MF files in that folder.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.library) { group in
                    DisclosureGroup {
                        ForEach(group.files, id: \.path) { url in
                            LibraryRow(url: url)
                        }
                    } label: {
                        Label(group.name, systemImage: "folder").lineLimit(1)
                    }
                }
            } header: {
                HStack {
                    Text("Library")
                    Spacer()
                    if model.libraryFolder != nil {
                        Button { model.scanLibrary() } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("Look for new files in the library folder")
                    }
                    Button(model.libraryFolder == nil ? "Choose Folder…" : "Change…") { model.chooseLibraryFolder() }
                        .buttonStyle(.borderless).font(.caption)
                        .help(model.libraryFolder.map { "Library folder: \(($0.path as NSString).abbreviatingWithTildeInPath)" }
                              ?? "Pick the folder that holds your SKÅDIS designs")
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct ItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: PlacedItem

    var body: some View {
        let selected = model.selection == item.id
        HStack(spacing: 6) {
            Circle().fill(item.color.color).frame(width: 10, height: 10)
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            if model.hasProblem(item.id) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    .help(model.missing.contains(item.id) ? "Its model file couldn't be loaded"
                          : (model.issues[item.id] ?? []).filter(\.isProblem).map(\.text).joined(separator: "\n"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = item.id }
        .listRowBackground(selected ? Color.accentColor.opacity(0.25) : Color.clear)
        .contextMenu {
            Button("Duplicate") { model.duplicate(item.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Divider()
            Button("Remove from Board") { model.remove(item.id) }
        }
    }
}

struct LibraryRow: View {
    @EnvironmentObject var model: AppModel
    let url: URL

    var body: some View {
        HStack(spacing: 4) {
            Text(url.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 2)
            Button { model.addFiles([url]) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("Hang this model on the board")
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.addFiles([url]) }
        .help("Double-click to hang it on the board")
    }
}

// MARK: Inspector

struct Inspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let item = model.selected {
                    ItemInspector(item: item)
                } else {
                    BoardInspector()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct Heading: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.headline) }
}

struct NumberField: View {
    let label: String
    let value: Float
    let set: (Float) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !$0 { commit() } }
                .onChange(of: value) { text = mm($0) }
                .onAppear { text = mm(value) }
        }
    }

    private func commit() {
        if let v = Float(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)), v.isFinite {
            if abs(v - value) > 0.001 { set(v) }
        }
        text = mm(value)
    }
}

struct BoardInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let b = model.board
        Heading("Board")
        Picker("", selection: Binding(get: { Board.presets.contains { $0.id == b.preset } ? b.preset : "custom" },
                                      set: { id in
                                          if id == "custom" { model.setCustomBoard(width: b.width, height: b.height) }
                                          else { model.setBoard(preset: id) }
                                      })) {
            ForEach(Board.presets) { Text($0.label).tag($0.id) }
            Divider()
            Text("Custom size").tag("custom")
        }
        .labelsHidden()
        if b.preset == "custom" {
            HStack {
                NumberField(label: "Wide", value: b.width) { model.setCustomBoard(width: $0, height: b.height) }
                NumberField(label: "Tall", value: b.height) { model.setCustomBoard(width: b.width, height: $0) }
                Text("mm").foregroundStyle(.secondary)
            }
        }
        Picker("Colour", selection: Binding(get: { b.finish }, set: { model.setFinish($0) })) {
            ForEach(Board.Finish.allCases) { Text($0.label).tag($0) }
        }
        Text("\(mm(b.width)) × \(mm(b.height)) mm, \(b.columns) columns, \(b.slotCount) slots. Slots are 5 × 15 mm, columns 20 mm apart, 40 mm between slots in a column.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if b.preset.hasPrefix("ikea") || b.preset == "custom" {
            Text("The slot pattern is centred on the board. Check the distance from a real board's edge to its first slot before trusting how close things sit to the edges.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        Divider()
        Heading("Fit")
        if model.items.isEmpty {
            Text("Add a model to see whether it fits.").foregroundStyle(.secondary)
        } else if model.problemCount == 0 {
            Label("Everything fits", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
        ForEach(model.items.filter { model.hasProblem($0.id) }) { item in
            Button { model.selection = item.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.name, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
                    ForEach(model.missing.contains(item.id) ? [Issue(isProblem: true, text: "Its model file couldn't be loaded.")]
                            : (model.issues[item.id] ?? []).filter(\.isProblem)) { issue in
                        Text(issue.text).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        Text("Click a model on the board or in the list to move, turn or recolour it.")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct ItemInspector: View {
    @EnvironmentObject var model: AppModel
    let item: PlacedItem

    var body: some View {
        let id = item.id
        let a = model.analysis(for: item)
        TextField("Name", text: Binding(get: { item.name }, set: { v in model.update(id, "Rename Model") { $0.name = v } }))
            .textFieldStyle(.roundedBorder)
            .font(.headline)
        Text((item.path as NSString).lastPathComponent)
            .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            .help((item.path as NSString).abbreviatingWithTildeInPath)

        if let a {
            Heading("Fit")
            let found = model.issues[id] ?? []
            if !found.contains(where: \.isProblem) {
                Label(a.hooks.isEmpty ? "Nothing in its way" : "Fits here", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(found) { issue in
                Label {
                    Text(issue.text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: issue.isProblem ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(issue.isProblem ? .red : .secondary)
                }
                .font(.callout)
            }

            Divider()
            Heading("Size")
            Text("\(mm(a.size.x)) wide × \(mm(a.size.y)) tall\nSticks out \(mm(a.depthInFront)) mm from the board")
                .fixedSize(horizontal: false, vertical: true)
            Text(hookText(a)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Divider()
            Heading("Position")
            let pos = model.position(of: item)
            HStack(spacing: 6) {
                Button { model.step(id, dc: -1, dl: 0) } label: { Image(systemName: "arrow.left") }.help("Move 40 mm left (←). Hold Option for one column, 20 mm.")
                VStack(spacing: 4) {
                    Button { model.step(id, dc: 0, dl: 1) } label: { Image(systemName: "arrow.up") }.help("Move up one slot, 40 mm (↑)")
                    Button { model.step(id, dc: 0, dl: -1) } label: { Image(systemName: "arrow.down") }.help("Move down one slot, 40 mm (↓)")
                }
                Button { model.step(id, dc: 1, dl: 0) } label: { Image(systemName: "arrow.right") }.help("Move 40 mm right (→). Hold Option for one column, 20 mm.")
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Column \(item.column + 1) of \(model.board.columns)")
                    Text("Slot \(mm(model.board.height - pos.y + item.dy)) mm from the top").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("Its edges: \(mm(pos.x + a.lower.x)) mm from the board's left, \(mm(model.board.width - pos.x - a.upper.x)) from the right, \(mm(model.board.height - pos.y - a.upper.y)) from the top, \(mm(pos.y + a.lower.y)) from the bottom.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NumberField(label: "→", value: item.dx) { v in model.update(id, "Nudge Model") { $0.dx = v } }
                NumberField(label: "↑", value: item.dy) { v in model.update(id, "Nudge Model") { $0.dy = v } }
            }
            .help("Fine offset from the slot, in millimetres, for seeing how much a design misses by")
            HStack(spacing: 8) {
                NumberField(label: "Off board", value: item.dz) { v in model.update(id, "Nudge Model") { $0.dz = max(0, v) } }
                if item.dx != 0 || item.dy != 0 || item.dz != 0 {
                    Button("Reset") { model.update(id, "Nudge Model") { $0.dx = 0; $0.dy = 0; $0.dz = 0 } }.controlSize(.small)
                }
            }

            Divider()
            Heading("Turn")
            HStack {
                Button { model.turn(id, about: 2) } label: { Label("Spin", systemImage: "arrow.counterclockwise") }
                    .help("Quarter turn flat against the board")
                Button { model.turn(id, about: 0) } label: { Label("Tip", systemImage: "arrow.up.and.down") }
                    .help("Quarter turn top-over-front, to change which face is against the board")
                Button { model.turn(id, about: 1) } label: { Label("Swing", systemImage: "arrow.left.and.right") }
                    .help("Quarter turn like a door, to change which face is against the board")
            }
            .controlSize(.small)
            Button("Find Hooks Again") { model.resetOrientation(id) }
                .controlSize(.small)
                .help("Turn the model back to the way its hooks face the board")
        } else {
            Label("Its model file couldn't be loaded. Put the file back where it was, or remove this and add the model again.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                .help(ErrorReporter.tooltip)
        }

        Divider()
        Heading("Colour")
        HStack(spacing: 5) {
            ForEach(RGB.palette, id: \.self) { c in
                Circle().fill(c.color).frame(width: 18, height: 18)
                    .overlay(Circle().stroke(Color.primary, lineWidth: item.color == c ? 2 : 0))
                    .onTapGesture { model.update(id, "Change Colour") { $0.color = c } }
            }
            ColorPicker("", selection: Binding(get: { item.color.color },
                                               set: { v in model.update(id, "Change Colour") { $0.color = RGB(v) } }),
                        supportsOpacity: false)
                .labelsHidden()
        }

        Divider()
        HStack {
            Button("Duplicate") { model.duplicate(id) }.disabled(a == nil)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Spacer()
        }
        .controlSize(.small)
        Button(role: .destructive) { model.remove(id) } label: { Label("Remove from Board", systemImage: "trash") }
            .controlSize(.small)
    }

    private func hookText(_ a: Analysis) -> String {
        if a.hooks.isEmpty { return "No hooks found" }
        if a.hooks.count == 1 { return "1 hook column" + (a.hooks[0].hasLower ? " with a lower peg" : "") }
        let gaps = zip(a.hooks, a.hooks.dropFirst()).map { mm($1.x - $0.x) }
        let same = Set(gaps).count == 1
        return "\(a.hooks.count) hook columns, \(same ? gaps[0] : gaps.joined(separator: " / ")) mm apart"
    }
}

// MARK: Status bar

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            if model.loading > 0 { ProgressView().controlSize(.small) }
            Text(model.summary).lineLimit(1)
            Spacer()
            if let e = model.lastError {
                Button {
                    ErrorReporter.shared.present(e, title: "SkadisModeler ran into a problem")
                } label: {
                    Label("\(e.code.rawValue): \(e.code.summary)", systemImage: "exclamationmark.triangle.fill").lineLimit(1)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(ErrorReporter.tooltip)
                Button { model.lastError = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
            }
        }
        .font(.callout)
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}
