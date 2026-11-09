import AppKit
import SceneKit
import simd

/// Where the camera is: it orbits a target point on the board.
final class CameraRig {
    enum Preset { case front, side, top, threeD }

    let node = SCNNode()
    var target = V3(280, 280, 0)
    var yaw: Float = 0.45          // radians round the vertical axis; 0 looks straight at the board
    var pitch: Float = 0.2         // radians above the horizontal
    var distance: Float = 1600
    var aspect: Float = 1.4
    /// Front, side and top views are drawn without perspective, so sizes and gaps read true.
    private(set) var view = Preset.threeD
    private var board = Board.standard
    static let fov: Float = 30

    init() {
        let cam = SCNCamera()
        cam.fieldOfView = CGFloat(CameraRig.fov)
        cam.zNear = 5
        cam.zFar = 30000
        node.camera = cam
        apply()
    }

    func apply() {
        pitch = min(max(pitch, -1.57), 1.57)
        distance = min(max(distance, 60), 12000)
        let dir = V3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        let flat = view != .threeD
        node.camera?.usesOrthographicProjection = flat
        node.camera?.orthographicScale = Double(distance * tan(CameraRig.fov * .pi / 360))
        node.simdPosition = target + dir * (flat ? max(distance, 4000) : distance)
        node.simdLook(at: target, up: V3(0, 1, 0), localFront: V3(0, 0, -1))
    }

    /// Frame the whole board from the current angle.
    func fit(_ b: Board? = nil) {
        if let b { board = b }
        let reach: Float = 260                    // room in front of the board for what hangs on it
        var across = board.width, up = board.height
        target = V3(board.width / 2, board.height / 2, 0)
        switch view {
        case .front: break
        case .side: across = reach * 2; target.z = reach / 2
        case .top: up = reach * 2; target.z = reach / 2
        case .threeD: across = sqrt(board.width * board.width + 200 * 200)
        }
        let half = tan(CameraRig.fov * .pi / 360)
        distance = max(up / (2 * half), across / (2 * half * max(aspect, 0.3))) * 1.1
        apply()
    }

    func set(_ p: Preset) {
        view = p
        switch p {
        case .front: (yaw, pitch) = (0, 0)
        case .side: (yaw, pitch) = (.pi / 2 - 0.001, 0)
        case .top: (yaw, pitch) = (0, .pi / 2 - 0.001)
        case .threeD: (yaw, pitch) = (0.45, 0.2)
        }
        fit()
    }

    func orbit(dx: Float, dy: Float) {
        view = .threeD
        yaw -= dx * 0.008
        pitch += dy * 0.008
        apply()
    }

    /// Slide the target across the screen by a number of points.
    func pan(dx: Float, dy: Float, viewHeight: Float) {
        let scale = 2 * distance * tan(CameraRig.fov * .pi / 360) / max(viewHeight, 1)
        let t = node.simdWorldTransform
        let right = V3(t.columns.0.x, t.columns.0.y, t.columns.0.z)
        let up = V3(t.columns.1.x, t.columns.1.y, t.columns.1.z)
        target -= (right * dx + up * dy) * scale
        apply()
    }

    func zoom(by factor: Float) {
        distance *= factor
        apply()
    }
}

/// The SceneKit scene: the wall, the board with its slots cut through, and one node per placed model.
final class BoardScene {
    let scene = SCNScene()
    let rig = CameraRig()
    private let boardNode = SCNNode()
    private let wallNode = SCNNode()
    private let itemsNode = SCNNode()
    private var shownBoard: Board?
    private var nodes: [UUID: SCNNode] = [:]

    static let wallColor = NSColor(calibratedRed: 0.80, green: 0.79, blue: 0.76, alpha: 1)
    /// IKEA's connectors hold the board about this far off the wall.
    static let wallGap: Float = 13

    init() {
        scene.background.contents = NSColor(calibratedRed: 0.62, green: 0.62, blue: 0.60, alpha: 1)
        scene.rootNode.addChildNode(rig.node)
        scene.rootNode.addChildNode(wallNode)
        scene.rootNode.addChildNode(boardNode)
        scene.rootNode.addChildNode(itemsNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 330
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        let key = SCNLight()
        key.type = .directional
        key.intensity = 760
        key.castsShadow = true
        key.maximumShadowDistance = 20000
        key.shadowCascadeCount = 2
        key.shadowColor = NSColor(white: 0, alpha: 0.32)
        key.shadowRadius = 5
        key.shadowSampleCount = 16
        key.shadowMapSize = CGSize(width: 4096, height: 4096)
        let keyNode = SCNNode()
        keyNode.light = key
        keyNode.simdPosition = V3(-600, 1500, 1500)
        keyNode.simdLook(at: V3(300, 300, 0), up: V3(0, 1, 0), localFront: V3(0, 0, -1))
        scene.rootNode.addChildNode(keyNode)

        let fill = SCNLight()
        fill.type = .directional
        fill.intensity = 220
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdPosition = V3(1500, 200, 1200)
        fillNode.simdLook(at: V3(300, 300, 0), up: V3(0, 1, 0), localFront: V3(0, 0, -1))
        scene.rootNode.addChildNode(fillNode)
    }

    // MARK: Board

    private static func finishColor(_ f: Board.Finish) -> NSColor {
        switch f {
        case .white: return NSColor(calibratedWhite: 0.96, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.13, alpha: 1)
        case .wood: return NSColor(calibratedRed: 0.80, green: 0.66, blue: 0.46, alpha: 1)
        case .grey: return NSColor(calibratedWhite: 0.62, alpha: 1)
        }
    }

    static func boardGeometry(_ b: Board) -> SCNGeometry {
        let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: CGFloat(b.width), height: CGFloat(b.height)),
                                xRadius: 8, yRadius: 8)
        let w = CGFloat(Board.slotWidth), l = CGFloat(Board.slotLength)
        for c in 0..<b.columns {
            for lvl in 0..<b.levels where b.hasSlot(c, lvl) {
                let s = b.slotCentre(c, lvl)
                path.appendRoundedRect(NSRect(x: CGFloat(s.x) - w / 2, y: CGFloat(s.y) - l / 2, width: w, height: l),
                                       xRadius: w / 2, yRadius: w / 2)
            }
        }
        path.windingRule = .evenOdd
        path.flatness = 0.15
        let shape = SCNShape(path: path, extrusionDepth: CGFloat(Board.thickness))
        let m = SCNMaterial()
        m.diffuse.contents = finishColor(b.finish)
        m.specular.contents = NSColor(white: 0.15, alpha: 1)
        m.lightingModel = .blinn
        shape.materials = [m]
        return shape
    }

    private func showBoard(_ b: Board) {
        guard b != shownBoard else { return }
        shownBoard = b
        boardNode.geometry = BoardScene.boardGeometry(b)
        boardNode.simdPosition = V3(0, 0, -Board.thickness / 2)        // SCNShape extrudes about z = 0
        let wall = SCNPlane(width: CGFloat(b.width) + 3000, height: CGFloat(b.height) + 3000)
        let m = SCNMaterial()
        m.diffuse.contents = BoardScene.wallColor
        m.lightingModel = .lambert
        wall.materials = [m]
        wallNode.geometry = wall
        wallNode.simdPosition = V3(b.width / 2, b.height / 2, -Board.thickness - BoardScene.wallGap)
    }

    // MARK: Items

    static func geometry(for a: Analysis) -> SCNGeometry {
        if let g = a.renderCache as? SCNGeometry { return g }
        let n = a.tris.count
        var pos = [Float](repeating: 0, count: n * 3), nor = [Float](repeating: 0, count: n * 3)
        for i in stride(from: 0, to: n, by: 3) {
            var normal = simd_cross(a.tris[i + 1] - a.tris[i], a.tris[i + 2] - a.tris[i])
            let len = simd_length(normal)
            normal = len > 0 ? normal / len : V3(0, 0, 1)
            for k in 0..<3 {
                let v = a.tris[i + k], o = (i + k) * 3
                pos[o] = v.x; pos[o + 1] = v.y; pos[o + 2] = v.z
                nor[o] = normal.x; nor[o + 1] = normal.y; nor[o + 2] = normal.z
            }
        }
        func source(_ values: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            SCNGeometrySource(data: values.withUnsafeBufferPointer { Data(buffer: $0) }, semantic: semantic,
                              vectorCount: n, usesFloatComponents: true, componentsPerVector: 3,
                              bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
        }
        let indices = (0..<UInt32(n)).map { $0 }
        let element = SCNGeometryElement(data: indices.withUnsafeBufferPointer { Data(buffer: $0) },
                                         primitiveType: .triangles, primitiveCount: n / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: [source(pos, .vertex), source(nor, .normal)], elements: [element])
        a.renderCache = g
        return g
    }

    private struct Look: Equatable {
        var analysis: ObjectIdentifier
        var color: RGB
        var selected: Bool
        var problem: Bool
    }
    private var looks: [UUID: Look] = [:]

    func sync(_ model: AppModel) {
        showBoard(model.board)
        var seen = Set<UUID>()
        for item in model.items {
            guard let a = model.analysis(for: item) else { continue }
            seen.insert(item.id)
            let node: SCNNode
            if let n = nodes[item.id] { node = n } else {
                node = SCNNode()
                node.name = item.id.uuidString
                node.castsShadow = true
                itemsNode.addChildNode(node)
                nodes[item.id] = node
            }
            let look = Look(analysis: ObjectIdentifier(a), color: item.color, selected: model.selection == item.id,
                            problem: model.hasProblem(item.id))
            if looks[item.id] != look {
                if looks[item.id]?.analysis != look.analysis || node.geometry == nil {
                    node.geometry = (BoardScene.geometry(for: a).copy() as! SCNGeometry)
                }
                let m = SCNMaterial()
                m.lightingModel = .blinn
                m.isDoubleSided = true
                // A model with a problem turns mostly red, keeping a little of its own colour.
                let k = look.problem ? 0.72 : 0.0
                m.diffuse.contents = NSColor(calibratedRed: item.color.r * (1 - k) + 0.90 * k, green: item.color.g * (1 - k) + 0.10 * k,
                                             blue: item.color.b * (1 - k) + 0.08 * k, alpha: 1)
                m.specular.contents = NSColor(white: 0.25, alpha: 1)
                m.shininess = 0.3
                if look.problem {
                    m.emission.contents = NSColor(calibratedRed: look.selected ? 0.40 : 0.22, green: 0.0, blue: 0.0, alpha: 1)
                } else if look.selected {
                    m.emission.contents = NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.30, alpha: 1)
                }
                node.geometry?.materials = [m]
                looks[item.id] = look
            }
            node.simdPosition = model.position(of: item)
        }
        for (id, node) in nodes where !seen.contains(id) {
            node.removeFromParentNode()
            nodes[id] = nil
            looks[id] = nil
        }
    }
}

/// The 3D view. Drag a model to move it across the slots. Drag empty space to orbit,
/// right-drag (or hold Option or Shift) to pan, scroll or pinch to zoom.
final class BoardView: SCNView {
    weak var model: AppModel?

    private enum Drag {
        case none
        case orbit
        case pan
        case item(id: UUID, grabbed: V2, anchor: V2, planeZ: Float, moved: Bool)
    }
    private var drag = Drag.none
    private var fitted = false
    private var downPoint = NSPoint.zero

    private var rig: CameraRig? { model?.scene.rig }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        guard let rig, bounds.height > 0 else { return }
        let aspect = Float(bounds.width / bounds.height)
        if abs(aspect - rig.aspect) > 0.01 || !fitted {
            rig.aspect = aspect
            if !fitted, let b = model?.board {     // frame the board once the view knows its shape
                fitted = true
                rig.fit(b)
            }
        }
    }

    /// Where the ray under a view point crosses the plane z = planeZ (in board coordinates).
    private func boardPoint(_ p: NSPoint, planeZ: Float) -> V2? {
        let near = unprojectPoint(SCNVector3(p.x, p.y, 0)), far = unprojectPoint(SCNVector3(p.x, p.y, 1))
        let a = V3(Float(near.x), Float(near.y), Float(near.z)), b = V3(Float(far.x), Float(far.y), Float(far.z))
        let d = b - a
        guard abs(d.z) > 1e-6 else { return nil }
        let t = (planeZ - a.z) / d.z
        guard t > 0 else { return nil }
        return V2(a.x + d.x * t, a.y + d.y * t)
    }

    private func itemID(at p: NSPoint) -> (UUID, SCNHitTestResult)? {
        for hit in hitTest(p, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue]) {
            if let name = hit.node.name, let id = UUID(uuidString: name) { return (id, hit) }
            return nil                      // the board or the wall is in front
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        if event.modifierFlags.contains(.option) || event.modifierFlags.contains(.shift) { drag = .pan; return }
        if let model, let (id, hit) = itemID(at: p), let item = model.item(id) {
            model.selection = id
            let z = Float(hit.worldCoordinates.z)
            if let g = boardPoint(p, planeZ: z) {
                let pos = model.position(of: item)
                drag = .item(id: id, grabbed: g, anchor: V2(pos.x, pos.y), planeZ: z, moved: false)
                return
            }
        }
        drag = .orbit
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .orbit:
            rig?.orbit(dx: Float(event.deltaX), dy: Float(event.deltaY))
        case .pan:
            rig?.pan(dx: Float(event.deltaX), dy: -Float(event.deltaY), viewHeight: Float(bounds.height))
        case .item(let id, let grabbed, let anchor, let planeZ, let moved):
            guard hypot(p.x - downPoint.x, p.y - downPoint.y) > 3 || moved, let now = boardPoint(p, planeZ: planeZ) else { return }
            if !moved {
                model?.beginDrag()
                drag = .item(id: id, grabbed: grabbed, anchor: anchor, planeZ: planeZ, moved: true)
            }
            model?.drag(id, to: anchor + (now - grabbed))
        case .none: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch drag {
        case .item(_, _, _, _, let moved) where moved:
            model?.endDrag()
        case .orbit where hypot(p.x - downPoint.x, p.y - downPoint.y) < 3:
            model?.selection = nil          // a plain click on the board or the wall
        default: break
        }
        drag = .none
    }

    override func rightMouseDown(with event: NSEvent) { drag = .pan }
    override func rightMouseDragged(with event: NSEvent) {
        rig?.pan(dx: Float(event.deltaX), dy: -Float(event.deltaY), viewHeight: Float(bounds.height))
    }
    override func rightMouseUp(with event: NSEvent) { drag = .none }
    override func otherMouseDragged(with event: NSEvent) { rightMouseDragged(with: event) }

    override func scrollWheel(with event: NSEvent) {
        let dy = Float(event.scrollingDeltaY)
        guard dy != 0 else { return }
        rig?.zoom(by: exp(-dy * (event.hasPreciseScrollingDeltas ? 0.004 : 0.05)))
    }

    override func magnify(with event: NSEvent) {
        rig?.zoom(by: 1 / (1 + Float(event.magnification)))
    }

    override func keyDown(with event: NSEvent) {
        guard let model, let id = model.selection else { super.keyDown(with: event); return }
        let half = event.modifierFlags.contains(.option)
        switch event.keyCode {
        case 123: model.step(id, dc: -1, dl: 0, half: half)
        case 124: model.step(id, dc: 1, dl: 0, half: half)
        case 125: model.step(id, dc: 0, dl: -1)
        case 126: model.step(id, dc: 0, dl: 1)
        case 51, 117: model.remove(id)
        case 53: model.selection = nil
        default: super.keyDown(with: event)
        }
    }
}
