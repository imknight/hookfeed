#!/usr/bin/env swift
import AppKit
import Foundation

// Native, offline icon generation. Output is consumed by Apple's iconutil.
guard CommandLine.arguments.count == 2 else {
    fputs("Usage: make-icon.swift OUTPUT.iconset\n", stderr)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// UI spec green #1A7431, with the near-black tile from the welcome mockup.
let iconGreen = NSColor(srgbRed: 26.0 / 255, green: 116.0 / 255, blue: 49.0 / 255, alpha: 1)
let iconBackground = NSColor(srgbRed: 15.0 / 255, green: 20.0 / 255, blue: 16.0 / 255, alpha: 1)

func png(size: Int) throws -> Data {
    let canvas = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
        let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844), xRadius: 190, yRadius: 190)
        iconBackground.setFill()
        tile.fill()

        let tray = NSBezierPath()
        tray.move(to: NSPoint(x: 352, y: 650))
        tray.line(to: NSPoint(x: 672, y: 650))
        tray.line(to: NSPoint(x: 704, y: 500))
        tray.line(to: NSPoint(x: 704, y: 392))
        tray.curve(to: NSPoint(x: 688, y: 376), controlPoint1: NSPoint(x: 704, y: 383), controlPoint2: NSPoint(x: 697, y: 376))
        tray.line(to: NSPoint(x: 336, y: 376))
        tray.curve(to: NSPoint(x: 320, y: 392), controlPoint1: NSPoint(x: 327, y: 376), controlPoint2: NSPoint(x: 320, y: 383))
        tray.line(to: NSPoint(x: 320, y: 500))
        tray.close()

        tray.move(to: NSPoint(x: 320, y: 500))
        tray.line(to: NSPoint(x: 430, y: 500))
        tray.line(to: NSPoint(x: 464, y: 454))
        tray.line(to: NSPoint(x: 560, y: 454))
        tray.line(to: NSPoint(x: 594, y: 500))
        tray.line(to: NSPoint(x: 704, y: 500))
        // Preserve the outline at Finder's smallest icon sizes.
        tray.lineWidth = size <= 32 ? 42 : 30
        tray.lineJoinStyle = .round
        tray.lineCapStyle = .round
        iconGreen.setStroke()
        tray.stroke()
        return true
    }
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    canvas.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return data
}

for pointSize in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let filename = "icon_\(pointSize)x\(pointSize)\(suffix).png"
        try png(size: pointSize * scale).write(to: output.appendingPathComponent(filename))
    }
}
