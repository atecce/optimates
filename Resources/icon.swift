// swift Resources/icon.swift Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
// Render Optimates' placeholder app icon: 1024×1024, opaque (the App Store
// rejects icons with an alpha channel), a gold serif O on dark blue.
import AppKit
import CoreText

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed: 0.07, green: 0.11, blue: 0.22, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

let font = CTFontCreateWithName("Didot" as CFString, 760, nil)
let gold = CGColor(srgbRed: 0.85, green: 0.69, blue: 0.33, alpha: 1)
let text = NSAttributedString(string: "O", attributes: [
    NSAttributedString.Key(kCTFontAttributeName as String): font,
    NSAttributedString.Key(kCTForegroundColorAttributeName as String): gold])
let line = CTLineCreateWithAttributedString(text)
// The glyph's own ink, not the font's line box, so the O is truly centred.
let ink = CTLineGetImageBounds(line, ctx)
ctx.textPosition = CGPoint(x: (CGFloat(size) - ink.width) / 2 - ink.minX,
                           y: (CGFloat(size) - ink.height) / 2 - ink.minY)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
