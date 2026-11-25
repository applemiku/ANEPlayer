import AppKit
import CoreGraphics

let S: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)

func squircle(_ r: CGRect, n: CGFloat = 5.0) -> CGPath {
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    let p = CGMutablePath()
    let steps = 900
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * (ct >= 0 ? 1 : -1) * pow(abs(ct), 2 / n)
        let y = cy + b * (st >= 0 ? 1 : -1) * pow(abs(st), 2 / n)
        if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
    }
    p.closeSubpath()
    return p
}

/// 圆角多边形：从第一条边的中点起步，避免起点留下多余的直段
func roundedPolygon(_ pts: [CGPoint], radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let start = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
    p.move(to: start)
    for i in 1...pts.count {
        p.addArc(tangent1End: pts[i % pts.count],
                 tangent2End: pts[(i + 1) % pts.count],
                 radius: radius)
    }
    p.closeSubpath()
    return p
}

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setAllowsAntialiasing(true)

let bodyPath = squircle(body)
let bgGrad = CGGradient(colorsSpace: cs,
                        colors: [color(0x9C7CF7), color(0x6E86F5), color(0x41B4E6)] as CFArray,
                        locations: [0, 0.55, 1])!
let bgStart = CGPoint(x: 190, y: 910), bgEnd = CGPoint(x: 870, y: 170)

// ── 投影 ──
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 26,
              color: CGColor(srgbRed: 0.12, green: 0.12, blue: 0.28, alpha: 0.16))
ctx.addPath(bodyPath)
ctx.setFillColor(color(0x6E86F5))
ctx.fillPath()
ctx.restoreGState()

// ── 玻璃底 ──
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
ctx.drawLinearGradient(bgGrad, start: bgStart, end: bgEnd, options: [])

let warm = CGGradient(colorsSpace: cs, colors: [color(0xFFE9F2, 0.40), color(0xFFE9F2, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawRadialGradient(warm, startCenter: CGPoint(x: 830, y: 850), startRadius: 0,
                       endCenter: CGPoint(x: 830, y: 850), endRadius: 400, options: [])

let sheen = CGGradient(colorsSpace: cs,
                       colors: [color(0xFFFFFF, 0.46), color(0xFFFFFF, 0.05), color(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 0.42, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 150, y: 950), end: CGPoint(x: 660, y: 360), options: [])

// 底部内侧压暗（玻璃厚度）
let inner = CGGradient(colorsSpace: cs, colors: [color(0x2A2F6B, 0), color(0x2A2F6B, 0.20)] as CFArray,
                       locations: [0.62, 1])!
ctx.drawLinearGradient(inner, start: CGPoint(x: 0, y: 480), end: CGPoint(x: 0, y: 100), options: [])
ctx.restoreGState()

// 边缘轻微压暗（vignette），玻璃感更实 —— 必须裁在圆角方块内
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let vig = CGGradient(colorsSpace: cs,
                     colors: [color(0x2B2A6B, 0), color(0x2B2A6B, 0), color(0x2B2A6B, 0.16)] as CFArray,
                     locations: [0, 0.72, 1])!
ctx.drawRadialGradient(vig, startCenter: CGPoint(x: 512, y: 560), startRadius: 120,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 640, options: [])
ctx.restoreGState()

// ── 外圈高光 ──
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.setLineWidth(6)
ctx.replacePathWithStrokedPath()
ctx.clip()
let rim = CGGradient(colorsSpace: cs,
                     colors: [color(0xFFFFFF, 1.0), color(0xFFFFFF, 0.22), color(0xFFFFFF, 0.66)] as CFArray,
                     locations: [0, 0.58, 1])!
ctx.drawLinearGradient(rim, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
ctx.restoreGState()

// ── 玻璃播放键 ──
let c = CGPoint(x: 524, y: 512)
let tri = roundedPolygon([CGPoint(x: c.x - 162, y: c.y + 188),
                          CGPoint(x: c.x - 162, y: c.y - 188),
                          CGPoint(x: c.x + 170, y: c.y)], radius: 32)

// 投影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -7), blur: 22,
              color: CGColor(srgbRed: 0.08, green: 0.08, blue: 0.30, alpha: 0.26))
ctx.addPath(tri)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.20))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tri)
ctx.clip()

// 折射：把背景渐变按偏移再画一遍，模拟玻璃把后面的光掰弯
ctx.saveGState()
ctx.translateBy(x: -26, y: 34)
ctx.drawLinearGradient(bgGrad, start: bgStart, end: bgEnd, options: [])
ctx.restoreGState()

// 磨砂白 + 上亮下暗
let frost = CGGradient(colorsSpace: cs,
                       colors: [color(0xFFFFFF, 0.54), color(0xFFFFFF, 0.34), color(0xFFFFFF, 0.22)] as CFArray,
                       locations: [0, 0.55, 1])!
ctx.drawLinearGradient(frost, start: CGPoint(x: 372, y: 690), end: CGPoint(x: 684, y: 334), options: [])

// 底部内侧一点点蓝，像光在玻璃里的散射
let scatter = CGGradient(colorsSpace: cs, colors: [color(0xA8D8FF, 0), color(0xA8D8FF, 0.30)] as CFArray,
                         locations: [0.5, 1])!
ctx.drawLinearGradient(scatter, start: CGPoint(x: 0, y: 600), end: CGPoint(x: 0, y: 334), options: [])

// 顶面镜面反光条
let spec = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.85), color(0xFFFFFF, 0)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(spec, start: CGPoint(x: 380, y: 690), end: CGPoint(x: 470, y: 610), options: [])
ctx.restoreGState()

// 棱边
ctx.saveGState()
ctx.addPath(tri)
ctx.setLineWidth(5)
ctx.replacePathWithStrokedPath()
ctx.clip()
let triRim = CGGradient(colorsSpace: cs,
                        colors: [color(0xFFFFFF, 1.0), color(0xFFFFFF, 0.45)] as CFArray,
                        locations: [0, 1])!
ctx.drawLinearGradient(triRim, start: CGPoint(x: 372, y: 690), end: CGPoint(x: 684, y: 334), options: [])
ctx.restoreGState()

// ── 左上角镜面高光 ──
ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let hl = CGGradient(colorsSpace: cs, colors: [color(0xFFFFFF, 0.50), color(0xFFFFFF, 0)] as CFArray,
                    locations: [0, 1])!
ctx.drawRadialGradient(hl, startCenter: CGPoint(x: 310, y: 880), startRadius: 0,
                       endCenter: CGPoint(x: 310, y: 880), endRadius: 250, options: [])
ctx.restoreGState()

guard let img = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: img)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/icon/icon5_1024.png"))
print("ok")
