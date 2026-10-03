import AppKit

// Hors application, `effectiveAppearance` n'est pas résolu et toutes les
// couleurs sémantiques (windowBackgroundColor, labelColor…) tombent en noir :
// le rendu devient illisible. On force donc l'apparence claire.
NSApplication.shared.appearance = NSAppearance(named: .aqua)

// Rend LES VRAIES classes de l'app (StatusItemView, PopupView) hors écran.
// Le contrôle précédent recopiait le code de dessin à la main : il pouvait
// diverger de l'implémentation réelle. Ici on importe les sources de l'app.

let snapshot = { () -> Snapshot in
    var s = Snapshot()
    s.cpu.total = 87
    s.cpu.perCore = [99, 96, 92, 88, 85, 90, 97, 81, 78, 84]
    s.gpu.deviceUtilization = 94
    s.gpu.rendererUtilization = 96
    s.gpu.model = "Apple M5"
    s.gpu.coreCount = 10
    s.gpu.inUseMemory = 1.8e9
    s.memory.used = 20.1e9
    s.memory.total = 25.8e9
    s.memory.compressed = 2.4e9
    s.memory.wired = 6.1e9
    s.network.downloadPerSecond = 12.4e6
    s.network.uploadPerSecond = 1.1e6
    s.network.activeInterface = "en0"
    s.battery.level = 34
    s.battery.isCharging = true
    s.battery.isPresent = true
    s.battery.timeRemainingMinutes = 27
    s.temperature.socPeak = 68.4
    s.temperature.socAverage = 61.2
    s.temperature.dieCount = 24
    s.date = Date()
    return s
}()

func render<V: NSView>(_ view: V, to path: String, scale: CGFloat = 2) {
    view.layoutSubtreeIfNeeded()
    let size = view.bounds.size
    guard size.width > 0, size.height > 0 else {
        print("✗ \(path) : taille nulle \(size)"); return
    }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size.width * scale),
                                     pixelsHigh: Int(size.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else {
        print("✗ \(path) : alloc rep"); return
    }
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)
    // Hors application, l'apparence système n'est pas résolue : on force le
    // mode clair, sinon tout sort noir et la mise en page est illisible.
    NSAppearance.currentDrawing().performAsCurrentDrawingAppearance {
        view.draw(view.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("✓ \(path)  \(Int(size.width))×\(Int(size.height))")
    }
}

// --- Panneau détaillé ---
let popup = PopupView(snapshot: snapshot, coreCount: 10)
popup.frame = NSRect(origin: .zero, size: popup.frame.size)
render(popup, to: "verify/panel.png")

// --- Jauge de la barre de menus, posée sur un fond de barre réel ---
//
// Rendu seul, l'icône est sans contexte : le défaut qui rendait l'ancienne
// version invisible (piste grise sur fond clair) ne se voyait pas. On la
// composite donc sur les deux fonds possibles — barre claire et barre sombre.
let status = StatusItemView(snapshot: snapshot)
status.batterySymbol = NSImage(systemSymbolName: "battery.25", accessibilityDescription: nil)
status.frame = NSRect(origin: .zero, size: status.intrinsicContentSize)

func renderOnMenuBar(_ view: NSView, dark: Bool, to path: String) {
    let scale: CGFloat = 3
    let size = view.bounds.size
    // Bande de barre de menus avec la même hauteur que l'item réel.
    let strip = NSSize(width: size.width + 40, height: 24)

    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(strip.width * scale),
                                     pixelsHigh: Int(strip.height * scale),
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = strip
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.cgContext.scaleBy(x: scale, y: scale)

    // Fond de barre : gris clair / gris sombre, comme sur macOS.
    (dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(origin: .zero, size: strip)).fill()
    // Séparation basse, comme le trait sous la barre de menus.
    (dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.78, alpha: 1)).setFill()
    NSBezierPath(rect: NSRect(x: 0, y: 0, width: strip.width, height: 0.5)).fill()

    // La vue choisit noir ou blanc via `effectiveAppearance` : il faut
    // encadrer le dessin avec l'apparence voulue, sinon les deux aperçus
    // seraient identiques.
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    appearance.performAsCurrentDrawingAppearance {
        view.draw(view.bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("✓ \(path)  \(Int(strip.width))×\(Int(strip.height))")
    }
}

// La vue est centrée verticalement dans la bande.
let savedFrame = status.frame
status.frame = NSRect(x: 20,
                      y: (24 - savedFrame.height) / 2,
                      width: savedFrame.width,
                      height: savedFrame.height)

renderOnMenuBar(status, dark: false, to: "verify/menubar-clair.png")
renderOnMenuBar(status, dark: true, to: "verify/menubar-sombre.png")
status.frame = savedFrame
