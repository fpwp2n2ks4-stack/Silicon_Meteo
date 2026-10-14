//
//  PopupView.swift
//  Panneau détaillé affiché au clic sur l'icône de la barre de menus
//

import AppKit

/// Panneau de détail affiché sous la barre de menus.
///
/// Panneau de lecture, à une exception près : une ligne de la liste des
/// processus révèle un bouton × au survol, qui demande la terminaison du
/// processus à `AppDelegate`. Tout le reste est en lecture seule, et seuls
/// « Quitter » et le rafraîchissement sont accessibles au clavier.
final class PopupView: NSView {

    var snapshot: Snapshot {
        didSet {
            // Le nombre de cœurs est fixe, mais la présence de batterie peut
            // varier (branchement/débranchement) : on retaille si besoin.
            let wanted = requiredHeight
            if abs(wanted - frame.height) > 1 {
                frame.size.height = wanted
                popover?.contentSize = NSSize(width: frame.width, height: wanted)
            }
            needsDisplay = true
        }
    }

    /// Renseignée par `AppDelegate` : nécessaire pour redimensionner le popover.
    weak var popover: NSPopover?

    /// Appelée lorsqu'un clic tombe sur le bouton × d'une ligne de processus.
    /// Renseignée par `AppDelegate`, qui se charge de la terminaison effective.
    var onQuitProcess: ((ProcessUsage) -> Void)?

    /// Zone cliquable d'une ligne : sa géométrie est calculée au dessin, donc
    /// mémorisée ici pour le test de survol et de clic.
    private struct ProcessRow {
        let process: ProcessUsage
        let rowRect: NSRect
        let killRect: NSRect
        let killable: Bool
    }

    /// Rempli à chaque `draw`, lu par `mouseMoved`/`mouseDown`.
    private var processRows: [ProcessRow] = []
    /// Indice de la ligne survolée, ou `nil`. Piloté uniquement par la souris.
    private var hoveredIndex: Int?

    /// Largeur réservée, au bord droit, au bouton × de terminaison. La colonne
    /// mémoire se décale d'autant pour que rien ne bouge à l'apparition du ×.
    private let killColumnWidth: CGFloat = 18

    private let coreCount: Int
    private let padding: CGFloat = 14
    private let rowHeight: CGFloat = 19
    private let lineWidth: CGFloat = 150
    /// Écart entre la fin du texte de valeur et le début de la jauge.
    private let valueGap: CGFloat = 42

    /// Lignes réservées à la liste des processus.
    ///
    /// Hauteur **fixe** : le nombre de processus lisibles varie d'un tick à
    /// l'autre (un process quitte la liste, un autre y entre), et caler la
    /// hauteur sur ce nombre ferait sauter le panneau à chaque rafraîchissement.
    private static let processRowCount = 10
    private static let processRowHeight: CGFloat = 13
    /// Largeur maximale du nom d'un processus : au-delà, il est tronqué pour
    /// ne pas empiéter sur la colonne du pourcentage.
    private let processNameWidth: CGFloat = 140

    /// Largeur du panneau : marge gauche, deux colonnes, l'écart des valeurs,
    /// puis la même marge qu'à gauche.
    ///
    /// La marge droite doit valoir la marge gauche. La jauge est dessinée
    /// jusqu'à `padding + lineWidth + valueGap + lineWidth`, soit 356 pt : avec
    /// un cadre plus étroit elle dépasse le bord et se fait rogner.
    private var panelWidth: CGFloat {
        padding + lineWidth * 2 + valueGap + padding
    }

    init(snapshot: Snapshot, coreCount: Int) {
        self.snapshot = snapshot
        self.coreCount = coreCount
        // `requiredHeight` lit `snapshot` : il faut initialiser avant `super.init`,
        // ce que Swift interdit. On passe donc par une variable locale.
        let height = Self.height(for: snapshot, padding: 14, rowHeight: 19)
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: height))
        // `panelWidth` lit des constantes d'instance, ce que Swift interdit
        // avant `super.init` : la largeur est donc appliquée juste après.
        frame.size.width = panelWidth
        wantsLayer = true
    }

    /// Hauteur nécessaire au contenu courant.
    ///
    /// Elle dépend du nombre de cœurs (une ligne par cœur) et de la présence
    /// d'une batterie, donc elle est calculée et non fixée à l'initialisation :
    /// un cadre trop court couperait le pied de page.
    private var requiredHeight: CGFloat {
        Self.height(for: snapshot, padding: padding, rowHeight: rowHeight)
    }

    /// Calcule la hauteur totale nécessaire au panneau en fonction du contenu.
    ///
    /// Fonction : détermine la hauteur requise en additionnant les hauteurs
    /// de chaque section (en-tête, CPU, GPU, mémoire, réseau, température,
    /// batterie, pied de page). Prend en compte le nombre de cœurs, la présence
    /// de mémoire GPU, d'interface réseau, de capteurs température et de batterie.
    ///
    /// - Parameters:
    ///   - snapshot: Données système à afficher
    ///   - padding: Marge extérieure du panneau
    ///   - rowHeight: Hauteur de base d'une ligne
    /// - Returns: Hauteur totale requise en points
    private static func height(for snapshot: Snapshot, padding: CGFloat, rowHeight: CGFloat) -> CGFloat {
        var height = padding * 2
        height += rowHeight * 2 + 4      // en-tête : modèle + heure
        height += 8                       // séparateur
        height += rowHeight + 4           // CPU
        height += CGFloat(snapshot.cpu.perCore.count) * 13 + 5
        height += 8                       // séparateur fin CPU
        height += 13                      // titre « Top processes »
        height += CGFloat(Self.processRowCount) * Self.processRowHeight
        height += 5                       // espace sous les processus
        height += 8                       // séparateur avant GPU
        height += rowHeight               // GPU
        if snapshot.gpu.inUseMemory > 0 { height += rowHeight - 4 }
        height += 8
        height += rowHeight * 3           // mémoire : jauge + 2 détails
        height += 8
        height += rowHeight * 2           // réseau ↓ ↑
        if snapshot.network.activeInterface != nil { height += rowHeight - 4 }
        height += 8
        if snapshot.temperature.dieCount > 0 { height += rowHeight * 2 - 3 }
        if snapshot.battery.isPresent { height += 8 + rowHeight }
        height += 8
        height += 12                     // pied de page
        return height
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) n'est pas supporté") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    // MARK: - Survol et terminaison

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Sans ce drapeau, la fenêtre ne relaie pas `mouseMoved` : aucun survol.
        window?.acceptsMouseMovedEvents = true
    }

    /// Réinstalle la zone de suivi à chaque changement de géométrie.
    ///
    /// `NSTrackingArea` est recalculée par AppKit à chaque `draw`, mais on la
    /// pose dans `bounds` : `.inVisibleRect` la suit automatiquement quand le
    /// panneau se redimensionne (batterie branchée/débranchée).
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = processRows.firstIndex { $0.rowRect.contains(point) }
        if index != hoveredIndex {
            hoveredIndex = index
            needsDisplay = true
        }
        refreshCursor(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredIndex != nil {
            hoveredIndex = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        // Seule la zone du × déclenche la terminaison : cliquer ailleurs sur la
        // ligne ne fait rien, pour ne pas tuer un processus par mégarde.
        guard let row = processRows.first(where: {
            $0.killable && $0.killRect.contains(point)
        }) else {
            super.mouseDown(with: event)
            return
        }
        onQuitProcess?(row.process)
    }

    /// Curseur main au-dessus du ×, flèche partout ailleurs.
    private func refreshCursor(at point: NSPoint) {
        let overKill = processRows.contains { $0.killable && $0.killRect.contains(point) }
        (overKill ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private func textColor(_ appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white
            : NSColor.labelColor
    }

    private func secondaryColor(_ appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.55)
            : NSColor.secondaryLabelColor
    }

    // 127 lignes, mais une suite de sections explicitement délimitées
    // (`// ---- CPU ----`, `// ---- Mémoire ----`…). Chacune est courte ;
    // c'est de la structure lisible, pas de la complexité. Découper
    // obligerait à faire circuler le curseur `y` entre des fonctions sans
    // rien simplifier.
    override func draw(_ dirtyRect: NSRect) {
        let appearance: NSAppearance = NSApp?.effectiveAppearance ?? .currentDrawing()
        let primary = textColor(appearance)
        let secondary = secondaryColor(appearance)

        // Fond translucide, comme les panneaux système.
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        border.lineWidth = 1
        border.stroke()

        var y = padding

        // ---- En-tête : modèle, puce, heure et date ----
        let model = HostInfo.modelString
        let modelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        draw(model, at: NSPoint(x: padding, y: y), font: modelFont, color: primary)

        // La puce complète l'identifiant sur la **même ligne**, calée à droite :
        // `MAC - 17.3` à gauche, `Apple M5 - 10 cœurs` à droite. Elle était
        // aussi écrite au-dessus de la ligne GPU, ce qui n'était qu'un doublon.
        //
        // Elle est **visuellement identique** à `MAC - 17.3` : même police
        // (taille et graisse) et même couleur `primary`. Plus de correction de
        // descendante, les deux points de `draw` sont au même niveau.
        let chipFont = modelFont
        drawRight(L("%1$@ - %2$d cores", HostInfo.chipString, coreCount),
                  at: NSPoint(x: padding, y: y),
                  rightEdge: bounds.width - padding,
                  font: chipFont, color: primary)
        y += rowHeight - 4

        // Seconde ligne : l'heure à gauche, la date à droite — cette dernière
        // se cale sous la puce, dans la même colonne.
        //
        // La date est au **format long** (`DateFormatter.Style.long`), dans la
        // langue active : « 14 octobre 2026 » en français, « October 14, 2026 »
        // en anglais. `dateFormat` en dur aurait figé l'ordre jour/mois, propre
        // au français.
        let headerDetailFont = NSFont.systemFont(ofSize: 10)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        draw(timeFormatter.string(from: snapshot.date),
             at: NSPoint(x: padding, y: y), font: headerDetailFont, color: secondary)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: Localization.current)
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .none
        drawRight(dateFormatter.string(from: snapshot.date),
                  at: NSPoint(x: padding, y: y), rightEdge: bounds.width - padding,
                  font: headerDetailFont, color: secondary)
        y += rowHeight + 4

        drawSeparator(y: y)
        y += 8

        // ---- CPU ----
        let cpuText = String(format: "%.0f %%", snapshot.cpu.total)
        drawRow(label: L("CPU"), value: cpuText, at: y, primary: primary, secondary: secondary,
                fraction: snapshot.cpu.total / 100)
        y += rowHeight + 4

        // Barres par cœur : dans l'ordre naturel (tel que rapporté par le système).
        // On n'effectue pas de tri par charge : cela ferait sauter les numéros
        // de cœur d'un rafraîchissement à l'autre et empêche de suivre un cœur
        // précis dans le temps. Le libellé « Cœur N » correspond donc bien au
        // N-ième cœur dans l'ordre système, et son pourcentage lui est associé.
        //
        // Fonction : affiche les barres de charge de chaque cœur dans l'ordre naturel
        // (index système). Pour chaque cœur : libellé "Cœur N", pourcentage formaté,
        // barre de progression, couleur par seuil de charge (gérée par drawCoreBar).
        if !snapshot.cpu.perCore.isEmpty {
            for (index, value) in snapshot.cpu.perCore.enumerated() {
                let label = L("Core %d", index + 1)
                let text = String(format: "%3.0f %%", value)
                drawCoreBar(label: label, value: text, fraction: value / 100, at: y,
                            primary: primary, secondary: secondary)
                y += 13
            }
            y += 5
        }

        drawSeparator(y: y)
        y += 8

        // ---- Processus les plus gourmands ----
        // Classés par charge CPU (voir `ProcessReader`). La hauteur est fixe :
        // on réserve toujours `processRowCount` lignes, que la liste soit
        // pleine ou non, pour que le panneau ne se redimensionne pas à chaque
        // rafraîchissement.
        draw(L("Top processes"), at: NSPoint(x: padding, y: y),
             font: .systemFont(ofSize: 10, weight: .semibold), color: secondary)
        y += 13

        // La géométrie de chaque ligne est recalculée ici : c'est le seul
        // endroit qui connaisse les positions, et `mouseMoved`/`mouseDown` la
        // relisent ensuite pour le survol et le clic.
        processRows.removeAll(keepingCapacity: true)
        let processes = Array(snapshot.processes.prefix(Self.processRowCount))
        for (index, process) in processes.enumerated() {
            let rowRect = NSRect(x: 4, y: y - 1,
                                 width: bounds.width - 8, height: Self.processRowHeight)
            let killRect = NSRect(x: bounds.width - padding - killColumnWidth, y: y,
                                  width: killColumnWidth, height: Self.processRowHeight)
            let killable = ProcessControl.canTerminate(process.pid)
            processRows.append(ProcessRow(process: process, rowRect: rowRect,
                                          killRect: killRect, killable: killable))

            if hoveredIndex == index {
                secondary.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: rowRect, xRadius: 4, yRadius: 4).fill()
            }

            drawProcessRow(process, at: y, primary: primary, secondary: secondary)

            // Le × n'apparaît que sur la ligne survolée et tuable : l'affordance
            // suit exactement ce que `ProcessControl` autorise.
            if hoveredIndex == index, killable {
                drawKillButton(at: y, color: secondary)
            }
            y += Self.processRowHeight
        }
        y += CGFloat(Self.processRowCount - processes.count) * Self.processRowHeight
        y += 5

        drawSeparator(y: y)
        y += 8

        // ---- GPU ----
        drawRow(label: L("GPU"),
                value: "\(snapshot.gpu.deviceUtilization) %",
                at: y, primary: primary, secondary: secondary,
                fraction: Double(snapshot.gpu.deviceUtilization) / 100)
        y += rowHeight

        if snapshot.gpu.inUseMemory > 0 {
            draw(L("Video memory %@", Formatters.bytes(snapshot.gpu.inUseMemory)),
                 at: NSPoint(x: padding + 92, y: y),
                 font: .systemFont(ofSize: 10), color: secondary)
            y += rowHeight - 4
        }

        drawSeparator(y: y)
        y += 8

        // ---- Mémoire ----
        drawRow(label: L("Memory"),
                value: "\(Int(snapshot.memory.fraction * 100)) %",
                at: y, primary: primary, secondary: secondary,
                fraction: snapshot.memory.fraction)
        y += rowHeight
        draw("\(Formatters.bytes(snapshot.memory.used)) / \(Formatters.bytes(snapshot.memory.total))",
             at: NSPoint(x: padding + 92, y: y), font: .systemFont(ofSize: 10), color: secondary)
        y += rowHeight - 4
        draw(L("compressed %1$@ · wired %2$@",
               Formatters.bytes(snapshot.memory.compressed),
               Formatters.bytes(snapshot.memory.wired)),
             at: NSPoint(x: padding + 92, y: y), font: .systemFont(ofSize: 10), color: secondary)
        y += rowHeight

        drawSeparator(y: y)
        y += 8

        // ---- Réseau ----
        drawRow(label: L("Network ↓"),
                value: Formatters.rate(snapshot.network.downloadPerSecond),
                at: y, primary: primary, secondary: secondary,
                fraction: networkFraction)
        y += rowHeight
        drawRow(label: L("Network ↑"),
                value: Formatters.rate(snapshot.network.uploadPerSecond),
                at: y, primary: primary, secondary: secondary,
                fraction: networkFraction)
        y += rowHeight
        if let interface = snapshot.network.activeInterface {
            draw(L("interface %@", interface), at: NSPoint(x: padding + 92, y: y),
                 font: .systemFont(ofSize: 10), color: secondary)
            y += rowHeight - 4
        }

        drawSeparator(y: y)
        y += 8

        // ---- Température ----
        if snapshot.temperature.dieCount > 0 {
            drawRow(label: L("SoC temperature"),
                    value: snapshot.temperature.socPeak.map { String(format: "%.1f °C", $0) } ?? "—",
                    at: y, primary: primary, secondary: secondary,
                    fraction: temperatureFraction)
            y += rowHeight
            let average = String(format: "%.1f", snapshot.temperature.socAverage ?? 0)
            let detail = L("avg %1$@ °C · %2$d measurement points",
                           average, snapshot.temperature.dieCount)
            draw(detail, at: NSPoint(x: padding + 92, y: y),
                 font: .systemFont(ofSize: 10), color: secondary)
            y += rowHeight - 3
        }

        // ---- Batterie ----
        if snapshot.battery.isPresent {
            drawSeparator(y: y)
            y += 8
            let symbol = snapshot.battery.isCharging ? "⚡︎ " : ""
            var text = "\(symbol)\(L("%d %%", snapshot.battery.level))"
            if let minutes = snapshot.battery.timeRemainingMinutes, minutes > 0 {
                let duration = Formatters.duration(minutes)
                text += snapshot.battery.isCharging ? " — \(duration)" : L(" — %@ remaining", duration)
            }
            // Marqueur textuel, comme le ⚡︎ de la charge : l'état doit se
            // lire sans la couleur. Le jaune de la jauge encode le mode
            // économie — or avec « Augmenter le contraste » macOS décale les
            // couleurs système, et le rouge vire au jaune. Un mot reste
            // fiable. Il est affiché même sous 20 %, où le rouge prend la
            // priorité : le mode est réel dans les deux cas.
            if snapshot.battery.isLowPowerMode { text += L(" · low power") }
            drawRow(label: L("Battery"), value: text, at: y, primary: primary, secondary: secondary,
                    fraction: Double(snapshot.battery.level) / 100,
                    tint: GaugeColor.battery(level: snapshot.battery.level,
                                             isPlugged: snapshot.battery.isPlugged,
                                             isCharging: snapshot.battery.isCharging,
                                             atChargeLimit: snapshot.battery.isAtChargeLimit,
                                             isLowPowerMode: snapshot.battery.isLowPowerMode))
            y += rowHeight
        }

        // ---- Pied de page ----
        drawSeparator(y: y)
        y += 8
        let footer = L("Refresh %1$@  ·  click to close", Formatters.interval(Interval.current))
        draw(footer, at: NSPoint(x: padding, y: y), font: .systemFont(ofSize: 9), color: secondary)
    }

    // MARK: - Éléments de dessin

    private var networkFraction: Double {
        let peak = max(snapshot.network.downloadPerSecond, snapshot.network.uploadPerSecond)
        // Même source que la barre de menus : une formule dupliquée diverge.
        return NetworkUsage.loadFraction(bytesPerSecond: peak)
    }

    private var temperatureFraction: Double {
        guard let peak = snapshot.temperature.socPeak else { return 0 }
        return max(0, min(1, (peak - 30) / 70))
    }

    private func drawSeparator(y: CGFloat) {
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: padding, y: y))
        line.line(to: NSPoint(x: bounds.width - padding, y: y))
        line.lineWidth = 0.5
        line.stroke()
    }

    /// Ligne « libellé … valeur » avec jauge horizontale.
    ///
    /// `tint` permet à une ligne de choisir sa couleur au lieu de subir
    /// les seuils génériques — c'est le cas de la batterie, dont la
    /// couleur dépend du branchement et pas seulement du niveau.
    private func drawRow(label: String, value: String, at y: CGFloat,
                         primary: NSColor, secondary: NSColor,
                         fraction: Double,
                         tint: NSColor? = nil) {
        draw(label, at: NSPoint(x: padding, y: y),
             font: .systemFont(ofSize: 11, weight: .medium), color: primary)

        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let valueSize = value.size(withAttributes: [.font: valueFont])
        draw(value, at: NSPoint(x: padding + lineWidth + valueGap - valueSize.width, y: y),
             font: valueFont, color: primary)

        // Jauge fine sous la ligne
        let barY = y + 12
        let barRect = NSRect(x: padding + lineWidth + valueGap, y: barY, width: lineWidth, height: 3)
        secondary.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

        let clamped = max(0, min(1, fraction))
        if clamped > 0 {
            let filled = NSRect(x: barRect.minX, y: barRect.minY,
                                width: max(2, barRect.width * clamped), height: barRect.height)
            (tint ?? GaugeColor.load(clamped)).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawCoreBar(label: String, value: String, fraction: Double, at y: CGFloat,
                             primary: NSColor, secondary: NSColor) {
        draw(label, at: NSPoint(x: padding, y: y),
             font: .systemFont(ofSize: 9), color: secondary)

        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let valueSize = value.size(withAttributes: [.font: valueFont])
        draw(value, at: NSPoint(x: padding + lineWidth + valueGap - valueSize.width, y: y),
             font: valueFont, color: secondary)

        let barRect = NSRect(x: padding + lineWidth + valueGap, y: y + 2, width: lineWidth, height: 3)
        secondary.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 1.5, yRadius: 1.5).fill()

        let clamped = max(0, min(1, fraction))
        if clamped > 0 {
            let filled = NSRect(x: barRect.minX, y: barRect.minY,
                                width: max(2, barRect.width * clamped), height: barRect.height)
            NSColor.systemGreen.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    /// Ligne d'un processus : nom puis PID à gauche, charge CPU et mémoire à
    /// droite.
    ///
    /// Le PID suit immédiatement le nom : il départage deux processus
    /// homonymes (plusieurs « Helper » partagent le même nom). Sa place est
    /// réservée **dans** la largeur allouée au nom, sinon un nom long le
    /// pousserait sous la colonne du pourcentage CPU.
    ///
    /// Les colonnes de valeurs sont alignées sur celles des cœurs (`CPU`) et,
    /// pour la mémoire, sur la colonne réservée au bouton × (bord droit).
    private func drawProcessRow(_ process: ProcessUsage, at y: CGFloat,
                                primary: NSColor, secondary: NSColor) {
        let nameFont = NSFont.systemFont(ofSize: 9)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)

        let pid = "\(process.pid)"
        let pidWidth = pid.size(withAttributes: [.font: valueFont]).width
        // Écart entre la fin du nom et le début du PID.
        let pidGap: CGFloat = 5
        let name = truncated(process.name,
                             toWidth: max(0, processNameWidth - pidWidth - pidGap),
                             font: nameFont)
        draw(name, at: NSPoint(x: padding, y: y), font: nameFont, color: primary)

        let nameWidth = name.size(withAttributes: [.font: nameFont]).width
        draw(pid, at: NSPoint(x: padding + nameWidth + pidGap, y: y),
             font: valueFont, color: secondary)

        let cpu = String(format: "%.1f %%", process.cpu)
        drawRight(cpu, at: NSPoint(x: padding, y: y),
                  rightEdge: padding + lineWidth + valueGap, font: valueFont, color: secondary)
        let memory = Formatters.bytes(process.memory)
        drawRight(memory, at: NSPoint(x: bounds.width / 2, y: y),
                  rightEdge: bounds.width - padding - killColumnWidth,
                  font: valueFont, color: secondary)
    }

    /// Bouton de terminaison, dessiné uniquement sur la ligne survolée.
    ///
    /// Un simple glyphe « ✕ » plutôt qu'un contrôle AppKit : le panneau est
    /// dessiné à la main, et la zone cliquable est fournie par `killRect`.
    private func drawKillButton(at y: CGFloat, color: NSColor) {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let glyph = "✕"
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = glyph.size(withAttributes: attributes)
        let columnLeft = bounds.width - padding - killColumnWidth
        let x = columnLeft + (killColumnWidth - size.width) / 2
        glyph.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }

    /// Tronque une chaîne pour qu'elle tienne dans `width`, `…` compris.
    ///
    /// `String.draw(at:)` ne coupe pas : un nom long déborderait sur la
    /// colonne du pourcentage. On retire des caractères par la fin jusqu'à ce
    /// que le résultat, ellipse incluse, tienne dans la largeur voulue.
    private func truncated(_ string: String, toWidth width: CGFloat, font: NSFont) -> String {
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        guard string.size(withAttributes: attributes).width > width else { return string }
        let ellipsis = "…"
        let ellipsisWidth = ellipsis.size(withAttributes: attributes).width
        var cut = string
        while !cut.isEmpty, cut.size(withAttributes: attributes).width + ellipsisWidth > width {
            cut.removeLast()
        }
        return cut + ellipsis
    }

    /// Texte calé sur le bord droit de la zone de contenu.
    ///
    /// `String.draw(at:)` n'ancre qu'en bas à gauche : aligner à droite
    /// impose de mesurer la chaîne et de décaler son départ. La mesure se
    /// fait avec la même police que le dessin, sinon le texte déborde.
    ///
    /// Si la chaîne est plus large que la place disponible, elle n'est pas
    /// dessinée : chevaucher l'identifiant serait pire que de perdre
    /// l'information.
    private func drawRight(_ string: String, at point: NSPoint, rightEdge: CGFloat,
                           font: NSFont, color: NSColor) {
        let width = string.size(withAttributes: [.font: font]).width
        let x = rightEdge - width
        guard x >= point.x else { return }
        draw(string, at: NSPoint(x: x, y: point.y), font: font, color: color)
    }

    /// Couleur des jauges.
private func draw(_ string: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        string.draw(at: point, withAttributes: attributes)
    }
}

// MARK: - Couleurs de jauges

/// Source unique, partagée par le panneau et la barre de menus. Les deux
/// vues avaient chacune leur copie, qui divergeaient déjà : c'est ainsi
/// qu'une batterie à 80 % s'est affichée en rouge partout.
enum GaugeColor {
    /// Seuils d'une jauge de **charge** (CPU, GPU, mémoire, réseau…).
    ///
    /// 60 / 80 % : au-delà, la ressource est saturée.
    static func load(_ fraction: Double) -> NSColor {
        switch fraction {
        case ..<0.6: return .systemGreen
        case ..<0.8: return .systemYellow
        default:     return .systemRed
        }
    }

    /// Seuil d'alerte batterie. En dessous, le rouge est justifié même
    /// branché : 5 % sur secteur signale un chargeur ou une batterie
    /// défaillante, pas un fonctionnement normal.
    private static let batteryCritical = 0.20

    /// Seuil de vigilance en décharge, sous lequel on orange.
    private static let batteryLow = 0.40

    /// Couleur d'une jauge de batterie.
    ///
    /// | état                            | couleur |
    /// |---------------------------------|---------|
    /// | sous 20 %                       | rouge   |
    /// | mode économie actif             | jaune   |
    /// | branché, plafond atteint        | bleu    |
    /// | branché, en charge              | vert    |
    /// | sur batterie, sous 40 %         | orange  |
    /// | sinon                            | vert    |
    ///
    /// Le **jaune suit la convention Apple** : il ne qualifie pas un niveau
    /// mais un mode. Apple Support : « When Low Power Mode is active, the
    /// battery icon in the status bar turns yellow. » Un jaune de vigilance
    /// sous 40 % aurait été une convention inventée, et une collision : le
    /// même jaune ne pouvait pas dire deux choses.
    ///
    /// L'orange, lui, prend la vigilance. Il reste la couleur d'« attention »
    /// de macOS, et il est libre parce que la charge est passée au vert.
    ///
    /// Le passage vert → bleu utilise le **signal direct** de macOS
    /// (`NotChargingReason` bit 24), et non une déduction de l'état de
    /// charge. On avait d'abord inféré « plafond atteint » de trois indices
    /// (branché, pas en train de charger, temps de charge nul) ; la mesure a
    /// montré que cette déduction était fausse — branché et immobile ne
    /// signifie pas « au plafond », seulement que le chargeur n'a pas encore
    /// repris. Voir `BatteryStatus.isAtChargeLimit`.
    ///
    /// Ces seuils (20 %, 40 %) n'ont **aucune source Apple** : Apple ne
    /// publie pas de table de couleur par niveau. Ce sont des choix de
    /// lisibilité, à reviser si l'usage s'y prête.
    static func battery(level: Int, isPlugged: Bool, isCharging: Bool,
                        atChargeLimit: Bool, isLowPowerMode: Bool = false) -> NSColor {
        let fraction = Double(level) / 100
        if fraction < batteryCritical { return .systemRed }
        if isLowPowerMode { return .systemYellow }
        if isPlugged || isCharging {
            if atChargeLimit { return .systemBlue }
            if isCharging { return .systemGreen }
        }
        return fraction < batteryLow ? .systemOrange : .systemGreen
    }
}

// MARK: - Informations machine

enum HostInfo {
    /// Identifiant de modèle, mis en forme pour la lecture.
    ///
    /// `hw.model` renvoie une valeur du type `Mac17,3` ou
    /// `MacBookPro18,3`. Le préfixe de gamme est retiré : il n'apporte rien
    /// à l'affichage et ferait `MAC - Mac17,3`. Ce qui reste — la famille et
    /// la variante — est rendu `MAC - 17.3`.
    static let modelString: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "MAC" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        let raw = String(cString: buffer)

        // On ne conserve que la partie numérique. Si le préfixe n'a pas la
        // forme attendue, on retombe sur la valeur brute plutôt que
        // d'afficher un `MAC - ` sans rien derrière.
        guard let start = raw.range(of: #"\d"#, options: .regularExpression)?.lowerBound else {
            return raw
        }
        let number = raw[start...]
            .replacingOccurrences(of: ",", with: ".")
            .uppercased()
        return "MAC - \(number)"
    }()

    static let chipString: String = {
        // Sur Apple Silicon, la marque CPU expose le nom réel de la puce.
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        if size > 0 {
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
            let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { return value }
        }
        return "Apple Silicon"
    }()
}

// MARK: - Formatage

enum Formatters {
    /// Octets en unités lisibles, base 1024.
    static func bytes(_ value: Double) -> String {
        let units = [L("B"), L("KB"), L("MB"), L("GB"), L("TB")]
        var amount = value
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return unit == 0
            ? String(format: "%.0f %@", amount, units[unit])
            : String(format: "%.1f %@", amount, units[unit])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        return bytes(bytesPerSecond) + "/s"
    }

    /// Durée en minutes : autonomie restante, temps de charge.
    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return L("%d min", minutes) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? L("%d h", hours) : L("%1$d h %2$d", hours, rest)
    }

    /// Intervalle en **secondes**, pour le pied de panneau.
    ///
    /// Volontairement distinct de `duration(_:)`, qui attend des minutes.
    /// Passer des secondes à ce dernier affichait « 2 min » pour une
    /// cadence de 2 s.
    static func interval(_ seconds: Double) -> String {
        if seconds < 60 { return L("%.0f s", seconds) }
        return duration(Int((seconds / 60).rounded()))
    }
}

enum Interval {
    /// Intervalle de rafraîchissement en secondes.
    static var current: Double = 2.0
}
