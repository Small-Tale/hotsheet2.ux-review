#!/usr/bin/env swift
// Generates macos/App/Resources/Assets.xcassets/AppIcon.appiconset from a full-bleed, square
// 1024 px icon export (the Hot Sheet 2 design export `docs/design/exports/ux-review-icon.png`).
// Each size is the artwork clipped to the macOS app icon shape (a rounded square, 824 of 1024 pt
// with a 185.4 pt corner radius) on a transparent canvas with the standard drop shadow, so the
// icon sits on the same grid as system icons.
//
// Usage: scripts/make-app-icon.swift <source-1024.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 2, let source = NSImage(contentsOfFile: args[1]),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("usage: make-app-icon.swift <source-1024.png>\n".utf8))
    exit(1)
}

let scriptDir = URL(fileURLWithPath: args[0]).deletingLastPathComponent()
let setDir = scriptDir.appendingPathComponent("../macos/App/Resources/Assets.xcassets/AppIcon.appiconset")
    .standardizedFileURL
try? FileManager.default.removeItem(at: setDir)
try FileManager.default.createDirectory(at: setDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let scale = CGFloat(pixels) / 1024
    let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    let body = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let shape = CGPath(roundedRect: body, cornerWidth: 185.4 * scale, cornerHeight: 185.4 * scale, transform: nil)
    // Shadow: 28 pt blur, 12 pt down, 30% black (Apple's macOS icon template).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -12 * scale),
        blur: 28 * scale,
        color: CGColor(gray: 0, alpha: 0.3)
    )
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(sourceCG, in: body)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: setDir.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: setDir.appendingPathComponent("Contents.json"))
print("Wrote \(setDir.path)")
