import AppKit
import SceneKit
import simd

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
