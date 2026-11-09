import Foundation
import simd

typealias V3 = SIMD3<Float>
typealias V2 = SIMD2<Float>

/// Triangle soup in millimetres: three vertices per triangle, in the file's own coordinates.
struct Mesh {
    var tris: [V3]
    var triangleCount: Int { tris.count / 3 }
}

struct NamedMesh {
    let name: String
    let mesh: Mesh
}

enum ModelFile {
    static let extensions = ["stl", "3mf"]

    static func isModel(_ url: URL) -> Bool { extensions.contains(url.pathExtension.lowercased()) }

    /// One mesh per printable object in the file (an STL is always one).
    static func load(_ url: URL) throws -> [NamedMesh] {
        let ext = url.pathExtension.lowercased()
        guard extensions.contains(ext) else { throw AppError(.unsupportedModelType, url.lastPathComponent) }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) } catch {
            throw AppError(.modelUnreadable, "\(url.lastPathComponent) — \(error.localizedDescription)")
        }
        let base = url.deletingPathExtension().lastPathComponent
        if ext == "stl" {
            return [NamedMesh(name: base, mesh: try STL.parse(data, file: url.lastPathComponent))]
        }
        return try ThreeMF.parse(data, file: url.lastPathComponent, baseName: base)
    }
}

enum STL {
    static func parse(_ data: Data, file: String) throws -> Mesh {
        var tris: [V3] = []
        if data.count >= 84 {
            let n = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 80, as: UInt32.self) })
            if n > 0 && 84 + 50 * n == data.count {
                tris.reserveCapacity(n * 3)
                data.withUnsafeBytes { raw in
                    for t in 0..<n {
                        let base = 84 + 50 * t + 12
                        for k in 0..<3 {
                            let o = base + 12 * k
                            tris.append(V3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                           raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                           raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
                        }
                    }
                }
            }
        }
        if tris.isEmpty { tris = ascii(data) }
        guard !tris.isEmpty, tris.count % 3 == 0 else {
            throw AppError(.badSTL, "\(file): \(data.count) bytes, no triangles found")
        }
        guard tris.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw AppError(.badSTL, "\(file): contains coordinates that aren't numbers")
        }
        return Mesh(tris: tris)
    }

    /// Text STL: every "vertex x y z" line, three per facet.
    private static func ascii(_ data: Data) -> [V3] {
        var out: [V3] = []
        let bytes = [UInt8](data)
        let key = Array("vertex".utf8)
        var i = 0
        let n = bytes.count
        func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 }
        while i < n {
            while i < n && isSpace(bytes[i]) { i += 1 }
            var j = i
            while j < n && !isSpace(bytes[j]) { j += 1 }
            if j - i == key.count && bytes[i..<j].elementsEqual(key) {
                var v = [Float]()
                var p = j
                for _ in 0..<3 {
                    while p < n && isSpace(bytes[p]) { p += 1 }
                    var q = p
                    while q < n && !isSpace(bytes[q]) { q += 1 }
                    guard let f = Float(String(decoding: bytes[p..<q], as: UTF8.self)) else { return [] }
                    v.append(f)
                    p = q
                }
                out.append(V3(v[0], v[1], v[2]))
                j = p
            }
            i = j
        }
        return out.count % 3 == 0 ? out : []
    }
}

/// One of the 24 right-angle ways a model can sit on the board. Board axes:
/// x to the right along the board, y up, z out of the board's front face.
/// `m` is row-major, board = m · file.
struct Orientation: Codable, Equatable, Hashable {
    var m: [Int]

    /// The frame the holder scripts export in: X out from the board, Y along it, Z up.
    static let hanging = Orientation(m: [0, 1, 0, 0, 0, 1, 1, 0, 0])

    func apply(_ v: V3) -> V3 {
        V3(Float(m[0]) * v.x + Float(m[1]) * v.y + Float(m[2]) * v.z,
           Float(m[3]) * v.x + Float(m[4]) * v.y + Float(m[5]) * v.z,
           Float(m[6]) * v.x + Float(m[7]) * v.y + Float(m[8]) * v.z)
    }

    /// A quarter turn about a board axis (0 = x, 1 = y, 2 = z), counter-clockwise looking down that axis.
    func turned(about axis: Int) -> Orientation {
        let r: [Int]
        switch axis {
        case 0: r = [1, 0, 0, 0, 0, -1, 0, 1, 0]
        case 1: r = [0, 0, 1, 0, 1, 0, -1, 0, 0]
        default: r = [0, -1, 0, 1, 0, 0, 0, 0, 1]
        }
        var out = [Int](repeating: 0, count: 9)
        for i in 0..<3 { for j in 0..<3 { for k in 0..<3 { out[i * 3 + j] += r[i * 3 + k] * m[k * 3 + j] } } }
        return Orientation(m: out)
    }

    var isValid: Bool {
        guard m.count == 9, m.allSatisfy({ (-1...1).contains($0) }) else { return false }
        let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        return det == 1
    }
}
