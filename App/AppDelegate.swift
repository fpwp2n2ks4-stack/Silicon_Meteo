//
//  AppDelegate.swift
//  Point d'entrée de l'application barre de menus
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var statusView: StatusItemView!
    private var popover: NSPopover!

    private let collector = MetricsCollector()
    private var timer: Timer?

    private var latest: Snapshot
    private let coreCount: Int

    // Historique court pour lisser le débit réseau (les compteurs bursty
    // rendent le débit instantané illisible d'une tick à l'autre).
    private var netSamples: [(Date, Double)] = []

    override init() {
        var initial = Snapshot()
        initial.battery.isPresent = true
        latest = initial
        coreCount = ProcessInfo.processInfo.processorCount
        super.init()
    }

    // MARK: - Cycle de vie
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent de barre de menus uniquement : pas d'icône dans le Dock.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        startTimer()

        // Première lecture après avoir installé les vues, sinon `refresh()`
        // tenterait de mettre à jour un `statusView` encore nil.
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
    }

    // MARK: - Barre de menus

    private func setupStatusItem() {
        // Rien ici ne doit lire `statusItem.button?.window` ni appeler
        // `convert(_:to:)`. Ces accès matérialisent la fenêtre de l'item avant
        // qu'AppKit ait fini sa passe de démarrage, et elle reste alors
        // aplatie : hauteur 0, origine (0, 0), rien à l'écran. Le symptôme est
        // trompeur — le bouton a bien une taille correcte, seule la fenêtre
        // reste plate. Toute inspection de la géométrie se fait donc après le
        // lancement, jamais dans ce chemin.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusView = StatusItemView(snapshot: latest)
        statusItem.button?.addSubview(statusView)

        // Le clic ouvre le panneau ; pas de menu système, le panneau suffit.
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        updateStatusItemSize()
        statusView.isHidden = false
        statusView.needsDisplay = true
    }

    /// Recalcule la place occupée dans la barre de menus.
    ///
    /// La longueur du `statusItem` est fixée explicitement plutôt que laissée
    /// variable : le bouton ajoute de la marge interne qu'il faut compenser,
    /// sinon la vue est rognée d'un côté.
    private func updateStatusItemSize() {
        guard let button = statusItem.button else { return }
        let size = statusView.intrinsicContentSize

        // Marge standard d'un item de barre de menus, de part et d'autre.
        let inset: CGFloat = 6
        statusItem.length = size.width + inset * 2

        // La hauteur du bouton appartient à la barre de menus : on ne la fixe
        // pas. Elle est déjà déduite de `statusItem.length`, et `bounds` donne
        // la taille réelle — se contenter de s'y ajuster évite de se battre
        // avec la mise en page du système.
        //
        // On ne fixe PAS `button.frame.size.height` : le conteneur du bouton
        // se retrouve à y = -11 (géométrie normale pour un NSStatusBarButton),
        // et imprisonner la hauteur dans le cadre du bouton désynchronise le
        // recalcul du système sans gain mesurable.
        statusView.frame = NSRect(x: inset,
                                  y: (max(button.bounds.height, 22) - size.height) / 2,
                                  width: size.width,
                                  height: size.height)
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    // MARK: - Panneau

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        // Le panneau se ferme au clic dehors : le comportement `.transient`
        // s'en charge, mais on force aussi la fermeture au changement d'état.
        let controller = NSViewController()
        let view = PopupView(snapshot: latest, coreCount: coreCount)
        view.popover = popover
        controller.view = view
        popover.contentViewController = controller
        popover.contentSize = view.frame.size
    }

    private func openPopover() {
        guard let view = popover.contentViewController?.view as? PopupView else { return }
        view.snapshot = latest
        view.needsDisplay = true
        popover.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func closePopover() {
        popover.performClose(nil)
    }

    // MARK: - Boucle de collecte

    private func startTimer() {
        let timer = Timer(timeInterval: Interval.current, repeats: true) { [weak self] _ in
            // Une lecture prend quelques ms : on la fait sur le thread courant,
            // le timer étant sur le run loop principal. Assez rapide pour 2 s.
            self?.refresh()
        }
        // .common : le timer continue pendant le glissement d'une fenêtre.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        var snapshot = collector.read()

        smoothNetwork(&snapshot)
        latest = snapshot

        statusView.snapshot = snapshot
                updateStatusItemSize()
        DispatchQueue.main.async { [weak self] in
            self?.updateStatusItemSize()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.updateStatusItemSize()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.updateStatusItemSize()
        }

        if let view = popover.contentViewController?.view as? PopupView, popover.isShown {
            view.snapshot = snapshot
            view.needsDisplay = true
        }
    }

    /// Moyenne glissante du débit sur ~6 s pour éviter les pics d'une tick.
    private func smoothNetwork(_ snapshot: inout Snapshot) {
        let now = snapshot.date
        netSamples.append((now, snapshot.network.downloadPerSecond + snapshot.network.uploadPerSecond))
        netSamples.removeAll { now.timeIntervalSince($0.0) > 6 }

        guard netSamples.count > 1 else { return }
        // On garde la dernière lecture pour la répartition ↓/↑, et on
        // remplace seulement la valeur lissée du total.
        let average = netSamples.reduce(0.0) { $0 + $1.1 } / Double(netSamples.count)
        let last = netSamples[netSamples.count - 1].1
        let ratio = last > 0 ? (snapshot.network.downloadPerSecond / last) : 0.5
        snapshot.network.downloadPerSecond = average * ratio
        snapshot.network.uploadPerSecond = average * (1 - ratio)
    }

    /// Icône de batterie adaptée au niveau, tirée des symboles SF.
    ///
    /// SF Symbols expose `battery.100`, `battery.75`… mais le rendu varie
    /// selon la taille ; on garde une seule hauteur pour un alignement net.
    private func batterySymbol(for battery: BatteryStatus) -> NSImage? {
        guard battery.isPresent else { return nil }
        let level = max(0, min(100, battery.level))
        // Paliers SF Symbols disponibles.
        let step: Int
        switch level {
        case 100...:  step = 100
        case 76...99: step = 75
        case 51...75: step = 50
        case 26...50: step = 25
        default:      step = 0
        }
        let name = battery.isCharging ? "battery.100.bolt" : "battery.\(step)"
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}
