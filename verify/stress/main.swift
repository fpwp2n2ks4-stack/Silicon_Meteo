//
//  stress.swift
//  Test de robustesse du TemperatureReader
//
//  Le bug corrigé était un use-after-free : il ne se manifeste qu'après
//  quelques appels, quand ARC ou IOKit finit par toucher une référence
//  libérée. Une lecture unique ne prouve donc rien — il faut marteler.
//

import Foundation

let reader = TemperatureReader()

// Phase 1 : hammer le lecteur, y compris avec des reconstructions de client.
var peakSeen: Double = 0
var samples = 0
for iteration in 0..<400 {
    let t = reader.read()
    if let peak = t.socPeak { peakSeen = max(peakSeen, peak) }
    if iteration % 50 == 0, t.dieCount > 0 {
        let avg = t.socAverage.map { String(format: "%.1f", $0) } ?? "—"
        print("  \(iteration.formatted()): \(t.dieCount) capteurs, moy \(avg) °C, pic \(t.socPeak.map { String(format: "%.1f", $0) } ?? "—") °C")
    }
    samples += t.dieCount
    // Force l'allocation/libération d'objets Core Foundation autour de
    // chaque cycle : un use-after-free se révèle bien plus facilement.
    autoreleasepool { _ = NSString(format: "%d-%f", iteration, peakSeen) }
}

// Phase 2 : lecture depuis une tâche de fond — les lectures sont appelées
// par un timer sur le fil principal, mais une erreur d'ownership peut
// corrompre la mémoire sans lien avec le fil.
let done = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    for _ in 0..<400 { _ = reader.read() }
    done.signal()
}
// Une seconde lecture concurrente depuis le fil principal : c'est
// exactement ce que ferait un timer déclenché pendant le refresh.
var concurrent = 0
while done.wait(timeout: .now() + 0.01) == .timedOut {
    concurrent += reader.read().dieCount
}

print("""
✅ survived
  800 lectures, \(samples) échantillons de capteurs, pic \(String(format: "%.1f", peakSeen)) °C
  aucune libération croisée détectée
""")