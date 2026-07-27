import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

NSColor.clear.setFill()
NSRect(origin: .zero, size: size).fill()

guard let symbol = NSImage(
    systemSymbolName: "arrow.left.arrow.right.circle.fill",
    accessibilityDescription: "AccountDock"
)?.withSymbolConfiguration(
    NSImage.SymbolConfiguration(pointSize: 780, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [
            NSColor(calibratedWhite: 0.96, alpha: 1),
            NSColor(calibratedWhite: 0.38, alpha: 1)
        ]))
) else {
    fatalError("Required SF Symbol is unavailable")
}

NSColor(calibratedWhite: 0.93, alpha: 1).set()
let symbolRect = NSRect(x: 122, y: 122, width: 780, height: 780)
symbol.draw(
    in: symbolRect,
    from: .zero,
    operation: .sourceOver,
    fraction: 1,
    respectFlipped: true,
    hints: nil
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
