import AppKit
import SceneKit
import SwiftUI

// Draws the board scene and the real window to PNGs, without opening anything on screen.
// Usage: snapshot <output dir> <model files…>

let args = CommandLine.arguments
let outDir = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let files = args.dropFirst(2).map { URL(fileURLWithPath: $0) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func wait(_ model: AppModel) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    while model.loading > 0 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
}

MainActor.assumeIsolated {
    let model = AppModel(persists: false)
    for f in files { model.addFiles([f]); wait(model) }
    for item in model.items {
        let a = model.analysis(for: item)!
        print("\(item.name): column \(item.column) level \(item.level), hooks \(a.hooks.count), issues \((model.issues[item.id] ?? []).map(\.text))")
    }

    let device = MTLCreateSystemDefaultDevice()
    print("Metal device: \(device?.name ?? "none"); all: \(MTLCopyAllDevices().map(\.name))")
    let renderer = device != nil ? SCNRenderer(device: device, options: nil) : SCNRenderer(context: nil, options: nil)
    renderer.scene = model.scene.scene
    renderer.pointOfView = model.scene.rig.node
    func render(_ name: String, _ preset: CameraRig.Preset) {
        model.scene.rig.aspect = 1.5
        model.scene.rig.set(preset)
        let image = renderer.snapshot(atTime: 0, with: CGSize(width: 1500, height: 1000), antialiasingMode: .multisampling4X)
        print("image \(image.size) reps \(image.representations.count)")
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
            print("wrote \(name)")
        }
    }
    render("scene-3d.png", .threeD)
    render("scene-front.png", .front)
    render("scene-side.png", .side)

    // Push the last model onto the first to show an overlap.
    if model.items.count > 1, let first = model.items.first, let last = model.items.last {
        model.beginDrag()
        let p = model.position(of: first)
        model.drag(last.id, to: V2(p.x + 40, p.y))
        model.endDrag()
        print("after overlap: \((model.issues[last.id] ?? []).map(\.text))")
        render("scene-overlap.png", .threeD)
        model.undo.undo()
    }

    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    @discardableResult
    func window(_ name: String, keep: Bool = false) -> (NSWindow, NSView)? {
        let size = NSSize(width: 1280, height: 780)
        let hosting = NSHostingView(rootView: ContentView().environmentObject(model))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { print("no rep"); return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        // The 3D view draws with Metal, which cacheDisplay can't see: paste its own snapshot in.
        if let board = find(BoardView.self, in: hosting) {
            let shot = board.snapshot()
            let frame = board.convert(board.bounds, to: hosting)
            let image = NSImage(size: size)
            image.lockFocus()
            rep.draw(in: NSRect(origin: .zero, size: size))
            shot.draw(in: NSRect(x: frame.minX, y: size.height - frame.maxY, width: frame.width, height: frame.height))
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let out = NSBitmapImageRep(data: tiff) {
                try? out.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
            }
        } else {
            try? rep.representation(using: .png, properties: [:])?.write(to: outDir.appendingPathComponent(name))
        }
        print("wrote \(name)")
        if keep { return (window, hosting) }
        window.orderOut(nil)
        return nil
    }
    model.selection = nil
    window("window-board.png")
    model.selection = model.items.first?.id
    guard let (win, hosting) = window("window-item.png", keep: true), let board = find(BoardView.self, in: hosting) else { exit(0) }

    // Drive the real view with mouse events: click the last model, drag it down and right.
    func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: board.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: win.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
    model.scene.rig.set(.front)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if let item = model.items.last, let a = model.analysis(for: item) {
        var best = V3(0, 0, -1)
        for i in stride(from: 0, to: a.tris.count, by: 3) {
            let n = simd_cross(a.tris[i + 1] - a.tris[i], a.tris[i + 2] - a.tris[i])
            let c = (a.tris[i] + a.tris[i + 1] + a.tris[i + 2]) / 3
            if n.z > 0.9 * simd_length(n), simd_length(n) > 8, c.z > best.z { best = c }
        }
        let world = model.position(of: item) + best
        let on = board.projectPoint(SCNVector3(world.x, world.y, world.z))
        let start = NSPoint(x: on.x, y: on.y)
        let before = (item.column, item.level)
        model.selection = nil
        board.mouseDown(with: event(.leftMouseDown, start))
        print("click selects the model: \(model.selection == item.id ? "ok" : "FAIL")")
        for step in 1...10 {
            board.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: start.x + CGFloat(step) * 9, y: start.y - CGFloat(step) * 12)))
        }
        board.mouseUp(with: event(.leftMouseUp, NSPoint(x: start.x + 90, y: start.y - 120)))
        let moved = model.item(item.id)!
        let p0 = model.board.slotCentre(before.0, before.1), p1 = model.board.slotCentre(moved.column, moved.level)
        let scale = Float(on.x - board.projectPoint(SCNVector3(world.x - 100, world.y, world.z)).x) / 100      // points per mm
        print("drag moved it \(p1.x - p0.x) mm right, \(p0.y - p1.y) mm down (mouse went \(90 / scale), \(120 / scale)); on a slot: \(model.board.hasSlot(moved.column, moved.level) && moved.dx == 0 ? "ok" : "FAIL")")
        print("moved roughly with the mouse: \(abs((p1.x - p0.x) - 90 / scale) <= 21 && abs((p0.y - p1.y) - 120 / scale) <= 21 ? "ok" : "FAIL")")
        model.undo.undo()
        let back = model.item(item.id)!
        print("undo puts it back: \((back.column, back.level) == before ? "ok" : "FAIL")")
        board.mouseDown(with: event(.leftMouseDown, NSPoint(x: 5, y: 5)))
        board.mouseUp(with: event(.leftMouseUp, NSPoint(x: 5, y: 5)))
        print("clicking empty space deselects: \(model.selection == nil ? "ok" : "FAIL")")
        model.selection = item.id
        model.turn(item.id, about: 2)
        print("after a spin: hooks \(model.analysis(for: model.item(item.id)!)!.hooks.count), issues \((model.issues[item.id] ?? []).map(\.text))")
        model.resetOrientation(item.id)
        print("find hooks again: \(model.item(item.id)!.orientation == .hanging ? "ok" : "FAIL")")
    }
}
