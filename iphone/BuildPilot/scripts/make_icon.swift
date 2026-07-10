// Generates the Build Pilot app icon (1024x1024 PNG).
// Run from iphone/BuildPilot:  swift scripts/make_icon.swift
// Design: three green paint strokes on a near-black field — calm, minimal,
// recognisable at every size.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let context = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!

// Background
context.setFillColor(CGColor(srgbRed: 0.078, green: 0.090, blue: 0.082, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

// Paint strokes (rounded-cap horizontal bars, top-aligned like brush swipes)
let green = (r: 0.188, g: 0.820, b: 0.345)
let strokes: [(y: CGFloat, width: CGFloat, alpha: CGFloat)] = [
    (y: 660, width: 560, alpha: 1.00),
    (y: 512, width: 430, alpha: 0.75),
    (y: 364, width: 300, alpha: 0.50),
]
let barHeight: CGFloat = 104
let originX: CGFloat = 232

for stroke in strokes {
    context.setFillColor(CGColor(
        srgbRed: green.r, green: green.g, blue: green.b, alpha: stroke.alpha
    ))
    let rect = CGRect(
        x: originX, y: stroke.y - barHeight / 2,
        width: stroke.width, height: barHeight
    )
    let path = CGPath(roundedRect: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2, transform: nil)
    context.addPath(path)
    context.fillPath()
}

let image = context.makeImage()!
let outputURL = URL(fileURLWithPath: "Assets.xcassets/AppIcon.appiconset/icon-1024.png")
try? FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true
)
let destination = CGImageDestinationCreateWithURL(
    outputURL as CFURL, UTType.png.identifier as CFString, 1, nil
)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("Wrote \(outputURL.path)")
