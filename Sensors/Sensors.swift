//
//  Sensors.swift
//  Module de lecture des métriques système (Apple Silicon)
//
//  Toutes les valeurs sont des structs Sendable, lues depuis une file
//  de fond à intervalle régulier. Aucun accès privilégié, aucun helper.
//

import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - Déclarations IOKit non exposées au module Swift
//
// Le SDK des Command Line Tools n'expose ni `IOHIDEventSystemClient`, ni
// `IORegistryEntry.h`, ni `IOReportLib.h`. On déclare donc à la main les
// points d'entrée dont on a besoin — même approche que le bridge.h de Stats.

typealias HIDClient = CFTypeRef
typealias HIDService = CFTypeRef
typealias HIDEvent = CFTypeRef

// Ownership is the whole subtlety here.
//
// Every IOHID function whose name contains "Copy" hands back a **+1**
// reference. Declaring it as returning plain `CFTypeRef` makes Swift treat
// the result as an ARC-managed object and release it, on top of the
// ownership IOKit already granted us: a double free, which surfaces as
// `_os_unfair_lock_corruption_abort` inside IOHID, or as silent garbage.
//
// Returning `Unmanaged` keeps ARC out of the picture; we then consume the
// reference explicitly with `takeRetainedValue()`.

@_silgen_name("IOHIDEventSystemClientCreate")
func hidClientCreate(_ allocator: CFAllocator?) -> Unmanaged<HIDClient>?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func hidClientSetMatching(_ client: HIDClient, _ match: CFDictionary) -> Int32

@_silgen_name("IOHIDEventSystemClientCopyServices")
func hidClientCopyServices(_ client: HIDClient) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func hidServiceCopyProperty(_ service: HIDService, _ key: CFString) -> Unmanaged<CFTypeRef>?

@_silgen_name("IOHIDServiceClientCopyEvent")
func hidServiceCopyEvent(_ service: HIDService, _ type: Int64, _ options: Int32,
                         _ timestamp: Int64) -> Unmanaged<HIDEvent>?

/// Parameter is **borrowed** — passed without ownership transfer.
@_silgen_name("IOHIDEventGetFloatValue")
func hidEventFloatValue(_ event: HIDEvent, _ field: Int32) -> Double

/// kIOHIDEventTypeTemperature
private let kHIDEventTypeTemperature: Int64 = 15
/// IOHIDEventFieldBase(type) == (type << 16)
private let kHIDEventFieldTemperatureBase: Int32 = 15 << 16

// MARK: - Types de sortie

public struct CPUUsage {
    public var total: Double = 0            // 0...100
    public var perCore: [Double] = []
}

public struct MemoryUsage {
    public var used: Double = 0             // octets
    public var total: Double = 0            // octets
    public var compressed: Double = 0       // octets
    public var wired: Double = 0            // octets
    public var swapUsed: Double = 0         // octets

    public var fraction: Double { total > 0 ? used / total : 0 }
}

public struct NetworkUsage {
    public var downloadPerSecond: Double = 0   // octets/s (somme des interfaces actives)
    public var uploadPerSecond: Double = 0
    public var activeInterface: String?        // "en0", "en1"…

    /// Jauge de charge réseau, saturée à 1.
    ///
    /// ## Pourquoi une échelle fixe, et non la capacité du lien
    ///
    /// L'idée naturelle serait de caler la jauge sur la bande passante
    /// theorique de l'interface (« 80 % de 1 Gbit/s »). Elle est inapplicable
    /// ici, pour une raison mesurée sur cette machine :
    ///
    /// | source                                  | résultat                    |
    /// |-----------------------------------------|-----------------------------|
    /// | `ifconfig en0`                          | `media: autoselect`, sans   |
    /// |                                         | vitesse annoncée            |
    /// | `sysctl net.link.physical.*`            | n'existe pas               |
    /// | `SIOCGIFINFO` / `ifru_baudrate`         | non exposé à Swift          |
    /// | DHCP                                    | `en0` en IP fixe, rien     |
    /// |                                         | à annoncer                  |
    ///
    /// La vitesse negotiated n'est donc pas lisible. Elle serait de plus
    /// instable et trompeuse en Wi-Fi : un lien annoncé à 1 Gbit/s peut
    /// ne délivrer que 200 Mbit/s, et une jauge calibrée sur l'annonce
    /// resterait au vert pendant un vrai plafond. Une jauge qui ne ment
    /// pas vaut mieux qu'une jauge prétendument exacte.
    ///
    /// L'échelle est donc **logarithmique**, avec des seuils nommés : un
    /// transfert de fichier produit un pic, pas un niveau de charge, et
    /// une échelle linéaire l'étalerait sur toute la hauteur. Les seuils
    /// sont explicites pour que le passage vert → jaune → rouge se lise
    /// dans le code au lieu d'être caché dans une division.
    ///
    /// Fraction de jauge, alignée sur les deux seuils ci-dessus.
    ///
    /// `GaugeColor.load` bascule à 0,60 puis 0,80. L'échelle est donc
    /// calibrée pour que **chaque seuil nommé tombe exactement sur sa
    /// frontière de couleur** — sinon le commentaire annoncerait 1,5 Mo/s
    /// alors que le jaune arrive à 1,0, et la jauge contredirait sa
    /// propre documentation.
    ///
    /// `greenBelowBytesPerSecond` produit 0,5999997 et `yellowBelow…`
    /// 0,7999997 : les deux restent **juste en dessous** de la bascule,
    /// parce que la racine de 10 n'a pas de représentation exacte en
    /// flottant. Le seuil est donc le dernier débit encore dans la couleur
    /// inférieure, pas le premier dans la suivante.
    ///
    /// - Parameter bytesPerSecond: le plus élevé des deux débits, mesuré sur
    ///   l'interface active — une jauge ne montre pas le trafic cumulé de
    ///   toutes les interfaces, qui n'a aucun sens.
    public static func loadFraction(bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        let normalized = log10(1 + bytesPerSecond / 100_000) / 2
        return min(1, max(0, normalized))
    }

    /// Dernier débit encore vert : 1 484 892 o/s, soit ≈ 1,48 Mo/s.
    ///
    /// Résolu à partir de l'échelle — `b = 100 000 × (10^(2f) − 1)` avec
    /// `f = 0,60` — plutôt que recopié d'une mesure, pour que les deux
    /// restent justes si la normalisation change.
    public static let greenBelowBytesPerSecond: Double = 1_484_892
    /// Dernier débit encore jaune : 3 881 071 o/s, soit ≈ 3,88 Mo/s.
    public static let yellowBelowBytesPerSecond: Double = 3_881_071
}

public struct BatteryStatus {
    // swiftlint:disable implicit_optional_initialization
    // `= nil` est explicite ici parce que ces propriétés sont publiques :
    // la valeur par défaut fait partie de l'API, elle se lit dans la
    // déclaration plutôt que dans la documentation.
    public var level: Int = 0                  // 0...100
    public var isCharging: Bool = false
    public var isPlugged: Bool = false
    /// Mode économie d'énergie actif (Réglages > Batterie).
    ///
    /// `ProcessInfo.isLowPowerModeEnabled` est le signal direct et officiel,
    /// disponible depuis macOS 12. Il ne dit rien du niveau de charge : c'est
    /// un **mode**, pas un seuil. Voir `GaugeColor.battery`.
    public var isLowPowerMode: Bool = false
    public var timeRemainingMinutes: Int? = nil
    public var temperature: Double? = nil
    public var cycleCount: Int? = nil
    public var healthPercent: Int? = nil
    public var isPresent: Bool = false
    // swiftlint:enable implicit_optional_initialization

    /// Motif pour lequel macOS refuse de charger (`ChargerData.NotChargingReason`).
    public var notChargingReason: Int = 0

    /// macOS a décidé de lui-même de ne plus monter la charge : seuil de
    /// charge atteint, ou charge optimisée qui retient la batterie aux
    /// alentours de 80 %.
    ///
    /// Signal **direct**, mesuré sur une>M5 dans les états réels :
    ///
    /// | état                            | `NotChargingReason` | drapeau |
    /// |---------------------------------|---------------------|---------|
    /// | en train de charger (81 %)       | `0x00000000`        | faux    |
    /// | charge suspendue (81 %, branché) | `0x01000000`        | **vrai** |
    /// | ancien plafond 80 %, branché     | `0x01000000`        | **vrai** |
    /// | débranché                       | `0x00000080`        | faux    |
    ///
    /// Le bit suit la **décision** de macOS, pas le pourcentage : observé
    /// à 81 % dans les deux sens selon que la charge court ou est retenue.
    /// C'est exactement la distinction qui manquait à une déduction par
    /// l'état apparent — branché et immobile ne veut pas dire « au plafond ».
    ///
    /// Apple ne publie pas la table de ce bitfield. Seul le bit 24 est connu
    /// de première main, parce qu'il est apparu et disparu avec le basculement
    /// du réglage de limite. Les autres bits restent non interprétés ;
    /// `notChargingReason` est exposé brut pour le diagnostic.
    public var isAtChargeLimit: Bool {
        notChargingReason & Self.chargeLimitBit != 0
    }

    /// Bit 24 — « macOS retient la charge ».
    private static let chargeLimitBit = 0x0100_0000
}

public struct GPUUsage {
    public var deviceUtilization: Int = 0     // 0...100
    public var rendererUtilization: Int = 0
    public var tilerUtilization: Int = 0
    public var coreCount: Int = 0
    public var model: String = ""
    public var inUseMemory: Double = 0         // octets
}

/// Sur Apple Silicon, CPU et GPU partagent le même die : il n'existe pas
/// de capteur séparé « CPU » et « GPU ». On expose donc des zones du die.
public struct Temperature {
    // swiftlint:disable implicit_optional_initialization
    public var socAverage: Double? = nil
    public var socPeak: Double? = nil
    // swiftlint:enable implicit_optional_initialization
    public var dieCount: Int = 0
    public var sensorNames: [String] = []
    /// Détail par capteur, trié du plus chaud au plus froid
    public var sensors: [(name: String, celsius: Double)] = []
}

public struct Snapshot {
    public var cpu: CPUUsage = CPUUsage()
    public var memory: MemoryUsage = MemoryUsage()
    public var network: NetworkUsage = NetworkUsage()
    public var battery: BatteryStatus = BatteryStatus()
    public var gpu: GPUUsage = GPUUsage()
    public var temperature: Temperature = Temperature()
    public var date: Date = Date()
}

// MARK: - Utilitaires

private func ioProperty(_ service: io_object_t, _ key: String) -> AnyObject? {
    guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    return ref.takeRetainedValue()
}

// MARK: - CPU

/// Signature `host_processor_info` de macOS 24+.
///
/// Le 5e paramètre est `mach_msg_type_number_t *out_processor_infoCnt`
/// (nombre d'entiers dans le tampon). Le wrapper Swift du SDK est resté sur
/// l'ancienne signature `processor_name_array_t *` : l'appeler provoque un
/// SIGSEGV immédiat. D'où la déclaration manuelle.
@_silgen_name("host_processor_info")
private func hostProcessorInfo(
    _ host: mach_port_t,
    _ flavor: processor_flavor_t,
    _ outProcessorCount: UnsafeMutablePointer<natural_t>?,
    _ outProcessorInfo: UnsafeMutablePointer<UnsafeMutablePointer<integer_t>?>?,
    _ outProcessorInfoCnt: UnsafeMutablePointer<mach_msg_type_number_t>?
) -> kern_return_t

private let kFlavorProcessorCPULoad = processor_flavor_t(2)  // PROCESSOR_CPU_LOAD_INFO
private let kCPUTicksPerCore = 4                             // CPU_STATE_MAX

public final class CPUReader: @unchecked Sendable {
    private struct Ticks {
        var user: UInt32 = 0, system: UInt32 = 0, idle: UInt32 = 0, nice: UInt32 = 0
    }
    private var previous: [Ticks] = []
    public private(set) var coreCount: Int = 0

    public init() {
        if let ticks = Self.sample() {
            previous = ticks
            coreCount = ticks.count
        } else {
            coreCount = ProcessInfo.processInfo.processorCount
        }
    }

    private static func sample() -> [Ticks]? {
        var nproc: natural_t = 0
        var info: UnsafeMutablePointer<integer_t>?
        var count: mach_msg_type_number_t = 0
        let rc = hostProcessorInfo(mach_host_self(), kFlavorProcessorCPULoad, &nproc, &info, &count)
        guard rc == KERN_SUCCESS, let info, nproc > 0 else { return nil }

        var result: [Ticks] = []
        result.reserveCapacity(Int(nproc))
        for i in 0..<Int(nproc) {
            result.append(Ticks(
                user: UInt32(bitPattern: info[i * kCPUTicksPerCore + 0]),
                system: UInt32(bitPattern: info[i * kCPUTicksPerCore + 1]),
                idle: UInt32(bitPattern: info[i * kCPUTicksPerCore + 2]),
                nice: UInt32(bitPattern: info[i * kCPUTicksPerCore + 3])
            ))
        }
        // Le noyau a alloué le tampon : sans libération, fuite à chaque tick.
        vm_deallocate(mach_task_self_,
                      vm_address_t(UInt(bitPattern: info)),
                      vm_size_t(count) * 4)
        return result
    }

    public func read() -> CPUUsage {
        guard let now = Self.sample(), !now.isEmpty else { return CPUUsage() }
        var perCore: [Double] = []
        perCore.reserveCapacity(now.count)
        var sum: Double = 0

        for (index, current) in now.enumerated() {
            let old = index < previous.count ? previous[index] : Ticks()
            let dUser = current.user &- old.user
            let dSystem = current.system &- old.system
            let dIdle = current.idle &- old.idle
            let dNice = current.nice &- old.nice
            let ticks = Double(dUser &+ dSystem &+ dIdle &+ dNice)
            let load = ticks > 0 ? Double(dUser &+ dSystem) / ticks * 100 : 0
            perCore.append(load)
            sum += load
        }

        previous = now
        return CPUUsage(total: sum / Double(now.count), perCore: perCore)
    }
}

// MARK: - Mémoire

public struct MemoryReader: Sendable {
    public init() {}

    public func read() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let rc = host_statistics64(
            mach_host_self(),
            HOST_VM_INFO64,
            withUnsafeMutablePointer(to: &stats) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { $0 }
            },
            &count
        )
        guard rc == KERN_SUCCESS else { return MemoryUsage() }

        let pageSize = Double(vm_page_size)
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize

        return MemoryUsage(
            used: active + wired + compressed,
            total: Double(ProcessInfo.processInfo.physicalMemory),
            compressed: compressed,
            wired: wired,
            // `swap_count` = pages actuellement(populés dans le fichier d'échange.
            swapUsed: Double(stats.swap_count) * Double(vm_page_size)
        )
    }
}

// MARK: - Réseau

public final class NetworkReader: @unchecked Sendable {
    private struct Counters { var rx: UInt32 = 0; var tx: UInt32 = 0 }
    private var previous: [String: Counters] = [:]
    private var lastTimestamp: Date?

    public init() {}

    /// Interfaces à ignorer : boucle locale et interfaces virtuelles
    /// qui fausseraient le débit affiché.
    private static let ignored: Set<String> = [
        "lo0", "awdl0", "llw0", "bridge0", "anpi0", "gif0", "stf0",
        "utun0", "utun1", "utun2", "utun3", "utun4", "utun5",
        "vmnet1", "vmnet2", "vmnet3", "vnic0", "ap1"
    ]

    private static func collect() -> [String: Counters] {
        var list: [String: Counters] = [:]
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return list }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let node = cursor {
            let interface = node.pointee
            if let data = interface.ifa_data?.assumingMemoryBound(to: if_data.self) {
                let name = String(cString: interface.ifa_name)
                // ifi_ibytes / ifi_obytes sont des entiers 32 bits signés dans
                // la structure : on masque pour obtenir la valeur brute.
                list[name] = Counters(rx: UInt32(truncatingIfNeeded: data.pointee.ifi_ibytes),
                                      tx: UInt32(truncatingIfNeeded: data.pointee.ifi_obytes))
            }
            cursor = interface.ifa_next
        }
        return list
    }

    public func read() -> NetworkUsage {
        let current = Self.collect()
        let now = Date()
        // Le débit a besoin d'un intervalle : au premier appel, on ne mesure rien.
        guard let last = lastTimestamp else {
            previous = current
            lastTimestamp = now
            return NetworkUsage()
        }
        let elapsed = now.timeIntervalSince(last)
        guard elapsed > 0 else { return NetworkUsage() }

        var down: Double = 0
        var up: Double = 0
        var best: (String, Double)?

        for (name, counters) in current where !Self.ignored.contains(name) {
            guard let old = previous[name] else { continue }
            // ifi_ibytes/ifi_obytes sont des compteurs 32 bits qui rebouclent :
            // la soustraction non saturante gère le passage 2^32 -> 0.
            let deltaDown = Double(counters.rx &- old.rx)
            let deltaUp = Double(counters.tx &- old.tx)
            down += deltaDown
            up += deltaUp
            let total = deltaDown + deltaUp
            if total > 0, best == nil || total > best!.1 {
                best = (name, total)
            }
        }

        previous = current
        lastTimestamp = now
        return NetworkUsage(
            downloadPerSecond: down / elapsed,
            uploadPerSecond: up / elapsed,
            activeInterface: best?.0
        )
    }
}

// MARK: - Batterie

public struct BatteryReader: Sendable {
    public init() {}

    public func read() -> BatteryStatus {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let description = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any]
        else {
            return BatteryStatus()
        }

        let level = description[kIOPSCurrentCapacityKey as String] as? Int ?? 0
        let charging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let plugged = description[kIOPSPowerSourceStateKey as String] as? String == kIOPSACPowerValue

        var remaining: Int?
        if charging {
            if let full = description[kIOPSIsFinishingChargeKey as String] as? Bool, full {
                remaining = nil
            } else {
                remaining = description["Time to Full Charge" as String] as? Int  // kIOPSTimeToFullChargeKey
            }
        } else {
            remaining = description[kIOPSTimeToEmptyKey as String] as? Int
        }

        return BatteryStatus(
            level: level,
            isCharging: charging,
            isPlugged: plugged,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            timeRemainingMinutes: (remaining ?? 0) > 0 ? remaining : nil,
            temperature: nil,
            cycleCount: nil,
            healthPercent: nil,
            isPresent: true,
            notChargingReason: self.notChargingReason()
        )
    }

    /// `AppleSmartBattery.ChargerData.NotChargingReason`.
    ///
    /// Ce champ n'est **pas** dans la description IOPS : il faut aller le
    /// chercher dans l'IORegistry. La référence IOKit est relâchée avant
    /// de rendre la main — la conserver au-delà de l'appel est inutile et
    /// invite aux invalides d'usage.
    private func notChargingReason() -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("AppleSmartBattery"),
                                          &iterator) == kIOReturnSuccess else { return 0 }
        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return 0 }
        defer { IOObjectRelease(service) }

        guard let data = IORegistryEntryCreateCFProperty(service, "ChargerData" as CFString,
                                                         kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [String: Any]
        else { return 0 }
        return data["NotChargingReason"] as? Int ?? 0
    }
}

// MARK: - GPU

public final class GPUReader: @unchecked Sendable {
    private var cached: GPUUsage = GPUUsage()
    public init() {}

    public func read() -> GPUUsage {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"),
                                          &iterator) == kIOReturnSuccess
        else { return cached }
        defer { IOObjectRelease(iterator) }

        // Sur Apple Silicon il n'y a qu'un accélérateur (intégré) : on garde
        // celui qui expose le plus de métriques.
        var best: GPUUsage?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = ioProperty(service, "PerformanceStatistics") as? [String: Any] else { continue }

            var usage = GPUUsage()
            usage.deviceUtilization = stats["Device Utilization %"] as? Int ?? 0
            usage.rendererUtilization = stats["Renderer Utilization %"] as? Int ?? 0
            usage.tilerUtilization = stats["Tiler Utilization %"] as? Int ?? 0
            usage.inUseMemory = Double(stats["In use system memory"] as? Int ?? 0)
            if best == nil || usage.deviceUtilization > best!.deviceUtilization {
                best = usage
            }
        }

        if var best {
            // Le modèle et le nombre de cœurs ne changent pas : on ne les
            // relit qu'une fois, pour éviter un parcours IORegistry inutile.
            if cached.model.isEmpty {
                best.model = discoverModel()
                best.coreCount = discoverCoreCount()
            } else {
                best.model = cached.model
                best.coreCount = cached.coreCount
            }
            cached = best
        }
        return cached
    }

    private func discoverModel() -> String {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"),
                                          &iterator) == kIOReturnSuccess else { return "GPU" }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let model = ioProperty(service, "model") as? String, !model.isEmpty {
                return model
            }
        }
        return "GPU"
    }

    private func discoverCoreCount() -> Int {
        var iterator: io_iterator_t = 0
        defer { IOObjectRelease(iterator) }
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("IOAccelerator"),
                                          &iterator) == kIOReturnSuccess else { return 0 }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let count = ioProperty(service, "gpu-core-count") as? Int, count > 0 {
                return count
            }
        }
        return 0
    }
}

// MARK: - Températures

/// Lecture des capteurs thermiques via `IOHIDEventSystemClient`.
///
/// Sur les Mac Apple Silicon récents, les seuls capteurs exposés sont
/// nommés `PMU tdie<N>` et `PMU2 tdie<N>` : ce sont des points de mesure
/// répartis sur le die du SoC, **pas** un capteur CPU et un capteur GPU.
/// Apple ne publie aucun correspondance entre ces points et les clusters
/// CPU/GPU — mesuré sur ce M5, les 24 points réagissent de façon
/// indifférenciée à une charge CPU comme à une charge GPU.
///
/// On remonte donc la moyenne et le pic du die, ce qui est honnête, plutôt
/// que d'attribuer artificiellement une température à un cœur.
public final class TemperatureReader: @unchecked Sendable {

    // Le client et le tableau de services restent en vie pendant toute la
    // durée de la lecture. C'est indispensable : les éléments du CFArray ne
    // sont valides que tant que le tableau l'est, et lire un pointeur de
    // service après la disparition du tableau est un use-after-free — c'est
    // ce qui produisait `_os_unfair_lock_corruption_abort` au second tick.
    private var client: Unmanaged<HIDClient>?
    private var servicesArray: Unmanaged<CFTypeRef>?
    /// Indices, dans `servicesArray`, des services retenus comme capteurs
    /// thermiques. Indispensable de les mémoriser : le tableau contient aussi
    /// des services sans rapport, dont on ne garde pas le nom.
    private var matchedIndices: [Int] = []
    private var names: [String] = []
    private var lastRead: Date?

    public init() {
        discover()
    }

    deinit {
        // Libération explicite : ces références ont été obtenues en +1 et ne
        // sont pas gérées par ARC.
        servicesArray?.release()
        client?.release()
    }

    private func discover() {
        releaseResources()

        guard let owned = hidClientCreate(kCFAllocatorDefault) else { return }
        client = owned
        let raw = owned.takeUnretainedValue()

        let match: NSDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005]
        _ = hidClientSetMatching(raw, match as CFDictionary)

        guard let ownedArray = hidClientCopyServices(raw) else { return }
        servicesArray = ownedArray

        // `CopyServices` renvoie un `CFArray` : le pont vers `NSArray` ne peut pas
        // échouer, mais on ne le suppose pas — un `guard` coûte deux lignes et
        // évite un plantage si le type change d'une version de SDK à l'autre.
        guard let array = ownedArray.takeUnretainedValue() as? NSArray else { return }
        var foundIndices: [Int] = []
        var foundNames: [String] = []
        for index in 0..<array.count {
            let service = array[index] as CFTypeRef
            guard let owned = hidServiceCopyProperty(service, "Product" as CFString) else { continue }
            // Consomme le +1 : la chaîne ne doit pas être laissée à ARC, qui
            // la libérerait une seconde fois.
            let name = owned.takeRetainedValue() as? String
            guard let name, name.hasPrefix("PMU"), name.contains("tdie") else { continue }
            foundIndices.append(index)
            foundNames.append(name)
        }
        matchedIndices = foundIndices
        names = foundNames
    }

    private func releaseResources() {
        servicesArray?.release()
        servicesArray = nil
        client?.release()
        client = nil
        matchedIndices = []
        names = []
    }

    public func read() -> Temperature {
        // Le client HID doit être recréé : les services become invalides
        // après un certain temps, et Apple ne documente pas la durée.
        if let last = lastRead, Date().timeIntervalSince(last) > 60 {
            discover()
        }
        lastRead = Date()

        guard let array = servicesArray?.takeUnretainedValue() as? NSArray else {
            return Temperature()
        }

        var values: [(String, Double)] = []
        for (position, arrayIndex) in matchedIndices.enumerated() where position < names.count {
            let service = array[arrayIndex] as CFTypeRef
            guard let ownedEvent = hidServiceCopyEvent(service,
                                                        kHIDEventTypeTemperature,
                                                        0,
                                                        0) else { continue }
            // `ownedEvent` est +1 : `takeUnretainedValue` lit la valeur sans
            // consommer, `takeRetainedValue` consomme et libère. Les deux
            // dans cet ordre — sinon l'événement est libéré trop tôt.
            let event = ownedEvent.takeUnretainedValue()
            let celsius = hidEventFloatValue(event, kHIDEventFieldTemperatureBase)
            // On ignore volontairement la valeur : l'appel ne sert qu'à
            // consommer la référence +1 et la libérer.
            _ = ownedEvent.takeRetainedValue()

            // Certains capteurs rapportent des valeurs aberrantes au repos.
            guard celsius > 5, celsius < 120 else { continue }
            values.append((names[position], celsius))
        }

        guard !values.isEmpty else { return Temperature() }
        let total = values.reduce(0.0) { $0 + $1.1 }
        return Temperature(
            socAverage: total / Double(values.count),
            socPeak: values.map(\.1).max(),
            dieCount: values.count,
            sensorNames: names,
            sensors: values.sorted { $0.1 > $1.1 }
        )
    }
}

// MARK: - Agrégateur

public final class MetricsCollector: @unchecked Sendable {
    private let cpu = CPUReader()
    private let memory = MemoryReader()
    private let network = NetworkReader()
    private let battery = BatteryReader()
    private let gpu = GPUReader()
    private let temperature = TemperatureReader()

    public init() {}

    public var coreCount: Int { cpu.coreCount }

    public func read() -> Snapshot {
        Snapshot(
            cpu: cpu.read(),
            memory: memory.read(),
            network: network.read(),
            battery: battery.read(),
            gpu: gpu.read(),
            temperature: temperature.read(),
            date: Date()
        )
    }
}
