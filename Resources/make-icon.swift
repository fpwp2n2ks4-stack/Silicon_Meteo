#!/usr/bin/env swift
//
//  make-icon.swift
//  Génère l'icône de l'application (Toasty.icns) à partir de toaster.svg.
//
//  Outil de développement, hors build : `build.sh` se contente de copier le
//  `.icns` versionné. À relancer uniquement quand le SVG change :
//
//      ./Resources/make-icon.swift
//
//  Aucune dépendance externe : AppKit lit le SVG nativement (NSImage), on
//  compose la tuile macOS (carré arrondi + marges) puis `iconutil` emballe le
//  jeu de PNG en `.icns`. Pas de rsvg-convert, pas d'ImageMagick.
//

import AppKit

// MARK: - Paramètres de rendu (à ajuster librement)

/// Côté du canevas de référence. Toutes les géométries sont exprimées dans cet
/// espace, puis mises à l'échelle pour chaque taille du `.iconset`.
let canvas: CGFloat = 1024

/// Côté du corps de la tuile : la convention macOS laisse ~10 % de marge de
/// chaque côté (824 sur 1024) entre le bord du canevas et le carré arrondi.
let bodySide: CGFloat = 824

/// Rayon des coins du corps. ~22,5 % du côté, proche du rayon des icônes système.
let cornerRadius: CGFloat = 185

/// Part du corps occupée par le glyphe, centrée. 0,60 laisse des marges
/// confortables ; augmenter pour un glyphe plus grand.
let glyphRatio: CGFloat = 0.60

/// Fond de la tuile : blanc cassé neutre (#F5F5F7).
let background = NSColor(srgbRed: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)

// MARK: - Entrées du .iconset (nom, côté en pixels)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// MARK: - Chemins

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let svgURL = scriptDir.appendingPathComponent("toaster.svg")
let icnsURL = scriptDir.appendingPathComponent("Toasty.icns")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("erreur : " + message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - Chargement du glyphe

guard FileManager.default.fileExists(atPath: svgURL.path) else {
    fail("\(svgURL.path) introuvable")
}
guard let glyph = NSImage(contentsOf: svgURL) else {
    fail("impossible de charger \(svgURL.lastPathComponent)")
}

// MARK: - Composition

/// Rend une tuile complète (fond arrondi + glyphe) à `px` pixels de côté.
func renderTile(px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true

    // De l'espace de référence (canvas) vers la taille réelle.
    let scale = CGFloat(px) / canvas
    ctx.cgContext.scaleBy(x: scale, y: scale)

    let bodyOrigin = (canvas - bodySide) / 2
    let bodyRect = NSRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide)

    background.setFill()
    NSBezierPath(roundedRect: bodyRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()

    // Glyphe centré, à l'échelle demandée. Le SVG est carré : on remplit la
    // boîte sans déformation.
    let glyphSide = bodySide * glyphRatio
    let glyphOrigin = (canvas - glyphSide) / 2
    let glyphRect = NSRect(x: glyphOrigin, y: glyphOrigin, width: glyphSide, height: glyphSide)
    glyph.draw(in: glyphRect,
               from: .zero,
               operation: .sourceOver,
               fraction: 1,
               respectFlipped: true,
               hints: [.interpolation: NSImageInterpolation.high.rawValue])

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - Écriture du .iconset

let fm = FileManager.default
let iconsetURL = fm.temporaryDirectory
    .appendingPathComponent("Toasty-\(UUID().uuidString).iconset")
try? fm.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconsetURL) }

for entry in entries {
    guard let data = renderTile(px: entry.px) else {
        fail("rendu impossible pour \(entry.name)")
    }
    try! data.write(to: iconsetURL.appendingPathComponent(entry.name))
    print("  \(entry.name)  (\(entry.px)×\(entry.px))")
}

// MARK: - Emballage en .icns

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try! iconutil.run()
iconutil.waitUntilExit()

guard iconutil.terminationStatus == 0 else {
    fail("iconutil a échoué (code \(iconutil.terminationStatus))")
}

print("✓ \(icnsURL.path)")
