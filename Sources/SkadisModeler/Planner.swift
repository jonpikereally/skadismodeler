import Foundation
import simd

/// A layout the way a person or an LLM would write it. Everything but each
/// item's file is optional, and a saved .skadis layout reads as a plan too.
///
///     {"board": "ikea76x56",
///      "items": [{"file": "Drill/drill_holder.3mf", "left": 40, "top": 300},
///                {"file": "hex_key_holder.3mf", "column": 20, "level": 25},
///                {"file": "pliers_holder.stl"}]}
///
/// An item goes where `column` and `level` say (the slot its left hook column
/// hangs from), or as near as the slots allow to `left` and `top` (millimetres
/// from the board's left and top edges to the model's own left and top edges).
/// Items with neither are fitted into the first free space afterwards, in order.
struct Plan: Decodable {
    enum BoardSpec: Decodable {
        case named(String)
        case full(Board)

        init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) { self = .named(s); return }
            if let b = try? Board(from: decoder) { self = .full(b); return }
            struct Size: Decodable { let width: Float; let height: Float; let finish: Board.Finish? }
            let size = try Size(from: decoder)
            var b = Board.centred("custom", width: size.width, height: size.height)
            if let f = size.finish { b.finish = f }
            self = .full(b)
        }
    }

    /// {"r":…, "g":…, "b":…} with 0–1 values, or "#rrggbb".
    struct Tint: Decodable {
        let rgb: RGB

        init(from decoder: Decoder) throws {
            if let c = try? RGB(from: decoder) { rgb = c; return }
            let s = try decoder.singleValueContainer().decode(String.self)
            let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
            guard hex.count == 6, let v = Int(hex, radix: 16) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "colour \"\(s)\" isn't #rrggbb"))
            }
            rgb = RGB(r: Double(v >> 16 & 255) / 255, g: Double(v >> 8 & 255) / 255, b: Double(v & 255) / 255)
        }
    }

    struct Item: Decodable {
        var id: UUID?
        var file: String?
        var path: String?
        var part: Int?
        var name: String?
        var orientation: Orientation?
        var column: Int?
        var level: Int?
        var left: Float?
        var top: Float?
        var dx: Float?
        var dy: Float?
        var dz: Float?
        var color: Tint?
    }

    var board: BoardSpec
    var items: [Item]
}

/// A layout with every model loaded and measured.
struct Resolved {
    var layout: Layout
    var analyses: [UUID: Analysis]

    var placed: [(PlacedItem, Analysis)] { layout.items.compactMap { i in analyses[i.id].map { (i, $0) } } }
}

/// What `skadis check` prints: where everything ended up and whether it fits.
struct Report: Encodable {
    struct BoardInfo: Encodable {
        let name: String
        let width: Float
        let height: Float
        let columns: Int
        let levels: Int
    }

    struct Item: Encodable {
        let name: String
        let file: String
        let part: Int
        let column: Int
        let level: Int
        /// Millimetres from the board's left and top edges to the model's left and top edges.
        let left: Float
        let top: Float
        let width: Float
        let height: Float
        let sticksOut: Float
        let hookColumns: Int
        let fits: Bool
        let problems: [String]
        let notes: [String]
    }

    let board: BoardInfo
    let fits: Bool
    let problemCount: Int
    let items: [Item]
}

enum Planner {
    private static func tenth(_ v: Float) -> Float { (v * 10).rounded() / 10 }

    /// A board from a preset id ("ikea56x56") or a size in millimetres ("760x560").
    static func board(named s: String) throws -> Board {
        if let p = Board.presets.first(where: { $0.id == s.lowercased() }) { return p.make() }
        let parts = s.lowercased().split(separator: "x").compactMap { Float($0) }
        if parts.count == 2, parts[0] >= 60, parts[1] >= 80 { return .centred("custom", width: parts[0], height: parts[1]) }
        throw AppError(.unknownBoard, "\"\(s)\". Known boards: \(Board.presets.map(\.id).joined(separator: ", ")), or a size in mm like 760x560")
    }

    private final class Loader {
        var meshes: [String: [NamedMesh]] = [:]

        func parts(_ path: String) throws -> [NamedMesh] {
            if let m = meshes[path] { return m }
            guard FileManager.default.fileExists(atPath: path) else { throw AppError(.modelMissing, path) }
            let m = try ModelFile.load(URL(fileURLWithPath: path))
            meshes[path] = m
            return m
        }
    }

    private static func prettyName(_ s: String) -> String { s.replacingOccurrences(of: "_", with: " ") }

    static func resolve(_ data: Data, relativeTo base: URL) throws -> Resolved {
        let plan: Plan
        do { plan = try JSONDecoder().decode(Plan.self, from: data) } catch {
            throw AppError(.planMalformed, "\(error)")
        }
        let board: Board
        switch plan.board {
        case .named(let s): board = try Planner.board(named: s)
        case .full(let b): board = b
        }
        let checker = LayoutChecker(board: board)
        let loader = Loader()
        var out = Resolved(layout: Layout(board: board, items: []), analyses: [:])
        var floating: [Int] = []

        for (n, p) in plan.items.enumerated() {
            guard let given = p.file ?? p.path, !given.isEmpty else {
                throw AppError(.planMalformed, "item \(n + 1) has no \"file\"")
            }
            let expanded = (given as NSString).expandingTildeInPath
            let path = expanded.hasPrefix("/") ? expanded : base.appendingPathComponent(expanded).standardizedFileURL.path
            let parts = try loader.parts(path)
            let part = p.part ?? 0
            guard let mesh = parts[safe: part] else {
                throw AppError(.planMalformed, "item \(n + 1): \((path as NSString).lastPathComponent) has \(parts.count) object\(parts.count == 1 ? "" : "s"), so \"part\": \(part) doesn't exist (parts count from 0)")
            }
            if let o = p.orientation, !o.isValid { throw AppError(.planMalformed, "item \(n + 1) has an orientation that isn't a right-angle turn") }
            let o = p.orientation ?? Analysis.bestOrientation(for: mesh.mesh)
            let a = Analysis(mesh: mesh.mesh, orientation: o)
            var item = PlacedItem(path: path, part: part, name: p.name ?? prettyName(mesh.name), orientation: o, column: 0, level: 0,
                                  color: p.color?.rgb ?? RGB.palette[n % RGB.palette.count])
            if let id = p.id { item.id = id }
            item.dx = p.dx ?? 0; item.dy = p.dy ?? 0; item.dz = p.dz ?? 0
            if let c = p.column, let l = p.level {
                item.column = c
                item.level = l
            } else if p.left != nil || p.top != nil {
                guard let left = p.left, let top = p.top else {
                    throw AppError(.planMalformed, "item \(n + 1) needs both \"left\" and \"top\" (or both \"column\" and \"level\")")
                }
                let s = board.nearestSlot(to: V2(left - a.lower.x, board.height - top - a.upper.y))
                (item.column, item.level) = s
            } else if p.column != nil || p.level != nil {
                throw AppError(.planMalformed, "item \(n + 1) needs both \"column\" and \"level\"")
            } else {
                floating.append(out.layout.items.count)
            }
            out.layout.items.append(item)
            out.analyses[item.id] = a
        }
        // Fit the unpositioned ones round everything that was given a place.
        var settled: [(PlacedItem, Analysis)] = out.layout.items.enumerated()
            .filter { !floating.contains($0.offset) }.map { ($0.element, out.analyses[$0.element.id]!) }
        for i in floating {
            let a = out.analyses[out.layout.items[i].id]!
            let s = checker.freeSlot(for: a, among: settled)
            (out.layout.items[i].column, out.layout.items[i].level) = s
            settled.append((out.layout.items[i], a))
        }
        return out
    }

    /// Every object of every file, fitted in order from the top-left.
    static func pack(board: Board, files: [URL]) throws -> Resolved {
        let loader = Loader()
        let checker = LayoutChecker(board: board)
        var out = Resolved(layout: Layout(board: board, items: []), analyses: [:])
        for url in files {
            for (n, part) in try loader.parts(url.path).enumerated() {
                let o = Analysis.bestOrientation(for: part.mesh)
                let a = Analysis(mesh: part.mesh, orientation: o)
                let s = checker.freeSlot(for: a, among: out.placed)
                let item = PlacedItem(path: url.path, part: n, name: prettyName(part.name), orientation: o, column: s.0, level: s.1,
                                      color: RGB.palette[out.layout.items.count % RGB.palette.count])
                out.layout.items.append(item)
                out.analyses[item.id] = a
            }
        }
        return out
    }

    static func report(_ r: Resolved) -> Report {
        let b = r.layout.board
        let checker = LayoutChecker(board: b)
        let placed = r.placed
        let items = placed.map { item, a -> Report.Item in
            let found = checker.issues(for: item, analysis: a, others: placed)
            let pos = checker.position(item)
            return Report.Item(name: item.name, file: item.path, part: item.part, column: item.column, level: item.level,
                               left: tenth(pos.x + a.lower.x), top: tenth(b.height - pos.y - a.upper.y),
                               width: tenth(a.size.x), height: tenth(a.size.y), sticksOut: tenth(a.depthInFront),
                               hookColumns: a.hooks.count, fits: !found.contains(where: \.isProblem),
                               problems: found.filter(\.isProblem).map(\.text), notes: found.filter { !$0.isProblem }.map(\.text))
        }
        let count = items.reduce(0) { $0 + $1.problems.count }
        return Report(board: Report.BoardInfo(name: b.label, width: b.width, height: b.height, columns: b.columns, levels: b.levels),
                      fits: count == 0, problemCount: count, items: items)
    }
}
