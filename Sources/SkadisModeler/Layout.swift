import Foundation
import simd

struct RGB: Codable, Equatable, Hashable {
    var r: Double, g: Double, b: Double

    static let palette: [RGB] = [
        RGB(r: 0.20, g: 0.47, b: 0.85), RGB(r: 0.93, g: 0.49, b: 0.13), RGB(r: 0.25, g: 0.66, b: 0.38),
        RGB(r: 0.80, g: 0.27, b: 0.27), RGB(r: 0.55, g: 0.38, b: 0.78), RGB(r: 0.16, g: 0.65, b: 0.68),
        RGB(r: 0.86, g: 0.70, b: 0.16), RGB(r: 0.45, g: 0.47, b: 0.52),
    ]
}

/// One model hung on the board. Its anchor (the upper slot of its leftmost
/// hook column) sits on slot (column, level), plus a fine offset in millimetres.
struct PlacedItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    /// Which object inside the file (a 3MF can hold several).
    var part: Int
    var name: String
    var orientation: Orientation = .hanging
    var column: Int
    var level: Int
    var dx: Float = 0
    var dy: Float = 0
    /// Lifted off the board's front face.
    var dz: Float = 0
    var color: RGB = RGB.palette[0]
}

struct Layout: Codable {
    static let currentVersion = 1
    var version = Layout.currentVersion
    var board: Board
    var items: [PlacedItem]
}

struct Issue: Equatable, Identifiable {
    var isProblem: Bool
    var text: String
    var id: String { text }
}

/// Works out whether placed models really fit: hooks in slots, nothing
/// overlapping, and what hangs past the board's edges.
struct LayoutChecker {
    let board: Board

    /// Board position of an item's anchor.
    func position(_ item: PlacedItem) -> V3 {
        let s = board.slotCentre(item.column, item.level)
        return V3(s.x + item.dx, s.y + item.dy, item.dz)
    }

    /// The lattice point a hook lands nearest to, and how far off it is.
    private func landing(_ p: V2) -> (c: Int, l: Int, off: V2) {
        let c = Int(((p.x - board.firstColumn) / Board.pitch).rounded())
        let l = Int(((p.y - board.firstLevel) / Board.pitch).rounded())
        return (c, l, p - board.slotCentre(c, l))
    }

    func issues(for item: PlacedItem, analysis a: Analysis, others: [(PlacedItem, Analysis)]) -> [Issue] {
        var out: [Issue] = []
        let pos = position(item)
        let many = a.hooks.count > 1
        func label(_ k: Int) -> String { many ? "Hook column \(k + 1)" : "The hook" }

        if a.hooks.isEmpty {
            out.append(Issue(isProblem: false, text: "No SKÅDIS hooks found on this model, so it's placed by its back face. Turn it if it's facing the wrong way."))
        }
        if item.dz > 0.05 {
            out.append(Issue(isProblem: !a.hooks.isEmpty, text: String(format: "Lifted %.1f mm off the board.", item.dz)))
        }
        for (k, h) in a.hooks.enumerated() {
            let p = V2(pos.x + h.x, pos.y + h.y)
            let (c, l, off) = landing(p)
            if c < 0 || c >= board.columns || l < 0 || l >= board.levels {
                let side = c < 0 ? "left" : c >= board.columns ? "right" : l < 0 ? "bottom" : "top"
                out.append(Issue(isProblem: true, text: "\(label(k)) is past the \(side) edge of the slots."))
                continue
            }
            if !board.hasSlot(c, l) {
                let s = board.nearestSlot(to: p)
                let d = simd_distance(board.slotCentre(s.0, s.1), p)
                out.append(Issue(isProblem: true, text: String(format: "\(label(k)) lands between slots, %.1f mm from the nearest one.", d)))
                continue
            }
            if abs(off.x) > 0.6 {
                out.append(Issue(isProblem: true, text: String(format: "\(label(k)) misses its slot by %.1f mm sideways.", abs(off.x))))
                continue
            }
            if abs(off.y) > 1.0 {
                out.append(Issue(isProblem: true, text: String(format: "\(label(k)) sits %.1f mm too %@ for its slot.", abs(off.y), off.y > 0 ? "high" : "low")))
                continue
            }
            if h.hasLower && !board.hasSlot(c, l - 2) {
                out.append(Issue(isProblem: true, text: "\(label(k))'s lower peg has no slot: it's below the bottom row."))
            }
        }

        let lo = pos + a.lower, hi = pos + a.upper
        for (amount, side) in [(-lo.x, "left"), (hi.x - board.width, "right"), (-lo.y, "bottom"), (hi.y - board.height, "top")]
        where amount > 0.5 {
            out.append(Issue(isProblem: false, text: String(format: "Hangs %.0f mm past the board's \(side) edge.", amount)))
        }

        for (other, oa) in others where other.id != item.id {
            let area = Footprint.overlap(a.foot, at: pos, oa.foot, at: position(other))
            if area >= 12 {
                out.append(Issue(isProblem: true, text: String(format: "Overlaps \(other.name) (about %.0f cm² as seen from the front).", max(1, area / 100))))
            }
        }
        return out
    }

    /// The first slot, scanning from the top-left, where the model fits with no problems
    /// and stays on the board. Falls back to the middle of the board.
    func freeSlot(for a: Analysis, among others: [(PlacedItem, Analysis)]) -> (Int, Int) {
        var probe = PlacedItem(path: "", part: 0, name: "", column: 0, level: 0)
        var fallback: (Int, Int)?
        for l in stride(from: board.levels - 1, through: 0, by: -1) {
            for c in 0..<board.columns where board.hasSlot(c, l) {
                probe.column = c
                probe.level = l
                let pos = position(probe)
                let lo = pos + a.lower, hi = pos + a.upper
                let onBoard = lo.x >= 0 && lo.y >= 0 && hi.x <= board.width && hi.y <= board.height
                let found = issues(for: probe, analysis: a, others: others)
                if !found.contains(where: \.isProblem) {
                    if onBoard { return (c, l) }
                    if fallback == nil && !found.contains(where: { $0.text.hasPrefix("Hangs") }) { fallback = (c, l) }
                }
            }
        }
        return fallback ?? board.nearestSlot(to: V2(board.width / 2, board.height / 2))
    }
}
