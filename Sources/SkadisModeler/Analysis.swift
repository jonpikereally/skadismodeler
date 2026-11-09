import Foundation
import simd

/// One hook column found on a model: where its upper slot's centre is,
/// relative to the model's anchor, and whether a lower peg sits 40 mm below.
struct Hook: Equatable {
    var x: Float
    var y: Float
    var hasLower: Bool
}

/// What the model covers in front of the board, on a 2 mm grid anchored at the
/// model's anchor: for each cell, how far out from the board the model starts
/// and ends. Hollow shapes count as filled between their walls, which is what
/// you want for a cup that will hold something.
struct Footprint {
    static let cell: Float = 2
    var x0 = 0, y0 = 0, w = 0, h = 0
    var lo: [Float] = []
    var hi: [Float] = []

    /// Area in mm² where two footprints occupy the same space, a at pa and b at pb
    /// (board positions of their anchors; z is how far each is lifted off the board).
    static func overlap(_ a: Footprint, at pa: V3, _ b: Footprint, at pb: V3) -> Float {
        guard a.w > 0, b.w > 0 else { return 0 }
        let sx = Int(((pa.x - pb.x) / cell).rounded()), sy = Int(((pa.y - pb.y) / cell).rounded())
        let dz = pa.z - pb.z
        // a's cell (i, j) lines up with b's cell (i + a.x0 + sx - b.x0, j + a.y0 + sy - b.y0)
        let ox = a.x0 + sx - b.x0, oy = a.y0 + sy - b.y0
        let i0 = max(0, -ox), i1 = min(a.w, b.w - ox)
        let j0 = max(0, -oy), j1 = min(a.h, b.h - oy)
        guard i0 < i1, j0 < j1 else { return 0 }
        var cells = 0
        for j in j0..<j1 {
            let ra = j * a.w, rb = (j + oy) * b.w + ox
            for i in i0..<i1 {
                let alo = a.lo[ra + i]
                if alo == .infinity { continue }
                let blo = b.lo[rb + i]
                if blo == .infinity { continue }
                if min(a.hi[ra + i] + dz, b.hi[rb + i]) - max(alo + dz, blo) > 0.5 { cells += 1 }
            }
        }
        return Float(cells) * cell * cell
    }
}

/// A model turned to sit on the board and measured: its triangles relative to
/// an anchor (the upper slot of its leftmost hook column, on the board's front
/// face), its hooks, and its footprint.
final class Analysis {
    // SKÅDIS hook geometry, matching the holder scripts.
    static let slotSeat: Float = 6.2        // tongue bottom sits this far below the slot's centre
    static let tongueHeight: Float = 5.0
    static let slotPitch: Float = 40

    /// x right, y up, z out from the board's front face, all relative to the anchor.
    let tris: [V3]
    let lower: V3
    let upper: V3
    let hooks: [Hook]
    let foot: Footprint

    var size: V3 { upper - lower }
    var triangleCount: Int { tris.count / 3 }
    /// How far it sticks out in front of the board, and reaches behind its front face.
    var depthInFront: Float { max(0, upper.z) }
    var depthBehind: Float { max(0, -lower.z) }

    /// The SceneKit geometry drawn for this analysis, made on first use.
    var renderCache: AnyObject?

    /// All 24 right-angle orientations, the holder scripts' own first.
    static let orientations: [Orientation] = {
        var seen: [Orientation] = [.hanging]
        var i = 0
        while i < seen.count {
            for axis in 0..<3 {
                let o = seen[i].turned(about: axis)
                if !seen.contains(o) { seen.append(o) }
            }
            i += 1
        }
        return seen
    }()

    /// How a model should sit when first added: the way the holder scripts export it if that
    /// shows hooks, otherwise whichever right-angle turn shows the most hooks that could
    /// all sit in slots at once. Falls back to the scripts' orientation.
    static func bestOrientation(for mesh: Mesh) -> Orientation {
        var best = Orientation.hanging
        var bestScore = 0
        for o in orientations {
            let a = Analysis(mesh: mesh, orientation: o, measureFootprint: false)
            let onGrid = a.hooks.allSatisfy { h in
                let cx = h.x / Board.pitch, cy = h.y / Board.pitch
                return abs(cx - cx.rounded()) < 0.05 && abs(cy - cy.rounded()) < 0.08
                    && (Int(cx.rounded()) + Int(cy.rounded())) % 2 == 0
            }
            guard onGrid, !a.hooks.isEmpty else { continue }
            if o == .hanging { return o }
            let score = a.hooks.count + a.hooks.filter(\.hasLower).count
            if score > bestScore { bestScore = score; best = o }
        }
        return best
    }

    init(mesh: Mesh, orientation: Orientation, measureFootprint: Bool = true) {
        var t = mesh.tris.map(orientation.apply)
        var lo = V3(repeating: .infinity), hi = V3(repeating: -.infinity)
        for v in t { lo = simd_min(lo, v); hi = simd_max(hi, v) }

        // The board's front face touches the model's biggest flat rear-facing
        // surface that has something (hooks) poking out behind it.
        var area: [Int: Float] = [:]
        for i in stride(from: 0, to: t.count, by: 3) {
            let n = simd_cross(t[i + 1] - t[i], t[i + 2] - t[i])
            let len = simd_length(n)
            guard len > 1e-9, n.z / len < -0.98 else { continue }
            let z = (t[i].z + t[i + 1].z + t[i + 2].z) / 3
            if z > lo.z + 2 && z < lo.z + 25 { area[Int((z * 20).rounded()), default: 0] += len / 2 }
        }
        var plane = lo.z
        var found: [Hook] = []
        if let best = area.max(by: { $0.value < $1.value }), best.value >= 150 {
            let zp = Float(best.key) / 20
            var behind = t.filter { $0.z < zp - 0.2 }
            behind.sort { $0.x < $1.x }
            var clusters: [[V3]] = []
            for p in behind {
                // A hook is under 8 mm wide and columns are 20 mm apart.
                if let last = clusters.last?.last, p.x - last.x <= 8 { clusters[clusters.count - 1].append(p) }
                else { clusters.append([p]) }
            }
            for c in clusters {
                let x0 = c.first!.x, x1 = c.last!.x
                guard x1 - x0 >= 1.5, x1 - x0 <= 15 else { continue }
                // The tongue goes right through the 5 mm board; its top is 5 mm above its bottom,
                // and its bottom rests 6.2 mm below the slot's centre.
                let through = c.filter { $0.z < zp - Board.thickness - 0.2 }
                guard let top = through.map(\.y).max() else { continue }
                let slotY = top - Analysis.tongueHeight + Analysis.slotSeat
                found.append(Hook(x: (x0 + x1) / 2, y: slotY, hasLower: c.contains { $0.y < slotY - 30 }))
            }
            if !found.isEmpty { plane = zp }
        }

        let anchor: V3
        if let first = found.first {
            anchor = V3(first.x, first.y, plane)
            found = found.map { Hook(x: $0.x - first.x, y: $0.y - first.y, hasLower: $0.hasLower) }
        } else {
            anchor = V3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, plane)
        }
        for i in t.indices { t[i] -= anchor }
        tris = t
        lower = lo - anchor
        upper = hi - anchor
        hooks = found
        foot = measureFootprint ? Analysis.footprint(t, lower: lo - anchor, upper: hi - anchor) : Footprint()
    }

    private static func footprint(_ t: [V3], lower: V3, upper: V3) -> Footprint {
        let cell = Footprint.cell
        var f = Footprint()
        f.x0 = Int((lower.x / cell).rounded(.down)) - 1
        f.y0 = Int((lower.y / cell).rounded(.down)) - 1
        f.w = Int((upper.x / cell).rounded(.up)) - f.x0 + 2
        f.h = Int((upper.y / cell).rounded(.up)) - f.y0 + 2
        guard f.w > 0, f.h > 0, f.w * f.h < 4_000_000 else { return Footprint() }
        f.lo = [Float](repeating: .infinity, count: f.w * f.h)
        f.hi = [Float](repeating: -.infinity, count: f.w * f.h)
        func plot(_ q: V3) {
            let p = V3(q.x, q.y, max(q.z, 0))       // what's behind the board's face doesn't count
            let i = Int((p.x / cell).rounded(.down)) - f.x0, j = Int((p.y / cell).rounded(.down)) - f.y0
            guard i >= 0, i < f.w, j >= 0, j < f.h else { return }
            let k = j * f.w + i
            if p.z < f.lo[k] { f.lo[k] = p.z }
            if p.z > f.hi[k] { f.hi[k] = p.z }
        }

        for n in stride(from: 0, to: t.count, by: 3) {
            var a = t[n], b = t[n + 1], c = t[n + 2]
            if max(a.z, b.z, c.z) < -0.3 { continue }
            // Pull the corners a hair inward so two parts that only touch don't share a cell.
            // (Toward the triangle's middle for faces seen flat on, against the outward normal
            // for faces seen edge on.)
            let g = (a + b + c) / 3
            let normal = simd_cross(b - a, c - a)
            let inward = V3(normal.x > 0 ? -0.05 : normal.x < 0 ? 0.05 : 0, normal.y > 0 ? -0.05 : normal.y < 0 ? 0.05 : 0, 0)
                * (simd_length(normal) > 1e-9 ? 1 : 0)
            func pulled(_ p: V3) -> V3 {
                let d = g - p, len = simd_length(d)
                return (len > 0.1 ? p + d * (0.05 / len) : p) + inward
            }
            a = pulled(a); b = pulled(b); c = pulled(c)
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let steps = max(1, Int(simd_length(q - p).rounded(.up)))
                for s in 0...steps { plot(p + (q - p) * (Float(s) / Float(steps))) }
            }
            // Cells whose centre lies inside the triangle as seen from the front.
            let den = (b.y - c.y) * (a.x - c.x) + (c.x - b.x) * (a.y - c.y)
            guard abs(den) > 1e-6 else { continue }
            let i0 = Int((min(a.x, b.x, c.x) / cell).rounded(.down)), i1 = Int((max(a.x, b.x, c.x) / cell).rounded(.down))
            let j0 = Int((min(a.y, b.y, c.y) / cell).rounded(.down)), j1 = Int((max(a.y, b.y, c.y) / cell).rounded(.down))
            guard i1 - i0 > 0 || j1 - j0 > 0 else { continue }
            for j in j0...j1 {
                for i in i0...i1 {
                    let px = (Float(i) + 0.5) * cell, py = (Float(j) + 0.5) * cell
                    let u = ((b.y - c.y) * (px - c.x) + (c.x - b.x) * (py - c.y)) / den
                    let v = ((c.y - a.y) * (px - c.x) + (a.x - c.x) * (py - c.y)) / den
                    let w = 1 - u - v
                    if u >= 0 && v >= 0 && w >= 0 { plot(V3(px, py, u * a.z + v * b.z + w * c.z)) }
                }
            }
        }
        return f
    }
}
