import AppKit

let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// Background: rounded square on the macOS icon grid with a blue gradient
let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.30))
ctx.addPath(bgPath)
ctx.setFillColor(CGColor(red: 0.16, green: 0.42, blue: 0.88, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bgPath)
ctx.clip()
let gradient = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 0.45, green: 0.74, blue: 1.00, alpha: 1),
                                   CGColor(red: 0.10, green: 0.34, blue: 0.84, alpha: 1)] as CFArray,
                          locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Soft highlight at the top
ctx.setFillColor(CGColor(gray: 1, alpha: 0.10))
ctx.fillEllipse(in: CGRect(x: -100, y: 700, width: 1224, height: 520))
ctx.restoreGState()

// Three windows: a large one on the left, two stacked on the right
func drawWindow(_ r: CGRect) {
    let p = CGPath(roundedRect: r, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: CGColor(gray: 0, alpha: 0.28))
    ctx.addPath(p)
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.97))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(p)
    ctx.clip()
    let bar = CGRect(x: r.minX, y: r.maxY - 58, width: r.width, height: 58)
    ctx.setFillColor(CGColor(red: 0.86, green: 0.91, blue: 0.98, alpha: 1))
    ctx.fill(bar)
    let dots: [(CGFloat, CGFloat, CGFloat)] = [(1.00, 0.37, 0.34), (1.00, 0.74, 0.18), (0.16, 0.78, 0.30)]
    for (i, c) in dots.enumerated() {
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: r.minX + 26 + CGFloat(i) * 34, y: bar.midY - 11, width: 22, height: 22))
    }
    // A few faint lines suggesting content
    ctx.setFillColor(CGColor(red: 0.80, green: 0.86, blue: 0.95, alpha: 1))
    var y = bar.minY - 56
    var line = 0
    while y > r.minY + 40 && line < 6 {
        let w = r.width * (line % 3 == 1 ? 0.45 : 0.68)
        ctx.fill(CGRect(x: r.minX + 30, y: y, width: w, height: 14))
        y -= 46
        line += 1
    }
    ctx.restoreGState()
}

drawWindow(CGRect(x: 206, y: 226, width: 334, height: 572))
drawWindow(CGRect(x: 576, y: 522, width: 242, height: 276))
drawWindow(CGRect(x: 576, y: 226, width: 242, height: 276))

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("wrote", CommandLine.arguments[1])
