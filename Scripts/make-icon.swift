#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns.
//
// The icon is drawn in code rather than checked in as a pile of PNGs so it can
// be re-rendered at any size, and so the two colours stay in one place with the
// menu bar's: green down arrow (#51FF70), light up arrow (#E5E5E5), matching
// MenuBarTitle.
//
// Run:  swift Scripts/make-icon.swift
// The .icns it writes is committed, so a normal build never needs this script.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Palette

// Same values as the menu bar readout.
let downColor = CGColor(red: 0x51 / 255, green: 0xFF / 255, blue: 0x70 / 255, alpha: 1)
let upColor = CGColor(red: 0xE5 / 255, green: 0xE5 / 255, blue: 0xE5 / 255, alpha: 1)
// Near-black, a touch warm, so the green stays the only saturated thing.
let backgroundTop = CGColor(red: 0.19, green: 0.19, blue: 0.20, alpha: 1)
let backgroundBottom = CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)

// MARK: - Geometry
//
// All coordinates are on a 1024 grid and scaled at draw time. macOS icons leave
// a margin around the shape: the body is 824pt of the 1024pt canvas.

let canvas: CGFloat = 1024
let bodyInset: CGFloat = 100

/// Apple's icon shape is a squircle, not a circular-cornered rect. A
/// superellipse matches it closely; n ≈ 6.2 lands on the same corner tightness
/// as the 185pt radius Apple uses on an 824pt body.
func squirclePath(in rect: CGRect, n: CGFloat = 6.2, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let exponent = 2 / n
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), exponent)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), exponent)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A blunt arrow: rectangular stem sitting on a full-width triangular head.
/// `pointingDown` flips it about the vertical centre of `rect`.
func arrowPath(in rect: CGRect, pointingDown: Bool) -> CGPath {
    let headHeight = rect.height * 0.42
    let stemWidth = rect.width * 0.40
    let stemX = rect.midX - stemWidth / 2

    let path = CGMutablePath()
    if pointingDown {
        // Tip at the bottom edge.
        path.addRect(CGRect(x: stemX, y: rect.minY + headHeight,
                            width: stemWidth, height: rect.height - headHeight))
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + headHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + headHeight))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
    } else {
        // Tip at the top edge.
        path.addRect(CGRect(x: stemX, y: rect.minY,
                            width: stemWidth, height: rect.height - headHeight))
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - headHeight))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - headHeight))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    }
    path.closeSubpath()
    return path
}

// MARK: - Drawing

func drawIcon(in ctx: CGContext, pixelSize: CGFloat) {
    let scale = pixelSize / canvas
    ctx.scaleBy(x: scale, y: scale)
    ctx.setShouldAntialias(true)

    let body = CGRect(x: bodyInset, y: bodyInset,
                      width: canvas - bodyInset * 2, height: canvas - bodyInset * 2)
    let shape = squirclePath(in: body)

    // Background: a slight top-to-bottom lift, the way macOS icons are lit.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    if let gradient = CGGradient(colorsSpace: space,
                                 colors: [backgroundTop, backgroundBottom] as CFArray,
                                 locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: body.maxY),
                               end: CGPoint(x: 0, y: body.minY),
                               options: [])
    }
    ctx.restoreGState()

    // Arrows, side by side rather than stacked: at 16pt a stacked pair collapses
    // into a smudge, while two half-width arrows stay readable.
    let arrowHeight: CGFloat = 420
    let arrowWidth: CGFloat = 180
    let centerOffset: CGFloat = 135
    let arrowY = (canvas - arrowHeight) / 2

    let down = CGRect(x: canvas / 2 - centerOffset - arrowWidth / 2, y: arrowY,
                      width: arrowWidth, height: arrowHeight)
    let up = CGRect(x: canvas / 2 + centerOffset - arrowWidth / 2, y: arrowY,
                    width: arrowWidth, height: arrowHeight)

    ctx.setFillColor(downColor)
    ctx.addPath(arrowPath(in: down, pointingDown: true))
    ctx.fillPath()

    ctx.setFillColor(upColor)
    ctx.addPath(arrowPath(in: up, pointingDown: false))
    ctx.fillPath()
}

func renderPNG(pixelSize: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(pixelSize)px context")
    }
    drawIcon(in: ctx, pixelSize: CGFloat(pixelSize))
    guard let image = ctx.makeImage() else { throw Failure("could not snapshot the context") }
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("could not write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("could not finalize \(url.path)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Main

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
let output = root.appendingPathComponent("Resources/AppIcon.icns")

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

    // The set iconutil expects.
    for base in [16, 32, 128, 256, 512] {
        try renderPNG(pixelSize: base, to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        try renderPNG(pixelSize: base * 2, to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try iconutil.run()
    iconutil.waitUntilExit()
    guard iconutil.terminationStatus == 0 else { throw Failure("iconutil failed") }

    print("==> Wrote \(output.path)")
} catch {
    FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
