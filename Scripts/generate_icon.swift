import AppKit

let output = CommandLine.arguments[1]
let size = 1024
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                                   bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create icon context") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

let background = NSBezierPath(roundedRect: NSRect(x: 24, y: 24, width: 976, height: 976), xRadius: 216, yRadius: 216)
background.addClip()
NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.29, blue: 0.43, alpha: 1),
           ending: NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.23, alpha: 1))!
    .draw(in: background, angle: 115)

func card(_ rect: NSRect, color: NSColor) {
    let path = NSBezierPath(roundedRect: rect, xRadius: 52, yRadius: 52)
    color.setFill()
    path.fill()
}

card(NSRect(x: 230, y: 242, width: 585, height: 514), color: NSColor(calibratedWhite: 1, alpha: 0.22))
card(NSRect(x: 191, y: 282, width: 585, height: 514), color: NSColor(calibratedWhite: 1, alpha: 0.48))
card(NSRect(x: 151, y: 323, width: 585, height: 514), color: .white)

let inset = NSBezierPath(roundedRect: NSRect(x: 196, y: 370, width: 496, height: 419), xRadius: 29, yRadius: 29)
NSColor(calibratedRed: 0.83, green: 0.93, blue: 0.96, alpha: 1).setFill()
inset.fill()

let hills = NSBezierPath()
hills.move(to: NSPoint(x: 196, y: 370))
hills.line(to: NSPoint(x: 377, y: 608))
hills.line(to: NSPoint(x: 474, y: 500))
hills.line(to: NSPoint(x: 578, y: 648))
hills.line(to: NSPoint(x: 692, y: 485))
hills.line(to: NSPoint(x: 692, y: 370))
hills.close()
NSColor(calibratedRed: 0.24, green: 0.64, blue: 0.67, alpha: 1).setFill()
hills.fill()

let sun = NSBezierPath(ovalIn: NSRect(x: 522, y: 671, width: 75, height: 75))
NSColor(calibratedRed: 1, green: 0.70, blue: 0.29, alpha: 1).setFill()
sun.fill()

let sparkle = NSBezierPath()
sparkle.move(to: NSPoint(x: 774, y: 786))
sparkle.line(to: NSPoint(x: 794, y: 851))
sparkle.line(to: NSPoint(x: 813, y: 786))
sparkle.line(to: NSPoint(x: 878, y: 766))
sparkle.line(to: NSPoint(x: 813, y: 746))
sparkle.line(to: NSPoint(x: 794, y: 681))
sparkle.line(to: NSPoint(x: 774, y: 746))
sparkle.line(to: NSPoint(x: 709, y: 766))
sparkle.close()
NSColor(calibratedRed: 1, green: 0.79, blue: 0.42, alpha: 1).setFill()
sparkle.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode icon") }
try png.write(to: URL(fileURLWithPath: output), options: .atomic)
