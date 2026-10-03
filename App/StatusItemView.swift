//
//  StatusItemView.swift
//  Rendu de l'icône de la barre de menus
//

import AppKit

/// Vue compacte affichée dans la barre de menus.
///
/// On dessine des jauges plutôt que du texte : à 1-2 s de rafraîchissement,
/// des chiffres qui changent sans arrêt sont difficiles à lire, alors que
/// la longueur d'une barre se perçoit immédiatement.
///
/// Les jauges sont dessinées avec une piste **pleinement opaque** : une
/// piste semi-transparente devient gris sur gris dans une barre de menus
/// claire, et l'icône disparaît. Le contraste vient donc du trait, pas d'une
/// opacité faible.
final class StatusItemView: NSView {

    /// Identifiant de la jauge affichée, pour la couleur et l'ordre.
    enum Metric: CaseIterable {
        case cpu
        case gpu
        case memory
        case network
        case temperature
        case battery
    }

    var snapshot: Snapshot {
        didSet { needsDisplay = true }
    }

    /// Icône de batterie dessinée par le système (nil sur Mac de bureau).
    var batterySymbol: NSImage? {
        didSet { needsDisplay = true }
    }

    private let barWidth: CGFloat = 5
    private let barHeight: CGFloat = 10
    private let spacing: CGFloat = 3
    private let iconSize: CGFloat = 16

    private var metrics: [Metric] = [.cpu, .gpu, .memory, .network, .temperature, .battery]

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    init(snapshot: Snapshot) {
        self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: 60, height: 18))
        wantsLayer = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas supporté") }

    /// Génère la chaîne d'affichage du temps de batterie dans la barre de menus.
    ///
    /// Fonction : retourne le temps restant formaté, avec un indicateur d'éclair
    /// (⚡) si la batterie est en charge. Si aucun temps restant n'est disponible,
    /// retourne le niveau en pourcentage. Passe en rouge si < 20 % (via batteryTextColor).
    ///
    /// - Returns: Chaîne formatée pour l'affichage
    private func batteryTimeString() -> String {
        let b = snapshot.battery
        if let minutes = b.timeRemainingMinutes, minutes > 0 {
            return b.isCharging ? "⚡ \(Formatters.duration(minutes))" : Formatters.duration(minutes)
        }
        return "\(b.level) %"
    }

    /// Détermine la couleur du texte batterie dans la barre de menus.
    ///
    /// Fonction : applique la couleur rouge si le niveau est inférieur à 20 %,
    /// sinon utilise la couleur de piste adaptée à l'apparence (clair/sombre).
    ///
    /// - Returns: Couleur NSColor à utiliser
    private func batteryTextColor() -> NSColor {
        let b = snapshot.battery
        let fraction = Double(b.level) / 100
        if fraction < 0.20 {
            return .systemRed
        }
        return trackColor
    }

    override var intrinsicContentSize: NSSize {
        var width: CGFloat = 0
        let font = NSFont.systemFont(ofSize: 10)
        for metric in metrics {
            if metric == .battery {
                guard snapshot.battery.isPresent else { continue }
                let str = batteryTimeString()
                width += str.size(withAttributes: [.font: font]).width + spacing
                continue
            }
            width += barWidth + spacing
        }
        if width > 0 { width -= spacing }
        return NSSize(width: max(width, 22), height: iconSize)
    }

    // MARK: - Apparence

    /// `effectiveAppearance` de la vue plutôt que celle de l'application :
    /// c'est elle qui hérite réellement de l'apparence de la barre de menus,
    /// y compris lorsque l'utilisateur force un thème différent de celui du
    /// système. Interroger `NSApp` donnerait parfois la mauvaise valeur.
    private var isDarkMenuBar: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Couleur de la piste : noire sur barre claire, blanche sur barre sombre.
    private var trackColor: NSColor {
        isDarkMenuBar ? .white : .black
    }

    // MARK: - Dessin

    override func draw(_ dirtyRect: NSRect) {
        var x: CGFloat = 0
        let font = NSFont.systemFont(ofSize: 10)

        for metric in metrics {
            if metric == .battery {
                guard snapshot.battery.isPresent else { continue }
                let str = batteryTimeString()
                let color = batteryTextColor()
                let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                let size = str.size(withAttributes: attrs)
                let yText = (bounds.height - size.height) / 2
                str.draw(at: NSPoint(x: x, y: yText), withAttributes: attrs)
                x += size.width + spacing
                continue
            }

            let y = (bounds.height - barHeight) / 2
            let fraction = value(for: metric)
            drawGauge(at: NSPoint(x: x, y: y), fraction: fraction, tint: nil)
            x += barWidth + spacing
        }
    }

    /// Trace une jauge verticale remplie à `fraction` (0...1).
    private func drawGauge(at origin: NSPoint, fraction: Double, tint: NSColor? = nil) {
        let rect = NSRect(x: origin.x, y: origin.y, width: barWidth, height: barHeight)
        let clamped = max(0, min(1, fraction))
        let radius: CGFloat = barWidth / 2

        // Piste : contour opaque, 1 pt. C'est ce qui rend l'icône lisible
        // sur une barre claire — un remplissage gris pâle ne l'est pas.
        trackColor.setStroke()
        let track = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: radius, yRadius: radius)
        track.lineWidth = 1
        track.stroke()

        guard clamped > 0 else { return }
        let filled = NSRect(x: rect.minX,
                            y: rect.minY,
                            width: barWidth,
                            height: max(2, barHeight * clamped))
        (tint ?? GaugeColor.load(clamped)).setFill()
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }

    private func value(for metric: Metric) -> Double {
        switch metric {
        case .cpu:
            return snapshot.cpu.total / 100
        case .gpu:
            return Double(snapshot.gpu.deviceUtilization) / 100
        case .memory:
            return snapshot.memory.fraction
        case .network:
            // Échelle logarithmique, seuils nommés dans `NetworkUsage`.
            let bytesPerSecond = max(snapshot.network.downloadPerSecond,
                                     snapshot.network.uploadPerSecond)
            return NetworkUsage.loadFraction(bytesPerSecond: bytesPerSecond)
        case .temperature:
            // 30 °C à 100 °C : la plage utile sur ce genre de machine.
            guard let peak = snapshot.temperature.socPeak else { return 0 }
            return max(0, min(1, (peak - 30) / 70))
        case .battery:
            return Double(snapshot.battery.level) / 100
        }
    }
}
