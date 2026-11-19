// Renders the app icon (1024×1024 PNG) with SwiftUI.
// Usage: swift scripts/make-icon.swift <out.png>   (scripts/make-icon.sh turns it into AppIcon.icns)
//
// Layout follows Apple's macOS icon grid: an 824 pt continuous-corner squircle centred on a
// 1024 canvas, so Tahoe recognises the shape and doesn't put the icon on a grey plate.
import AppKit
import SwiftUI

let accentStart = Color(red: 1.00, green: 0.28, blue: 0.38)
let accentEnd = Color(red: 0.98, green: 0.55, blue: 0.22)

// Iconsax "DocumentDownload" (TwoTone), same glyph as the in-app header, drawn white.
// The arrow keeps the two-tone look but at 0.7 opacity so it stays readable at 16 px.
let glyphSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
<g opacity=".7" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 11v6l2-2M9 17l-2-2"/></g>
<path d="M22 10v5c0 5-2 7-7 7H9c-5 0-7-2-7-7V9c0-5 2-7 7-7h5" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
<path d="M22 10h-4c-3 0-4-1-4-4V2l8 8Z" stroke="#fff" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""

struct AppIcon: View {
    let glyph: NSImage

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            shape
                .fill(LinearGradient(colors: [accentStart, accentEnd], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear],
                                                   startPoint: .top, endPoint: .center)))
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 3))
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
            Image(nsImage: glyph)
                .resizable()
                .interpolation(.high)
                .frame(width: 500, height: 500)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
        }
        .frame(width: 824, height: 824)
        .frame(width: 1024, height: 1024)
    }
}

@MainActor
func render(to path: String) {
    guard let svg = NSImage(data: Data(glyphSVG.utf8)) else { fatalError("bad SVG") }
    // Rasterise the vector at full size; SwiftUI would otherwise scale up a 24 px bitmap.
    let glyph = NSImage(size: NSSize(width: 500, height: 500), flipped: false) { rect in
        svg.draw(in: rect)
        return true
    }
    let renderer = ImageRenderer(content: AppIcon(glyph: glyph))
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

MainActor.assumeIsolated { render(to: CommandLine.arguments[1]) }
