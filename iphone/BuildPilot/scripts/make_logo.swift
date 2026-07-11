// Generates the default placeholder company logo (1200x360 PNG, white bg).
// Run from iphone/BuildPilot:  swift scripts/make_logo.swift
// Design: charcoal roller glyph + modern spaced wordmark — a believable
// premium painting company, neutral colours, vector style.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 1200, height = 360
let ctx = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

let charcoal = CGColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 1)
let grey = CGColor(srgbRed: 0.52, green: 0.54, blue: 0.57, alpha: 1)

// White background (prints cleanly)
ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

// Roller glyph: rounded roller head + frame + handle, charcoal strokes
ctx.setStrokeColor(charcoal)
ctx.setFillColor(charcoal)
ctx.setLineWidth(16)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
// roller head (filled rounded rect)
let head = CGPath(roundedRect: CGRect(x: 70, y: 218, width: 170, height: 62),
                  cornerWidth: 18, cornerHeight: 18, transform: nil)
ctx.addPath(head); ctx.fillPath()
// frame from head to handle
let frame = CGMutablePath()
frame.move(to: CGPoint(x: 250, y: 249))
frame.addLine(to: CGPoint(x: 286, y: 249))
frame.addLine(to: CGPoint(x: 286, y: 170))
frame.addLine(to: CGPoint(x: 236, y: 170))
frame.addLine(to: CGPoint(x: 236, y: 96))
ctx.addPath(frame); ctx.strokePath()
// handle grip
let grip = CGPath(roundedRect: CGRect(x: 216, y: 40, width: 40, height: 64),
                  cornerWidth: 12, cornerHeight: 12, transform: nil)
ctx.addPath(grip); ctx.fillPath()

func draw(_ text: String, size: CGFloat, weight: CFString, color: CGColor, at point: CGPoint, kerning: CGFloat) {
    let font = CTFontCreateWithName(weight, size, nil)
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
        kCTKernAttributeName: kerning,
    ]
    let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attributed)
    ctx.textPosition = point
    CTLineDraw(line, ctx)
}

draw("NORDHUS", size: 118, weight: "HelveticaNeue-Bold" as CFString,
     color: charcoal, at: CGPoint(x: 360, y: 170), kerning: 10)
draw("PAINTING & DECORATING", size: 32,
     weight: "HelveticaNeue-Medium" as CFString,
     color: grey, at: CGPoint(x: 366, y: 100), kerning: 11)

let image = ctx.makeImage()!
let outputURL = URL(fileURLWithPath: "Assets.xcassets/DefaultLogo.imageset/default-logo.png")
try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)
let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(outputURL.path)")
