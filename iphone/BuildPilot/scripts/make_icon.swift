// Generates the BuildMate app icon (1024x1024 PNG).
// Run from iphone/BuildPilot:  swift scripts/make_icon.swift
// Design: yellow house outline with a white "M" on black — construction-
// grade, readable at every size.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Black background
ctx.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.045, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

// House outline (yellow, rounded joins): body + roof
let yellow = CGColor(srgbRed: 1.0, green: 0.78, blue: 0.05, alpha: 1)
ctx.setStrokeColor(yellow)
ctx.setLineWidth(58)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)

let path = CGMutablePath()
// body: x 262...762, y 180...560 (in bottom-left coords)
path.move(to: CGPoint(x: 262, y: 180))
path.addLine(to: CGPoint(x: 262, y: 560))
// roof apex
path.addLine(to: CGPoint(x: 512, y: 800))
path.addLine(to: CGPoint(x: 762, y: 560))
path.addLine(to: CGPoint(x: 762, y: 180))
path.closeSubpath()
ctx.addPath(path)
ctx.strokePath()

// White "M" centered in the house body
let fontSize: CGFloat = 340
let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, fontSize, nil)
let attributes: [CFString: Any] = [
    kCTFontAttributeName: font,
    kCTForegroundColorAttributeName: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
]
let attributed = CFAttributedStringCreate(nil, "M" as CFString, attributes as CFDictionary)!
let line = CTLineCreateWithAttributedString(attributed)
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
ctx.textPosition = CGPoint(
    x: 512 - bounds.width / 2 - bounds.origin.x,
    y: 380 - bounds.height / 2 - bounds.origin.y
)
CTLineDraw(line, ctx)

let image = ctx.makeImage()!
let outputURL = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/icon-1024.png")
let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(outputURL.path)")
