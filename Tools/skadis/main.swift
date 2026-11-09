import AppKit
import Metal
import SceneKit
import simd

// skadis — SkadisModeler from the command line, so a script or an LLM can
// measure models, try a layout, check that it fits and look at it.
// Results are JSON on standard output; errors carry an SM- code on standard error.

let help = """
skadis \(AppVersion.version) — plan a SKÅDIS pegboard from the command line

  skadis boards                              the boards skadis knows, as JSON
  skadis inventory <models or folders…>      size and hooks of every STL / 3MF, as JSON
  skadis pack --board <board> <models…>      fit models in order from the top-left
  skadis arrange <plan.json>                 place models where a plan says
  skadis check <layout or plan>              where everything is and whether it fits, as JSON
  skadis render <layout or plan> -o <png>    draw it

Options
  --board <name>     a name from `skadis boards`, or a size in mm like 760x560
  -o, --out <file>   pack / arrange: write a .skadis layout (opens in SkadisModeler). render: the PNG
  --render <png>     pack / arrange: also draw the result
  --view <view>      front (default, flat, with name labels), side, top or 3d
  --size <WxH>       picture size in pixels (default 1600x1200)
  --no-labels        leave the names off the front view

pack, arrange and check all print the same report: for each model its slot (column, level),
its left and top edge in mm from the board's left and top edges, its width, height and how far
it sticks out, and a list of problems. "fits": true at the top means no problems anywhere.

The board
  Slots are 5 × 15 mm in columns 20 mm apart, 40 mm apart within a column, and every other
  column is shifted 20 mm. `column` counts from 0 at the left; `level` counts 20 mm steps from 0
  at the bottom. Only every other (column, level) pair is a real slot; check tells you if you
  picked a gap. A model hangs from the slot its left hook column goes into.

The plan (arrange, check and render read it; a saved .skadis layout works too)
  {"board": "ikea76x56",
   "items": [
     {"file": "Drill Holder/drill_holder.3mf", "left": 40, "top": 300},
     {"file": "hex_key_holder.3mf", "column": 20, "level": 25, "name": "Hex keys", "color": "#cc4444"},
     {"file": "pliers_holder.stl"}
   ]}
  file          STL or 3MF, absolute or relative to the plan's own folder. The only required field.
  left, top     where the model's left and top edges should be, in mm from the board's left and
                top edges. It's moved to the nearest slot, so read the report for where it landed.
  column, level the exact slot instead, if you'd rather.
  (neither)     fitted into the first free space after everything that was given a place, in order.
  part          which object of a 3MF with several (from 0; see inventory). name, color: optional.
  board         a board name, a size like "760x560", or {"width": 760, "height": 560}.

A good way to work
  1. skadis inventory <folder>         to learn every model's size and how far it sticks out
  2. write plan.json with a left/top for each model, leaving gaps for the tools themselves
  3. skadis arrange plan.json -o board.skadis --render board.png
  4. read the problems and look at the picture; fix the plan and repeat until "fits" is true
  5. open board.skadis in SkadisModeler to fine-tune by hand

What it doesn't check: room above a holder to lift its hooks in (about 6 mm), and room for the
tool that goes in the holder. IKEA's edge margins are approximate (the pattern is centred).
Drawing pictures needs the Mac's graphics, so run render from Terminal, not a sandbox.
Error codes: \(ErrorReporter.helpURL)
"""

func fail(_ error: Error) -> Never {
    let e = AppError(wrapping: error)
    var text = "Error \(e.code.rawValue): \(e.code.summary)\n"
    if let d = e.detail, !d.isEmpty { text += "  \(d)\n" }
    text += "  \(e.code.hint)\n  Error list: \(ErrorReporter.helpURL)\n"
    FileHandle.standardError.write(Data(text.utf8))
    exit(1)
}

func printJSON<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let data = try? enc.encode(value) { print(String(decoding: data, as: UTF8.self)) }
}

func round1(_ v: Float) -> Float { (v * 10).rounded() / 10 }

// MARK: Arguments

struct Options {
    var positional: [String] = []
    var out: String?
    var render: String?
    var board: String?
    var view = CameraRig.Preset.front
    var size = (1600, 1200)
    var labels = true
}

func parse(_ args: [String]) throws -> Options {
    var o = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < args.count else { throw AppError(.badUsage, "\(flag) needs a value") }
        return args[i]
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "-o", "--out": o.out = try value(a)
        case "--render": o.render = try value(a)
        case "--board": o.board = try value(a)
        case "--no-labels": o.labels = false
        case "--view":
            switch try value(a).lowercased() {
            case "front": o.view = .front
            case "side": o.view = .side
            case "top": o.view = .top
            case "3d": o.view = .threeD
            case let other: throw AppError(.badUsage, "--view \(other): use front, side, top or 3d")
            }
        case "--size":
            let v = try value(a)
            let parts = v.lowercased().split(separator: "x").compactMap { Int($0) }
            guard parts.count == 2, (200...8000).contains(parts[0]), (200...8000).contains(parts[1]) else {
                throw AppError(.badUsage, "--size \(v): use a size like 1600x1200")
            }
            o.size = (parts[0], parts[1])
        default:
            if a.hasPrefix("-") && a.count > 1 { throw AppError(.badUsage, "unknown option \(a)") }
            o.positional.append(a)
        }
        i += 1
    }
    return o
}

func fileURL(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL }

/// Model files named directly, plus those found under any folders (skipping superseded
/// designs and loose parts, and an STL when a 3MF of the same name sits beside it).
func modelFiles(_ paths: [String]) throws -> [URL] {
    var out: [URL] = []
    let fm = FileManager.default
    for p in paths {
        let url = fileURL(p)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { throw AppError(.modelMissing, url.path) }
        if !isDir.boolValue {
            guard ModelFile.isModel(url) else { throw AppError(.unsupportedModelType, url.lastPathComponent) }
            out.append(url)
            continue
        }
        let skipped: Set<String> = ["earlier designs", "parts", "old", "archive"]
        var found: [URL] = []
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                if skipped.contains(f.lastPathComponent.lowercased()) { e.skipDescendants(); continue }
                if ModelFile.isModel(f) { found.append(f.standardizedFileURL) }
            }
        }
        let threeMFs = Set(found.filter { $0.pathExtension.lowercased() == "3mf" }.map { $0.deletingPathExtension().path })
        out += found.filter { $0.pathExtension.lowercased() == "3mf" || !threeMFs.contains($0.deletingPathExtension().path) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    return out
}

func load(_ path: String) throws -> Resolved {
    let url = fileURL(path)
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
        throw AppError(.layoutUnreadable, "\(url.path) — \(error.localizedDescription)")
    }
    return try Planner.resolve(data, relativeTo: url.deletingLastPathComponent())
}

func write(_ r: Resolved, to path: String) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do { try enc.encode(r.layout).write(to: fileURL(path)) } catch {
        throw AppError(.outputWriteFailed, "\(path) — \(error.localizedDescription)")
    }
}

// MARK: Drawing

func render(_ r: Resolved, to path: String, options o: Options) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw AppError(.noGraphics) }
    let board = r.layout.board
    let checker = LayoutChecker(board: board)
    let placed = r.placed
    let report = Planner.report(r)
    let scene = BoardScene()
    scene.show(board: board, items: placed.enumerated().map { n, p in
        BoardScene.Shown(item: p.0, analysis: p.1, position: checker.position(p.0), problem: !report.items[n].fits)
    })
    let (w, h) = o.size
    scene.rig.aspect = Float(w) / Float(h)
    scene.rig.fit(board)
    scene.rig.set(o.view)
    let renderer = SCNRenderer(device: device, options: nil)
    renderer.scene = scene.scene
    renderer.pointOfView = scene.rig.node
    let shot = renderer.snapshot(atTime: 0, with: CGSize(width: w, height: h), antialiasingMode: .multisampling4X)
    guard let cg = shot.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw AppError(.noGraphics, "the picture came back empty") }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

    if o.view == .front && o.labels {
        // The front view has no perspective, so board millimetres map straight to pixels.
        let perMM = CGFloat(h) / 2 / CGFloat(scene.rig.node.camera?.orthographicScale ?? 1)
        let target = scene.rig.target
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = NSFont.boldSystemFont(ofSize: max(11, CGFloat(h) / 85))
        for (n, p) in placed.enumerated() {
            let pos = checker.position(p.0)
            let cx = CGFloat(w) / 2 + CGFloat(pos.x + (p.1.lower.x + p.1.upper.x) / 2 - target.x) * perMM
            let cy = CGFloat(h) / 2 + CGFloat(pos.y + (p.1.lower.y + p.1.upper.y) / 2 - target.y) * perMM
            let bad = !report.items[n].fits
            let text = NSAttributedString(string: (bad ? "⚠ " : "") + p.0.name, attributes: [
                .font: font, .foregroundColor: bad ? NSColor(calibratedRed: 0.7, green: 0, blue: 0, alpha: 1) : NSColor.black])
            let size = text.size()
            let box = CGRect(x: cx - size.width / 2 - 6, y: cy - size.height / 2 - 3, width: size.width + 12, height: size.height + 6)
            NSColor(white: 1, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()
            text.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    guard let image = ctx.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        throw AppError(.noGraphics, "couldn't encode the picture")
    }
    do { try png.write(to: fileURL(path)) } catch {
        throw AppError(.outputWriteFailed, "\(path) — \(error.localizedDescription)")
    }
}

/// Write the layout and the picture if asked, then print the report.
func finish(_ r: Resolved, _ o: Options) throws {
    if let out = o.out { try write(r, to: out) }
    if let png = o.render { try render(r, to: png, options: o) }
    printJSON(Planner.report(r))
}

// MARK: Commands

struct BoardRow: Encodable {
    let board: String
    let description: String
    let width: Float
    let height: Float
    let columns: Int
    let levels: Int
    let slots: Int
}

struct InventoryRow: Encodable {
    let file: String
    let part: Int
    let name: String
    let width: Float
    let height: Float
    let sticksOut: Float
    let hookColumns: Int
    /// Millimetres between neighbouring hook columns, left to right.
    let hookSpacing: [Float]
    /// From the slot the left hook column hangs in: how far the model reaches left, right, up and down.
    let reachLeft: Float
    let reachRight: Float
    let reachUp: Float
    let reachDown: Float
    let note: String?
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let command = args.first, !["help", "--help", "-h"].contains(command) else {
        print(help)
        exit(0)
    }
    let o = try parse(Array(args.dropFirst()))
    switch command {
    case "version", "--version":
        print(AppVersion.version)

    case "boards":
        printJSON(Board.presets.map { p -> BoardRow in
            let b = p.make()
            return BoardRow(board: p.id, description: p.label, width: b.width, height: b.height,
                            columns: b.columns, levels: b.levels, slots: b.slotCount)
        })

    case "inventory":
        guard !o.positional.isEmpty else { throw AppError(.badUsage, "inventory needs model files or folders") }
        var rows: [InventoryRow] = []
        for url in try modelFiles(o.positional) {
            for (n, part) in try ModelFile.load(url).enumerated() {
                let a = Analysis(mesh: part.mesh, orientation: Analysis.bestOrientation(for: part.mesh), measureFootprint: false)
                rows.append(InventoryRow(
                    file: url.path, part: n, name: part.name.replacingOccurrences(of: "_", with: " "),
                    width: round1(a.size.x), height: round1(a.size.y), sticksOut: round1(a.depthInFront),
                    hookColumns: a.hooks.count, hookSpacing: zip(a.hooks, a.hooks.dropFirst()).map { round1($1.x - $0.x) },
                    reachLeft: round1(-a.lower.x), reachRight: round1(a.upper.x), reachUp: round1(a.upper.y), reachDown: round1(-a.lower.y),
                    note: a.hooks.isEmpty ? "No SKÅDIS hooks found: it's placed by its back face, measured from its centre." : nil))
            }
        }
        printJSON(rows)

    case "pack":
        guard let name = o.board else { throw AppError(.badUsage, "pack needs --board <name> (see `skadis boards`)") }
        guard !o.positional.isEmpty else { throw AppError(.badUsage, "pack needs model files or folders") }
        try finish(try Planner.pack(board: try Planner.board(named: name), files: try modelFiles(o.positional)), o)

    case "arrange", "check":
        guard o.positional.count == 1 else { throw AppError(.badUsage, "\(command) needs one plan or layout file") }
        try finish(try load(o.positional[0]), o)

    case "render":
        guard o.positional.count == 1 else { throw AppError(.badUsage, "render needs one plan or layout file") }
        guard let png = o.out ?? o.render else { throw AppError(.badUsage, "render needs -o <picture.png>") }
        let r = try load(o.positional[0])
        try render(r, to: png, options: o)
        let report = Planner.report(r)
        print("Drew \(report.items.count) model\(report.items.count == 1 ? "" : "s") on \(report.board.name) to \(png). "
              + (report.fits ? "Everything fits." : "\(report.problemCount) problem\(report.problemCount == 1 ? "" : "s"): run `skadis check` for details."))

    default:
        throw AppError(.badUsage, "\"\(command)\"")
    }
} catch {
    fail(error)
}
