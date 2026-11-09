import AppKit

// Draws the app icon (a pegboard with a holder on it) and writes Resources/AppIcon.icns.
// iconutil isn't needed: an .icns is just a list of PNGs.
// Usage: swiftc -o makeicon Tools/makeicon.swift && ./makeicon Resources/AppIcon.icns [preview.png]

func png(_ size: Int) -> Data {
    let s = CGFloat(size)
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s / 1024, y: s / 1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [CGColor(gray: 0.99, alpha: 1), CGColor(gray: 0.88, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    // Slots: 5 x 15 at 20 / 40 pitch, staggered, scaled 7x.
    ctx.setFillColor(CGColor(gray: 0.22, alpha: 1))
    let k: CGFloat = 7.2
    for c in 0..<7 {
        for r in 0..<7 {
            let x = 512 + (CGFloat(c) - 3) * 20 * k
            let y = 512 + (CGFloat(r) - 3) * 40 * k + (c % 2 == 0 ? 0 : 20 * k)
            let rect = CGRect(x: x - 2.5 * k, y: y - 7.5 * k, width: 5 * k, height: 15 * k)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 2.5 * k, cornerHeight: 2.5 * k, transform: nil))
        }
    }
    ctx.fillPath()
    // A holder: back plate and a shelf with a front lip.
    ctx.setShadow(offset: CGSize(width: 10, height: -18), blur: 30, color: CGColor(gray: 0, alpha: 0.4))
    let blue = CGColor(red: 0.16, green: 0.45, blue: 0.86, alpha: 1)
    ctx.setFillColor(blue)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 270, y: 330, width: 484, height: 250), cornerWidth: 26, cornerHeight: 26, transform: nil))
    ctx.fillPath()
    ctx.setFillColor(CGColor(red: 0.10, green: 0.33, blue: 0.70, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 240, y: 270, width: 544, height: 120), cornerWidth: 30, cornerHeight: 30, transform: nil))
    ctx.fillPath()
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setFillColor(CGColor(red: 0.30, green: 0.58, blue: 0.95, alpha: 1))
    ctx.addPath(CGPath(roundedRect: CGRect(x: 240, y: 362, width: 544, height: 28), cornerWidth: 14, cornerHeight: 14, transform: nil))
    ctx.fillPath()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func be(_ v: Int) -> Data { Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)]) }

var body = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128), ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                     ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let image = png(size)
    body += Data(type.utf8) + be(image.count + 8) + image
}
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
try (Data("icns".utf8) + be(body.count + 8) + body).write(to: URL(fileURLWithPath: out))
if CommandLine.arguments.count > 2 { try png(256).write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }   // optional PNG preview
print("wrote \(out)")
