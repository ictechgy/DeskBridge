// SPDX-License-Identifier: GPL-3.0-only
// Source geometry for Knot's interwoven-loop mark. No app, UI or user data is opened.
import Foundation
import CoreGraphics
import ImageIO

guard CommandLine.arguments.count == 2 else { fatalError("Expected an output directory") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let size = 1024
let ink = CGColor(srgbRed: 20 / 255, green: 32 / 255, blue: 43 / 255, alpha: 1)
let ivory = CGColor(srgbRed: 243 / 255, green: 241 / 255, blue: 232 / 255, alpha: 1)
let teal = CGColor(srgbRed: 42 / 255, green: 157 / 255, blue: 154 / 255, alpha: 1)
let ribbon: CGFloat = 96
let clearance: CGFloat = 160
let angle: CGFloat = 40
let capsule = CGRect(x: 232, y: 390, width: 560, height: 244)
let overpassClips = [CGRect(x: 310, y: 300, width: 200, height: 180),
                     CGRect(x: 514, y: 544, width: 200, height: 180)]

func transform(_ degrees: CGFloat) -> CGAffineTransform {
    CGAffineTransform(translationX: 512, y: 512)
        .rotated(by: degrees * .pi / 180).translatedBy(x: -512, y: -512)
}
func loop(_ degrees: CGFloat) -> CGPath {
    var rotation = transform(degrees)
    return CGPath(roundedRect: capsule, cornerWidth: 122, cornerHeight: 122, transform: &rotation)
}
let overpasses = CGMutablePath()
for rectangle in overpassClips { overpasses.addRect(rectangle, transform: transform(angle)) }
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("Could not create the icon canvas")
}
context.translateBy(x: 0, y: CGFloat(size))
context.scaleBy(x: 1, y: -1)
context.setFillColor(ink)
context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                       cornerWidth: 224, cornerHeight: 224, transform: nil))
context.fillPath()
context.setLineCap(.round)
context.setLineJoin(.round)
func stroke(_ path: CGPath, _ color: CGColor, _ width: CGFloat) {
    context.setStrokeColor(color)
    context.setLineWidth(width)
    context.addPath(path)
    context.strokePath()
}
// Cut each ribbon only where the other passes over it. Isolated layers keep
// the tile intact and avoid antialiased seams from painting over a ribbon twice.
context.beginTransparencyLayer(auxiliaryInfo: nil)
stroke(loop(angle), ivory, ribbon)
context.saveGState()
context.addRect(CGRect(x: 0, y: 0, width: size, height: size))
context.addPath(overpasses)
context.clip(using: .evenOdd)
context.setBlendMode(.clear)
stroke(loop(-angle), ink, clearance)
context.restoreGState()
context.endTransparencyLayer()
context.beginTransparencyLayer(auxiliaryInfo: nil)
stroke(loop(-angle), teal, ribbon)
context.saveGState()
context.addPath(overpasses)
context.clip()
context.setBlendMode(.clear)
stroke(loop(angle), ink, clearance)
context.restoreGState()
context.endTransparencyLayer()
guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent("knot.png") as CFURL,
                                                        "public.png" as CFString, 1, nil) else {
    fatalError("Could not create the PNG destination")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write the PNG") }
let clipRects = overpassClips.map {
    "<rect x=\"\(Int($0.origin.x))\" y=\"\(Int($0.origin.y))\" width=\"\(Int($0.width))\" height=\"\(Int($0.height))\" transform=\"rotate(40 512 512)\"/>"
}.joined(separator: "\n      ")
let rect = "x=\"232\" y=\"390\" width=\"560\" height=\"244\" rx=\"122\""
let svg = """
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title description">
  <title id="title">Knot</title>
  <desc id="description">Two interwoven ivory and teal loops on a deep ink rounded tile.</desc>
  <defs>
    <clipPath id="overpasses" clipPathUnits="userSpaceOnUse">
      \(clipRects)
    </clipPath>
    <mask id="ivory" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <rect width="1024" height="1024" fill="white"/>
      <rect \(rect) transform="rotate(-40 512 512)" fill="none" stroke="black" stroke-width="160"/>
      <g fill="white">\(clipRects)</g>
    </mask>
    <mask id="teal" maskUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">
      <rect width="1024" height="1024" fill="white"/>
      <rect \(rect) transform="rotate(40 512 512)" fill="none" stroke="black" stroke-width="160" clip-path="url(#overpasses)"/>
    </mask>
  </defs>
  <rect width="1024" height="1024" rx="224" fill="#14202b"/>
  <g fill="none" stroke-linecap="round" stroke-linejoin="round" stroke-width="96">
    <rect \(rect) transform="rotate(40 512 512)" stroke="#f3f1e8" mask="url(#ivory)"/>
    <rect \(rect) transform="rotate(-40 512 512)" stroke="#2a9d9a" mask="url(#teal)"/>
  </g>
</svg>

"""
try svg.write(to: output.appendingPathComponent("knot.svg"), atomically: true, encoding: .utf8)
