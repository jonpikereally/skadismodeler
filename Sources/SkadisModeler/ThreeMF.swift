import Compression
import Foundation

/// Just enough of ZIP to read a 3MF: stored and deflated entries, no ZIP64.
struct ZipArchive {
    struct Entry {
        let method: Int
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    struct Failure: Error { let detail: String }

    private let bytes: [UInt8]
    private(set) var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        let n = bytes.count
        guard n >= 22 else { throw Failure(detail: "too small to be a zip archive") }
        var eocd = -1
        var i = n - 22
        let lowest = max(0, n - 22 - 65535)
        while i >= lowest {
            if u32(i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw Failure(detail: "no zip directory found") }
        let count = u16(eocd + 10)
        var p = u32(eocd + 16)
        guard count != 0xFFFF, p != 0xFFFF_FFFF else { throw Failure(detail: "ZIP64 archives aren't supported") }
        for _ in 0..<count {
            guard p + 46 <= n, u32(p) == 0x0201_4b50 else { throw Failure(detail: "damaged zip directory") }
            let nameLen = u16(p + 28), extraLen = u16(p + 30), commentLen = u16(p + 32)
            guard p + 46 + nameLen <= n else { throw Failure(detail: "damaged zip directory") }
            let name = String(decoding: bytes[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            entries[name] = Entry(method: u16(p + 10), compressedSize: u32(p + 20), size: u32(p + 24),
                                  headerOffset: u32(p + 42))
            names.append(name)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    private func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
    private func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }

    /// Entry lookup that forgives a leading slash and letter case, as 3MF part names allow.
    func find(_ name: String) -> String? {
        let wanted = name.hasPrefix("/") ? String(name.dropFirst()) : name
        if entries[wanted] != nil { return wanted }
        return names.first { $0.lowercased() == wanted.lowercased() }
    }

    func read(_ name: String) throws -> Data {
        guard let key = find(name), let e = entries[key] else { throw Failure(detail: "\(name) is missing") }
        let h = e.headerOffset
        guard e.size != 0xFFFF_FFFF, e.compressedSize != 0xFFFF_FFFF else {
            throw Failure(detail: "ZIP64 archives aren't supported")
        }
        guard h + 30 <= bytes.count, u32(h) == 0x0403_4b50 else { throw Failure(detail: "\(key) is damaged") }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard start + e.compressedSize <= bytes.count else { throw Failure(detail: "\(key) is cut short") }
        if e.method == 0 { return Data(bytes[start..<(start + e.compressedSize)]) }
        guard e.method == 8 else { throw Failure(detail: "\(key) uses compression method \(e.method)") }
        if e.size == 0 { return Data() }
        var out = Data(count: e.size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            bytes.withUnsafeBufferPointer { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, e.size,
                                          src.baseAddress! + start, e.compressedSize, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == e.size else { throw Failure(detail: "\(key) didn't decompress cleanly") }
        return out
    }
}

/// 3MF reader: meshes, components (including ones kept in other model files
/// inside the archive, as Bambu Studio and Orca write them) and build items.
enum ThreeMF {
    /// Row-vector affine transform, the way 3MF writes it: 12 numbers, last three the translation.
    struct Affine {
        var m: [Float] = [1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0]

        init() {}
        init(_ text: String?) {
            let v = (text ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).compactMap { Float($0) }
            if v.count == 12 { m = v }
        }

        func apply(_ p: V3) -> V3 {
            V3(p.x * m[0] + p.y * m[3] + p.z * m[6] + m[9],
               p.x * m[1] + p.y * m[4] + p.z * m[7] + m[10],
               p.x * m[2] + p.y * m[5] + p.z * m[8] + m[11])
        }
    }

    struct Ref {
        let path: String?
        let id: String
        let xf: Affine
    }

    struct Obj {
        var name: String?
        var verts: [V3] = []
        var tris: [UInt32] = []
        var comps: [Ref] = []
    }

    final class Doc: NSObject, XMLParserDelegate {
        var objects: [String: Obj] = [:]
        var items: [Ref] = []
        var scale: Float = 1
        private var curID: String?
        private var cur = Obj()

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "vertex":
                cur.verts.append(V3(Float(a["x"] ?? "") ?? .nan, Float(a["y"] ?? "") ?? .nan, Float(a["z"] ?? "") ?? .nan))
            case "triangle":
                if let i = UInt32(a["v1"] ?? ""), let j = UInt32(a["v2"] ?? ""), let k = UInt32(a["v3"] ?? "") {
                    cur.tris.append(i); cur.tris.append(j); cur.tris.append(k)
                }
            case "object":
                curID = a["id"]
                cur = Obj(name: a["name"])
            case "component":
                if let id = a["objectid"] { cur.comps.append(Ref(path: a["p:path"], id: id, xf: Affine(a["transform"]))) }
            case "item":
                if let id = a["objectid"] { items.append(Ref(path: a["p:path"], id: id, xf: Affine(a["transform"]))) }
            case "model":
                switch a["unit"] ?? "millimeter" {
                case "micron": scale = 0.001
                case "centimeter": scale = 10
                case "inch": scale = 25.4
                case "foot": scale = 304.8
                case "meter": scale = 1000
                default: scale = 1
                }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "object", let id = curID {
                objects[id] = cur
                curID = nil
                cur = Obj()
            }
        }
    }

    /// Object names as Orca and Bambu Studio keep them, in Metadata/model_settings.config.
    private final class Names: NSObject, XMLParserDelegate {
        var names: [String: String] = [:]
        private var object: String?
        private var inPart = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            if name == "object" { object = a["id"]; inPart = false }
            else if name == "part" { inPart = true }
            else if name == "metadata", !inPart, let o = object, a["key"] == "name", let v = a["value"], !v.isEmpty {
                names[o] = v
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "part" { inPart = false }
            if name == "object" { object = nil }
        }
    }

    static func parse(_ data: Data, file: String, baseName: String) throws -> [NamedMesh] {
        let zip: ZipArchive
        do { zip = try ZipArchive(data) } catch let f as ZipArchive.Failure {
            throw AppError(.bad3MF, "\(file): \(f.detail)")
        }
        guard let rootName = zip.find("3D/3dmodel.model") ?? zip.names.first(where: { $0.lowercased().hasSuffix(".model") })
        else { throw AppError(.bad3MF, "\(file): no 3D model inside") }

        var docs: [String: Doc] = [:]
        func doc(_ path: String) throws -> Doc {
            let key = zip.find(path) ?? path
            if let d = docs[key] { return d }
            let d = Doc()
            do {
                let parser = XMLParser(data: try zip.read(key))
                parser.delegate = d
                guard parser.parse() else {
                    throw AppError(.bad3MF, "\(file): \(key) — \(parser.parserError?.localizedDescription ?? "not valid XML")")
                }
            } catch let f as ZipArchive.Failure {
                throw AppError(.bad3MF, "\(file): \(f.detail)")
            }
            docs[key] = d
            return d
        }

        func flatten(_ ref: Ref, in path: String, through outer: [Affine], depth: Int, into out: inout [V3]) throws {
            guard depth < 16 else { return }
            let home = ref.path ?? path
            let d = try doc(home)
            guard let o = d.objects[ref.id] else { return }
            let chain = [ref.xf] + outer
            let count = UInt32(o.verts.count)
            var moved = o.verts
            for i in moved.indices {
                var p = moved[i] * d.scale
                for xf in chain { p = xf.apply(p) }
                moved[i] = p
            }
            for t in stride(from: 0, to: o.tris.count - 2, by: 3) {
                let (i, j, k) = (o.tris[t], o.tris[t + 1], o.tris[t + 2])
                guard i < count, j < count, k < count else { continue }
                out.append(moved[Int(i)]); out.append(moved[Int(j)]); out.append(moved[Int(k)])
            }
            for c in o.comps { try flatten(c, in: home, through: chain, depth: depth + 1, into: &out) }
        }

        let root = try doc(rootName)
        var names: [String: String] = [:]
        if zip.find("Metadata/model_settings.config") != nil, let cfg = try? zip.read("Metadata/model_settings.config") {
            let reader = Names()
            let parser = XMLParser(data: cfg)
            parser.delegate = reader
            if parser.parse() { names = reader.names }
        }
        // No build section (rare): treat every top-level object as an item.
        let items = root.items.isEmpty
            ? root.objects.keys.sorted().map { Ref(path: nil, id: $0, xf: Affine()) }
            : root.items
        var meshes: [(String?, Mesh)] = []
        for item in items {
            var tris: [V3] = []
            try flatten(item, in: rootName, through: [], depth: 0, into: &tris)
            guard !tris.isEmpty, tris.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { continue }
            let name = names[item.id] ?? root.objects[item.id]?.name
            meshes.append((name?.isEmpty == false ? name : nil, Mesh(tris: tris)))
        }
        guard !meshes.isEmpty else { throw AppError(.empty3MF, file) }
        if meshes.count == 1 { return [NamedMesh(name: baseName, mesh: meshes[0].1)] }
        return meshes.enumerated().map { i, m in
            NamedMesh(name: m.0.map { "\($0) (\(baseName))" } ?? "\(baseName), part \(i + 1)", mesh: m.1)
        }
    }
}
