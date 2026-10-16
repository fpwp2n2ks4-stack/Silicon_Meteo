//
//  main.swift
//  verify/disk
//
//  Vérification hors interface des lecteurs disque : occupation, débit et
//  SMART NVMe. Compilé avec Sensors/Sensors.swift, sans AppKit.
//
//  swiftc Sensors/Sensors.swift verify/disk/main.swift -o /tmp/toasty-disk
//  /tmp/toasty-disk
//

import Foundation

func gigabytes(_ bytes: Double) -> String {
    String(format: "%.2f Go", bytes / 1_000_000_000)
}

let reader = DiskReader()

// Première lecture : le débit a besoin d'un intervalle, il vaut donc 0.
let first = reader.read()
print("— occupation —")
print("  présent   : \(first.isPresent)")
print("  système   : \(first.fileSystem)")
print("  total     : \(gigabytes(first.total))")
print("  occupé    : \(gigabytes(first.used))")
print("  libre     : \(gigabytes(first.free))")
print("  fraction  : \(String(format: "%.1f %%", first.fraction * 100))")
print("  (1re lecture débit : \(first.readPerSecond) o/s)")

// Laisse le temps aux compteurs de bouger, puis relit. On force un peu
// d'activité disque pour vérifier que les compteurs IOKit sont bien lus.
Thread.sleep(forTimeInterval: 1.0)
print("— débit (écriture forcée de 200 Mo) —")
let payload = Data(repeating: 0x41, count: 1_000_000)
do {
    let url = URL(fileURLWithPath: "/tmp/toasty-disk-test.bin")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    for _ in 0..<200 { try handle.write(contentsOf: payload) }
    try handle.close()
    try FileManager.default.removeItem(at: url)
} catch {
    print("  (écriture impossible : \(error))")
}
let second = reader.read()
print("  lecture   : \(second.readPerSecond) o/s")
print("  écriture  : \(second.writePerSecond) o/s")

// Le SMART démarre avec un délai anti-démarrage de 10 s : on attend.
print("— SMART (attente du délai de démarrage ~11 s) —")
Thread.sleep(forTimeInterval: 11)
let third = reader.read()
if let temperature = third.smartTemperature {
    print("  température SSD : \(String(format: "%.0f °C", temperature))")
} else {
    print("  température SSD : indisponible")
}
if let health = third.smartHealth {
    print("  santé SSD       : \(health) %")
} else {
    print("  santé SSD       : indisponible")
}
