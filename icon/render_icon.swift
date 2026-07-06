import AppKit

// Рендерит иконку приложения 1024×1024 в PNG.
// Дизайн: бирюзово-зелёный «squircle» (палитра отлична от Manager Assistant)
// со стилизованным белым «мозгом»: два полушария из дуг + извилины-штрихи.
// Рисуем NSBezierPath-ами, без emoji-шрифтов — рендер детерминирован.

let size = 1024
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("no rep") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

let s = CGFloat(size)
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

// Фон-squircle с отступом от краёв (как у нативных macOS-иконок).
let margin: CGFloat = 88
let bgRect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 210, yRadius: 210)

NSGraphicsContext.saveGraphicsState()
bgPath.addClip()
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 0.05, green: 0.65, blue: 0.60, alpha: 1.0),
    NSColor(srgbRed: 0.10, green: 0.40, blue: 0.55, alpha: 1.0)
])!
gradient.draw(in: bgRect, angle: -90)
NSGraphicsContext.restoreGraphicsState()

// «Мозг»: овал из двух полушарий с вертикальной ложбинкой посередине
// и извилинами-штрихами внутри. Всё — толстые белые обводки.
NSColor.white.setStroke()

let cx = s / 2
let cy = s / 2 + 20

// Контур мозга — широкий овал.
let brainRect = NSRect(x: cx - 270, y: cy - 210, width: 540, height: 420)
let outline = NSBezierPath(ovalIn: brainRect)
outline.lineWidth = 44
outline.stroke()

// Межполушарная борозда — вертикальная линия по центру.
let fissure = NSBezierPath()
fissure.move(to: NSPoint(x: cx, y: cy + 210))
fissure.line(to: NSPoint(x: cx, y: cy - 210))
fissure.lineWidth = 36
fissure.lineCapStyle = .round
fissure.stroke()

/// Извилина: дуга-«скобка» внутри полушария. dx — зеркалирование (±1).
func gyrus(dx: CGFloat, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: cx + dx * x, y: cy + y))
    path.curve(
        to: NSPoint(x: cx + dx * x, y: cy + y - h),
        controlPoint1: NSPoint(x: cx + dx * (x + w), y: cy + y - h * 0.15),
        controlPoint2: NSPoint(x: cx + dx * (x + w), y: cy + y - h * 0.85)
    )
    path.lineWidth = 34
    path.lineCapStyle = .round
    path.stroke()
}

// По три извилины на полушарие, зеркально.
for dx: CGFloat in [-1, 1] {
    gyrus(dx: dx, x: 70, y: 160, w: 110, h: 120)
    gyrus(dx: dx, x: 90, y: 10, w: 130, h: 130)
    gyrus(dx: dx, x: 70, y: -110, w: 100, h: 90)
}

NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("no png") }
try! data.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")
