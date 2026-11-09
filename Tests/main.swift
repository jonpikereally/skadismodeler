import Foundation
import simd

// Offline checks of the model readers, the board's slot pattern, hook
// detection and overlap detection.
//   skadis-tests                 run the checks
//   skadis-tests --scan <folder> print what's detected in every STL and 3MF under a folder

var failures = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { print("ok   \(what)") } else { failures += 1; print("FAIL \(what)  (line \(line))") }
}

/// An axis-aligned box as 12 triangles, wound outward.
func box(_ a: V3, _ b: V3) -> [V3] {
    let p = [V3(a.x, a.y, a.z), V3(b.x, a.y, a.z), V3(b.x, b.y, a.z), V3(a.x, b.y, a.z),
             V3(a.x, a.y, b.z), V3(b.x, a.y, b.z), V3(b.x, b.y, b.z), V3(a.x, b.y, b.z)]
    let quads = [[0, 3, 2, 1], [4, 5, 6, 7], [0, 1, 5, 4], [2, 3, 7, 6], [1, 2, 6, 5], [0, 4, 7, 3]]
    return quads.flatMap { q in [p[q[0]], p[q[1]], p[q[2]], p[q[0]], p[q[2]], p[q[3]]] }
}

/// A holder the way the holder scripts export one (X out from the board, Y along it, Z up,
/// shifted so its lowest corner is at the origin): a back plate with a shelf, and a hook
/// column at each of `columns` (Y positions) with its upper slot `upperZ` above the bottom.
func holder(length: Float = 100, columns: [Float] = [30, 70], upperZ: Float = 75, shelf: Float = 40) -> Mesh {
    let back: Float = 11.5                     // the board's front face ends up this far from X = 0
    var t = box(V3(back, 0, 0), V3(back + 4, length, 85))
    t += box(V3(back + 4, 0, 0), V3(back + 4 + shelf, length, 3))
    for y in columns {
        let tb = upperZ - 6.2
        t += box(V3(0, y - 2.25, tb), V3(back, y + 2.25, tb + 5))                 // tongue through the board
        t += box(V3(0, y - 2.25, tb - 6), V3(6, y + 2.25, tb))                    // tab behind it
        t += box(V3(back - 4.5, y - 2.25, tb - 40), V3(back, y + 2.25, tb - 35))  // lower peg
    }
    return Mesh(tris: t)
}

func binarySTL(_ m: Mesh) -> Data {
    var d = Data(count: 80)
    var n = UInt32(m.triangleCount)
    withUnsafeBytes(of: &n) { d.append(contentsOf: $0) }
    for i in stride(from: 0, to: m.tris.count, by: 3) {
        var f: [Float] = [0, 0, 0]
        for k in 0..<3 { f += [m.tris[i + k].x, m.tris[i + k].y, m.tris[i + k].z] }
        f.withUnsafeBytes { d.append(contentsOf: $0) }
        d.append(contentsOf: [0, 0])
    }
    return d
}

func asciiSTL(_ m: Mesh) -> Data {
    var s = "solid test\n"
    for i in stride(from: 0, to: m.tris.count, by: 3) {
        s += " facet normal 0 0 0\n  outer loop\n"
        for k in 0..<3 { s += "   vertex \(m.tris[i + k].x) \(m.tris[i + k].y) \(m.tris[i + k].z)\n" }
        s += "  endloop\n endfacet\n"
    }
    return Data((s + "endsolid test\n").utf8)
}

func scan(_ folder: String) {
    let root = URL(fileURLWithPath: folder)
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
    var files: [URL] = []
    for case let url as URL in e {
        if url.lastPathComponent == "Earlier designs" || url.lastPathComponent == "parts" { e.skipDescendants(); continue }
        if ModelFile.isModel(url) { files.append(url) }
    }
    for url in files.sorted(by: { $0.path < $1.path }) {
        let rel = url.path.replacingOccurrences(of: root.path + "/", with: "")
        do {
            let start = Date()
            for part in try ModelFile.load(url) {
                let a = Analysis(mesh: part.mesh, orientation: .hanging)
                let hooks = a.hooks.map { String(format: "(%.1f, %.1f%@)", $0.x, $0.y, $0.hasLower ? "" : " no peg") }.joined(separator: " ")
                print(String(format: "%@ [%@]\n    %d tris, %.0f × %.0f mm, %.0f out, %.1f behind, hooks: %@  (%.2fs)",
                             rel, part.name, a.triangleCount, a.size.x, a.size.y, a.depthInFront, a.depthBehind,
                             hooks.isEmpty ? "none" : hooks, Date().timeIntervalSince(start)))
            }
        } catch {
            print("\(rel)\n    ERROR \(error.localizedDescription)")
        }
    }
}

if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--scan" {
    scan(CommandLine.arguments[2])
    exit(0)
}

// MARK: STL

let sample = holder()
do {
    let b = try STL.parse(binarySTL(sample), file: "b.stl")
    check(b.triangleCount == sample.triangleCount, "binary STL keeps every triangle")
    check(b.tris[7] == sample.tris[7], "binary STL keeps coordinates")
    let a = try STL.parse(asciiSTL(sample), file: "a.stl")
    check(a.triangleCount == sample.triangleCount, "text STL keeps every triangle")
    check(simd_distance(a.tris[20], sample.tris[20]) < 1e-4, "text STL keeps coordinates")
} catch { check(false, "STL parses: \(error)") }
do {
    _ = try STL.parse(Data("this is not a model".utf8), file: "x.stl")
    check(false, "junk STL is refused")
} catch let e as AppError { check(e.code == .badSTL, "junk STL is refused with SM-202") } catch { check(false, "junk STL error type") }

// MARK: 3MF

func threeMF(_ files: [String: String]) -> Data? {
    let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory()).appendingPathComponent("skadis-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    for (name, text) in files {
        let url = dir.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    p.currentDirectoryURL = dir
    p.arguments = ["-q", "-r", "out.3mf"] + files.keys.sorted()
    do { try p.run() } catch { print("zip: \(error)"); return nil }
    p.waitUntilExit()
    return try? Data(contentsOf: dir.appendingPathComponent("out.3mf"))
}

let cube = """
<mesh><vertices><vertex x="0" y="0" z="0"/><vertex x="10" y="0" z="0"/><vertex x="0" y="10" z="0"/><vertex x="0" y="0" z="10"/></vertices>
<triangles><triangle v1="0" v2="2" v3="1"/><triangle v1="0" v2="1" v3="3"/><triangle v1="0" v2="3" v3="2"/><triangle v1="1" v2="2" v3="3"/></triangles></mesh>
"""
let head = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<model unit=\"millimeter\" xmlns=\"http://schemas.microsoft.com/3dmanufacturing/core/2015/02\" xmlns:p=\"http://schemas.microsoft.com/3dmanufacturing/production/2015/06\">"
if let data = threeMF([
    "3D/3dmodel.model": head + "<resources><object id=\"1\" type=\"model\">\(cube)</object>"
        + "<object id=\"2\" type=\"model\"><components><component objectid=\"1\" transform=\"1 0 0 0 1 0 0 0 1 100 0 0\"/>"
        + "<component p:path=\"/3D/Objects/other.model\" objectid=\"7\"/></components></object>"
        + "<object id=\"3\" type=\"model\">\(cube)</object></resources>"
        + "<build><item objectid=\"2\" transform=\"0 1 0 -1 0 0 0 0 1 0 0 5\"/><item objectid=\"3\"/></build></model>",
    "3D/Objects/other.model": head + "<resources><object id=\"7\" type=\"model\">\(cube)</object></resources></model>",
    "Metadata/model_settings.config": "<config><object id=\"2\"><metadata key=\"name\" value=\"Left half\"/><part id=\"1\"><metadata key=\"name\" value=\"body\"/></part></object></config>",
]) {
    do {
        let parts = try ThreeMF.parse(data, file: "t.3mf", baseName: "t")
        check(parts.count == 2, "3MF gives one mesh per build item")
        check(parts[0].mesh.triangleCount == 8, "3MF follows components, including ones in other model files")
        check(parts[0].name == "Left half (t)", "3MF takes object names from the slicer's settings")
        // (10,0,0) moved +100 in x by the component, then turned x→y by the item and lifted 5.
        check(parts[0].mesh.tris.contains { simd_distance($0, V3(0, 110, 5)) < 1e-3 }, "3MF applies component then item transforms")
        check(parts[1].mesh.triangleCount == 4, "3MF second item is on its own")
    } catch { check(false, "3MF parses: \(error)") }
    do {
        _ = try ThreeMF.parse(Data(data.prefix(200)), file: "cut.3mf", baseName: "cut")
        check(false, "cut-off 3MF is refused")
    } catch let e as AppError { check(e.code == .bad3MF, "cut-off 3MF is refused with SM-203") } catch { check(false, "3MF error type") }
} else { check(false, "couldn't build a test 3MF with /usr/bin/zip") }

// MARK: Board

let ikea = Board.centred("ikea56x56", width: 560, height: 560)
check(ikea.columns == 27 && abs(ikea.firstColumn - 20) < 1e-4, "56 cm board: 27 columns, first one 20 mm in")
check(ikea.hasSlot(0, ikea.levels - 1) && !ikea.hasSlot(1, ikea.levels - 1) && ikea.hasSlot(1, ikea.levels - 2),
      "neighbouring columns are staggered by 20 mm")
check(ikea.hasSlot(2, ikea.levels - 1) && ikea.hasSlot(0, ikea.levels - 3), "slots repeat 40 mm across and 40 mm down")
let gap = ikea.hasSlot(4, 7) ? (4, 8) : (4, 7)
let near = ikea.nearestSlot(to: ikea.slotCentre(gap.0, gap.1) + V2(3, 2))
check(!ikea.hasSlot(gap.0, gap.1) && ikea.hasSlot(near.0, near.1) && near.0 == 5, "nearestSlot only returns real slots")
let tile = Board.tiles(2, 1)
check(tile.slotCentre(0, 0) == V2(10, 20) && tile.hasSlot(0, 0) && tile.hasSlot(1, 1), "printed tile pattern matches the tile script")
check(tile.levels == 11 && tile.columns == 24, "printed tile: slots cut by the top edge aren't counted")

// MARK: Hooks

let a = Analysis(mesh: sample, orientation: .hanging)
if CommandLine.arguments.contains("--debug") { print(a.hooks, a.lower, a.upper) }
check(a.hooks.count == 2, "finds both hook columns")
if a.hooks.count == 2 {
    check(abs(a.hooks[1].x - 40) < 0.05 && abs(a.hooks[1].y) < 0.05, "hook columns are 40 mm apart at the same height")
    check(a.hooks.allSatisfy(\.hasLower), "finds the lower pegs")
}
check(abs(a.lower.z + 11.5) < 0.05 && abs(a.upper.z - 44) < 0.05, "board face sits on the back plate (11.5 behind, 44 out)")
check(abs(a.lower.y + 75) < 0.05, "upper slot is 75 mm above the holder's bottom")
check(abs(a.lower.x + 30) < 0.05, "anchor is the left hook column")
let plain = Analysis(mesh: Mesh(tris: box(V3(0, 0, 0), V3(30, 50, 20))), orientation: .hanging)
check(plain.hooks.isEmpty && abs(plain.lower.z) < 1e-4, "a plain block has no hooks and sits on the board's face")
let turned = Analysis(mesh: sample, orientation: Orientation.hanging.turned(about: 2))
check(turned.hooks.isEmpty || turned.hooks != a.hooks, "turning the model changes what's found")
var o = Orientation.hanging
for _ in 0..<4 { o = o.turned(about: 1) }
check(o == .hanging && Orientation.hanging.turned(about: 0).isValid, "four quarter turns come back round")

// MARK: Overlap

let w = Footprint.overlap(a.foot, at: V3(100, 300, 0), a.foot, at: V3(100, 300, 0))
check(w > 3000, "a holder overlaps a copy of itself")
check(Footprint.overlap(a.foot, at: V3(100, 300, 0), a.foot, at: V3(200, 300, 0)) < 12, "holders side by side, just touching, don't overlap")
check(Footprint.overlap(a.foot, at: V3(100, 300, 0), a.foot, at: V3(180, 300, 0)) > 100, "holders 20 mm into each other overlap")
check(Footprint.overlap(a.foot, at: V3(100, 300, 0), a.foot, at: V3(100, 420, 0)) == 0, "holders one above the other don't overlap")
// A block above the shelf, in front of the back plate, is clear; lowered onto the shelf it isn't.
check(Footprint.overlap(plain.foot, at: V3(150, 300, 60), a.foot, at: V3(100, 300, 0)) == 0, "a part in front of another's back plate is clear")

// MARK: Layout checks

let model = LayoutChecker(board: ikea)
let slot = ikea.nearestSlot(to: V2(200, 400))
var item = PlacedItem(path: "/x.stl", part: 0, name: "x", column: slot.0, level: slot.1)
check(model.issues(for: item, analysis: a, others: []).filter(\.isProblem).isEmpty, "a holder on real slots has no problems")
item.dx = 4
check(model.issues(for: item, analysis: a, others: []).contains { $0.isProblem && $0.text.contains("4.0 mm") }, "nudged 4 mm sideways, its hooks miss the slots")
item.dx = 0
item.column = 0; item.level = ikea.hasSlot(0, 1) ? 1 : 0
check(model.issues(for: item, analysis: a, others: []).contains { $0.isProblem }, "at the bottom-left corner it doesn't fit")
let odd = Analysis(mesh: holder(columns: [30, 60]), orientation: .hanging)
item.column = slot.0; item.level = slot.1
check(model.issues(for: item, analysis: odd, others: []).contains { $0.isProblem }, "hook columns 30 mm apart can't both find a slot")
let other = PlacedItem(path: "/y.stl", part: 0, name: "y", column: slot.0 + 2, level: slot.1)
check(model.issues(for: item, analysis: a, others: [(other, a)]).contains { $0.text.contains("Overlaps y") }, "overlapping neighbours are named")

// MARK: Plans (what the skadis command reads)

let tmp = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
    .appendingPathComponent("skadis-plan-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("sub"), withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }
try? binarySTL(sample).write(to: tmp.appendingPathComponent("sub/wide_holder.stl"))
try? binarySTL(holder(length: 60, columns: [30])).write(to: tmp.appendingPathComponent("small.stl"))
func plan(_ json: String) throws -> Resolved { try Planner.resolve(Data(json.utf8), relativeTo: tmp) }
do {
    let r = try plan(##"{"board": "ikea56x56", "items": [{"file": "sub/wide_holder.stl", "left": 200, "top": 100}, {"file": "small.stl"}, {"file": "small.stl", "column": 4, "level": 8, "name": "Second", "color": "#ff0000"}]}"##)
    let rep = Planner.report(r)
    check(rep.items.count == 3 && rep.board.columns == 27, "a plan loads its models, relative to its own folder")
    check(abs(rep.items[0].left - 200) <= 10 && abs(rep.items[0].top - 100) <= 20 && rep.items[0].fits, "left / top lands on the nearest slot")
    check(rep.items[0].name == "wide holder" && rep.items[0].hookColumns == 2, "names come from the file, hooks are found")
    check(rep.items[1].fits && !rep.fits && rep.problemCount >= 1, "an item with no position is fitted into free space")
    check(r.layout.items[2].column == 4 && r.layout.items[2].name == "Second" && r.layout.items[2].color == RGB(r: 1, g: 0, b: 0), "column / level, name and #rrggbb are taken as given")
    check(!ikea.hasSlot(4, 8) && !rep.items[2].fits && rep.items[2].problems.contains { $0.contains("between slots") }, "a slot that isn't real is reported, not moved")
    // A saved layout reads back as a plan and comes out the same.
    let saved = try JSONEncoder().encode(r.layout)
    let again = try Planner.resolve(saved, relativeTo: URL(fileURLWithPath: "/"))
    check(again.layout.items == r.layout.items && again.layout.board == r.layout.board, "a saved .skadis layout reads back unchanged")
    let two = try plan(#"{"board": "400x300", "items": [{"file": "small.stl", "column": 4, "level": 8}, {"file": "small.stl", "column": 4, "level": 8}]}"#)
    check(Planner.report(two).problemCount >= 2 && Planner.report(two).board.width == 400, "two models on the same slot are both flagged, on a custom board")
    let packed = try Planner.pack(board: ikea, files: [tmp.appendingPathComponent("sub/wide_holder.stl"), tmp.appendingPathComponent("small.stl"), tmp.appendingPathComponent("small.stl")])
    check(Planner.report(packed).fits && packed.layout.items.count == 3, "pack fits everything with no overlaps")
} catch { check(false, "plans resolve: \(error)") }
func refused(_ json: String, _ code: ErrorCode, _ what: String) {
    do { _ = try plan(json); check(false, what) } catch let e as AppError { check(e.code == code, what) } catch { check(false, what) }
}
refused(#"{"board": "ikea56x56", "items": [{"left": 3, "top": 4}]}"#, .planMalformed, "an item with no file is refused with SM-401")
refused(#"{"board": "ikea56x56", "items": [{"file": "small.stl", "left": 3}]}"#, .planMalformed, "left without top is refused with SM-401")
refused(#"{"board": "billy", "items": []}"#, .unknownBoard, "an unknown board is refused with SM-402")
refused(#"{"board": "ikea56x56", "items": [{"file": "gone.stl"}]}"#, .modelMissing, "a missing model is refused with SM-206")
refused(#"{"board": "ikea56x56", "items": [{"file": "small.stl", "part": 3}]}"#, .planMalformed, "a part that isn't there is refused with SM-401")

print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) FAILED.")
exit(failures == 0 ? 0 : 1)
