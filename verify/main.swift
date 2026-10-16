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
    s.battery.isPlugged = true
    s.battery.isPresent = true
    s.battery.timeRemainingMinutes = 27
    s.battery.health = 99
    s.battery.cycles = 77
    s.battery.maxCapacityMah = 4563
    s.battery.designCapacityMah = 4629
    s.battery.voltage = 12.2
    s.battery.amperage = -376
    s.battery.adapterWatts = 96
    s.battery.adapterVoltage = 20.15
    s.temperature.socPeak = 68.4
    s.temperature.socAverage = 61.2
    s.temperature.dieCount = 24
    s.processes = [
        ProcessUsage(name: "Google Chrome", pid: 4021, cpu: 142.7, memory: 4.2e9),
        ProcessUsage(name: "Google Chrome Helper (Renderer)", pid: 4118, cpu: 63.1, memory: 1.8e9),
        ProcessUsage(name: "WindowServer", pid: 218, cpu: 41.5, memory: 980e6),
        ProcessUsage(name: "kernel_task", pid: 0, cpu: 28.9, memory: 0),
        ProcessUsage(name: "WindowServerHelperNomTresLong", pid: 9087, cpu: 9.8, memory: 220e6)
    ]
    s.bluetooth = [
        BluetoothDevice(name: "AirPods de Yves", components: [
            BluetoothComponent(kind: "left", level: 100),
            BluetoothComponent(kind: "right", level: 100),
            BluetoothComponent(kind: "case", level: 43)
        ]),
        BluetoothDevice(name: "Magic Mouse", components: [
            BluetoothComponent(kind: "battery", level: 85)
        ])
    ]
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
    // `cacheDisplay` laisse AppKit configurer le contexte selon `isFlipped` :
    // le rendu manuel dans un contexte bitmap (ancienne version) inversait
    // verticalement les vues retournées, donc toutes les captures sortaient
    // à l'envers. L'apparence claire forcée plus haut reste prise en compte.
    view.cacheDisplay(in: view.bounds, to: rep)
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
status.frame = NSRect(origin: .zero, size: status.intrinsicContentSize)

/// Bande de barre de menus : fond gris (clair/sombre) et trait de séparation
/// en bas, comme sous la barre réelle. Sert de conteneur pour `cacheDisplay`,
/// qui gère lui-même l'orientation selon `isFlipped`.
final class MenuBarStrip: NSView {
    var barColor: NSColor = .white
    var hairlineColor: NSColor = .gray
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        barColor.setFill()
        NSBezierPath(rect: bounds).fill()
        hairlineColor.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: bounds.width, height: 0.5)).fill()
    }
}

func renderOnMenuBar(_ view: NSView, dark: Bool, to path: String) {
    let statusSize = view.bounds.size
    // Bande de barre de menus avec la même hauteur que l'item réel.
    let strip = NSSize(width: statusSize.width + 40, height: 24)

    let container = MenuBarStrip(frame: NSRect(origin: .zero, size: strip))
    // Fond de barre : gris clair / gris sombre, comme sur macOS.
    container.barColor = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.94, alpha: 1)
    // Séparation basse, comme le trait sous la barre de menus.
    container.hairlineColor = dark ? NSColor(white: 0.32, alpha: 1) : NSColor(white: 0.78, alpha: 1)

    // La vue choisit noir ou blanc via `effectiveAppearance` : on fixe donc
    // l'apparence du conteneur, héritée par l'icône, sinon les deux aperçus
    // seraient identiques.
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
    container.appearance = appearance

    // La vue est centrée verticalement dans la bande.
    view.frame = NSRect(x: 20,
                        y: (strip.height - statusSize.height) / 2,
                        width: statusSize.width,
                        height: statusSize.height)
    container.addSubview(view)
    container.layoutSubtreeIfNeeded()

    appearance.performAsCurrentDrawingAppearance {
        render(container, to: path, scale: 3)
    }
}

renderOnMenuBar(status, dark: false, to: "verify/menubar-clair.png")
renderOnMenuBar(status, dark: true, to: "verify/menubar-sombre.png")
