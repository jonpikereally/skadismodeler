import Foundation
import simd

/// A SKÅDIS-pattern board. Origin is its bottom-left corner as you face it,
/// x to the right, y up, front face at z = 0.
///
/// Slots are 5 × 15 mm, upright. Columns are 20 mm apart, slots 40 mm apart in
/// a column, and every other column is shifted 20 mm. So slot centres sit on a
/// 20 mm lattice of (column, level) where column + level has a fixed parity.
struct Board: Codable, Equatable {
    enum Finish: String, Codable, CaseIterable, Identifiable {
        case white, black, wood, grey
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    static let thickness: Float = 5
    static let slotWidth: Float = 5
    static let slotLength: Float = 15
    static let pitch: Float = 20

    var preset: String
    var width: Float
    var height: Float
    /// x of the first column's centre, and y of the lowest slot level.
    var firstColumn: Float
    var firstLevel: Float
    var columns: Int
    var levels: Int
    /// A slot exists where (column + level) % 2 == parity.
    var parity: Int
    var finish: Finish = .white

    struct Preset: Identifiable {
        let id: String
        let label: String
        let make: () -> Board
    }

    static let presets: [Preset] = [
        Preset(id: "ikea36x56", label: "IKEA SKÅDIS 36 × 56 cm") { .centred("ikea36x56", width: 360, height: 560) },
        Preset(id: "ikea56x56", label: "IKEA SKÅDIS 56 × 56 cm") { .centred("ikea56x56", width: 560, height: 560) },
        Preset(id: "ikea76x56", label: "IKEA SKÅDIS 76 × 56 cm") { .centred("ikea76x56", width: 760, height: 560) },
        Preset(id: "ikea76x100", label: "IKEA SKÅDIS 76 × 100 cm") { .centred("ikea76x100", width: 760, height: 1000) },
        Preset(id: "tiles1x1", label: "Printed tiles 1 × 1 (24 × 24 cm)") { .tiles(1, 1) },
        Preset(id: "tiles2x1", label: "Printed tiles 2 × 1 (48 × 24 cm)") { .tiles(2, 1) },
        Preset(id: "tiles2x2", label: "Printed tiles 2 × 2 (48 × 48 cm)") { .tiles(2, 2) },
        Preset(id: "tiles3x2", label: "Printed tiles 3 × 2 (72 × 48 cm)") { .tiles(3, 2) },
    ]

    static let standard = Board.centred("ikea56x56", width: 560, height: 560)

    /// A board with the slot pattern centred on it: at least 20 mm from the side
    /// edges to the first column's centre and 25 mm from the top and bottom
    /// edges to the nearest slot centre.
    static func centred(_ preset: String, width: Float, height: Float) -> Board {
        let w = max(60, min(width, 3000)), h = max(80, min(height, 3000))
        let columns = max(1, Int(((w - 40) / pitch).rounded(.down)) + 1)
        let levels = max(1, Int(((h - 50) / pitch).rounded(.down)) + 1)
        return Board(preset: preset, width: w, height: h,
                     firstColumn: (w - Float(columns - 1) * pitch) / 2,
                     firstLevel: (h - Float(levels - 1) * pitch) / 2,
                     columns: columns, levels: levels,
                     parity: (levels - 1) % 2)            // top-left corner has a slot
    }

    /// 240 mm printed tiles: columns start 10 mm in, slots at 20, 60, … in even
    /// columns and 40, 80, … in odd ones. Slots cut in half by the outer edge aren't counted.
    static func tiles(_ across: Int, _ up: Int) -> Board {
        Board(preset: "tiles\(across)x\(up)", width: Float(across) * 240, height: Float(up) * 240,
              firstColumn: 10, firstLevel: 20, columns: across * 12, levels: up * 12 - 1, parity: 0)
    }

    var label: String {
        Board.presets.first { $0.id == preset }?.label
            ?? "Custom \(Int(width.rounded())) × \(Int(height.rounded())) mm"
    }

    var slotCount: Int {
        (0..<columns).reduce(0) { n, c in n + (0..<levels).filter { hasSlot(c, $0) }.count }
    }

    func hasSlot(_ c: Int, _ l: Int) -> Bool {
        c >= 0 && c < columns && l >= 0 && l < levels && (c + l) % 2 == parity
    }

    func slotCentre(_ c: Int, _ l: Int) -> V2 {
        V2(firstColumn + Float(c) * Board.pitch, firstLevel + Float(l) * Board.pitch)
    }

    /// The real slot nearest to a point on the board.
    func nearestSlot(to p: V2) -> (Int, Int) {
        let fc = (p.x - firstColumn) / Board.pitch, fl = (p.y - firstLevel) / Board.pitch
        let c0 = min(max(Int(fc.rounded()), 0), columns - 1)
        let l0 = min(max(Int(fl.rounded()), 0), levels - 1)
        var best = (c0, l0)
        var bestD = Float.infinity
        for c in (c0 - 1)...(c0 + 1) {
            for l in (l0 - 1)...(l0 + 1) where hasSlot(c, l) {
                let d = simd_distance_squared(slotCentre(c, l), p)
                if d < bestD { bestD = d; best = (c, l) }
            }
        }
        return best
    }
}
