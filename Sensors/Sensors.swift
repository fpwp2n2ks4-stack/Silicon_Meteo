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
    /// L'échelle est donc **logarithmique** : un transfert de fichier produit
    /// un pic, pas un niveau de charge, et une échelle linéaire l'étalerait
    /// sur toute la hauteur.
    ///
    /// `GaugeColor.load` bascule à 0,60 puis 0,80 : l'échelle place donc le
    /// vert sous ≈ 1,48 Mo/s et le jaune sous ≈ 3,88 Mo/s, seuils que l'on
    /// peut lire directement dans la formule ci-dessous.
    ///
    /// - Parameter bytesPerSecond: le plus élevé des deux débits, mesuré sur
    ///   l'interface active — une jauge ne montre pas le trafic cumulé de
    ///   toutes les interfaces, qui n'a aucun sens.
    public static func loadFraction(bytesPerSecond: Double) -> Double {
        guard bytesPerSecond > 0 else { return 0 }
        let normalized = log10(1 + bytesPerSecond / 100_000) / 2
        return min(1, max(0, normalized))
    }
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
    public var isPresent: Bool = false
    // swiftlint:enable implicit_optional_initialization

    /// Motif pour lequel macOS refuse de charger (`ChargerData.NotChargingReason`).
    public var notChargingReason: Int = 0

    // MARK: Détails matériels (`AppleSmartBattery`)
    //
    // Lus dans l'IORegistry et non dans la description IOPS : la santé, les
    // cycles, les capacités et la tension/courant n'y figurent pas. Ils
    // viennent du même service que `ChargerData`, donc d'un seul accès.

    /// Santé en pourcentage : capacité maximale actuelle rapportée à la
    /// capacité d'origine. Plafonnée à 100, comme Statistiques système.
    public var health: Int = 0
    /// Nombre de cycles de charge.
    public var cycles: Int = 0
    /// Capacité maximale actuelle, en mAh.
    public var maxCapacityMah: Int = 0
    /// Capacité d'origine (conçue), en mAh.
    public var designCapacityMah: Int = 0
    /// Tension de la batterie, en volts.
    public var voltage: Double = 0
    /// Courant de la batterie, en milliampères. **Signé** : négatif en
    /// décharge (relevé à `-376` sur cette machine au repos, débranchée).
    public var amperage: Double = 0
    /// Puissance nominale du chargeur, en watts. Vaut 0 quand aucun
    /// adaptateur n'est branché : IOPS ne renvoie alors rien.
    public var adapterWatts: Int = 0
    /// Tension négociée de l'adaptateur, en volts. 0 si non branché.
    public var adapterVoltage: Double = 0

    /// Puissance instantanée de la batterie, en watts.
    ///
    /// Dérivée des deux mesures brutes du contrôleur (`voltage` × `amperage`),
    /// comme Stats. On n'utilise **pas** la clé SMC `PPBR` : elle exige le
    /// helper privilégié de Stats, que Toasty n'a pas.
    public var power: Double { voltage * amperage / 1000 }

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
}

/// Charge d'un processus, telle qu'affichée dans la liste des plus gourmands.
public struct ProcessUsage: Sendable {
    public var name: String = ""
    /// Identifiant du processus (`pid_t`). Affiché à côté du nom pour
    /// distinguer deux processus homonymes — plusieurs « Google Chrome
    /// Helper » partagent le même nom, seul le PID les sépare.
    public var pid: Int32 = 0
    /// Charge CPU en pourcentage. Peut dépasser 100 : comme Activity Monitor,
    /// on **somme** le temps de tous les threads du processus.
    public var cpu: Double = 0
    /// Mémoire résidente (RSS) en octets — `pti_resident_size`.
    public var memory: Double = 0
}

/// Occupation et activité du disque de démarrage.
///
/// Trois sources, trois cadences. L'occupation (`statfs`) et l'activité
/// (compteurs IOKit) sont bon marché et relues à chaque tick ; le SMART NVMe
/// envoie une commande administrative au contrôleur, donc il est confié à un
/// lecteur séparé qui met son résultat en cache (`DiskSmartReader`).
public struct DiskUsage: Sendable {
    /// Faux si le volume racine n'a pas pu être lu : la section est masquée.
    public var isPresent: Bool = false
    /// Espace occupé et capacité totale du volume racine, en octets.
    public var used: Double = 0
    public var total: Double = 0
    public var free: Double = 0
    /// Type du système de fichiers du volume racine (« APFS »…).
    public var fileSystem: String = ""

    /// Débit lecture/écriture, en octets par seconde. Somme des disques
    /// physiques ; les images disque montées sont écartées.
    public var readPerSecond: Double = 0
    public var writePerSecond: Double = 0

    /// Température du SSD en °C, si le SMART est lisible.
    public var smartTemperature: Double? = nil
    /// Santé du SSD en pourcentage (100 = neuf), si lisible.
    public var smartHealth: Int? = nil

    public var fraction: Double { total > 0 ? used / total : 0 }
}

public struct Snapshot {
    public var cpu: CPUUsage = CPUUsage()
    public var memory: MemoryUsage = MemoryUsage()
    public var network: NetworkUsage = NetworkUsage()
    public var disk: DiskUsage = DiskUsage()
    public var battery: BatteryStatus = BatteryStatus()
    public var gpu: GPUUsage = GPUUsage()
    public var temperature: Temperature = Temperature()
    public var processes: [ProcessUsage] = []
    public var bluetooth: [BluetoothDevice] = []
    public var date: Date = Date()
}

// MARK: - Utilitaires

private func ioProperty(_ service: io_object_t, _ key: String) -> AnyObject? {
    guard let ref = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    return ref.takeRetainedValue()
}

/// Un `CFNumber` de l'IORegistry se pont vers `NSNumber` quel que soit son
/// type sous-jacent (`SInt64`, `Double`…). Passer par `NSNumber` évite de
/// supposer lequel : `Voltage` arrive parfois signé, parfois flottant selon
/// la machine, et un `as? Int` trop strict rendrait alors `nil`.
private func intValue(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
}

private func doubleValue(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
}

/// Toutes les propriétés d'une entrée IORegistry, en une seule ouverture.
private func ioRegistryProperties(_ service: io_object_t) -> [String: Any]? {
    var reference: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &reference,
                                            kCFAllocatorDefault, 0) == kIOReturnSuccess,
          let dictionary = reference?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return dictionary
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
            wired: wired
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
        // Une seule ouverture du service pour toutes les valeurs IORegistry
        // (motif de non-charge, santé, cycles, capacités, tension/courant,
        // adaptateur) : l'ancienne version ouvrait le service juste pour
        // `NotChargingReason`, ce qui doublait les accès.
        let hardware = smartBatteryProperties()

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

        // --- Détails matériels ---
        let batteryData = hardware["BatteryData"] as? [String: Any]
        let chargerData = hardware["ChargerData"] as? [String: Any]

        let design = intValue(hardware["DesignCapacity"])
            ?? intValue(batteryData?["DesignCapacity"])
            ?? 0
        // Sur Apple Silicon, `MaxCapacity` vaut 100 (un pourcentage) : la
        // capacité réelle est dans `AppleRawMaxCapacity`, à défaut dans
        // `BatteryData`. On préfère ensuite `FullChargeCapacity` (capacité
        // réellement mesurée à pleine charge) à `NominalChargeCapacity`
        // (valeur nominale, qui peut dépasser la capacité de conception et
        // gonfler artificiellement la santé). Stats fait l'inverse ; ce choix
        // rend la santé plus fidèle à l'usure réelle.
        let maximum = intValue(hardware["AppleRawMaxCapacity"])
            ?? intValue(batteryData?["FullChargeCapacity"])
            ?? intValue(batteryData?["NominalChargeCapacity"])
            ?? 0
        let health = design > 0
            ? min(100, Int((100.0 * Double(maximum) / Double(design)).rounded()))
            : 0

        // L'adaptateur n'est décrit par IOPS que lorsqu'il est branché.
        let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any]
        let adapterDetails = hardware["AdapterDetails"] as? [String: Any]
        let adapterWatts = intValue(adapter?["Watts"])
            ?? intValue(adapterDetails?["Watts"])
            ?? 0
        let adapterVoltage = plugged
            ? Double(intValue(adapterDetails?["AdapterVoltage"]) ?? 0) / 1000
            : 0

        return BatteryStatus(
            level: level,
            isCharging: charging,
            isPlugged: plugged,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            timeRemainingMinutes: (remaining ?? 0) > 0 ? remaining : nil,
            isPresent: true,
            notChargingReason: intValue(chargerData?["NotChargingReason"]) ?? 0,
            health: health,
            cycles: intValue(hardware["CycleCount"]) ?? 0,
            maxCapacityMah: maximum,
            designCapacityMah: design,
            voltage: (doubleValue(hardware["Voltage"]) ?? 0) / 1000,
            amperage: doubleValue(hardware["Amperage"]) ?? 0,
            adapterWatts: adapterWatts,
            adapterVoltage: adapterVoltage
        )
    }

    /// Toutes les propriétés de l'`AppleSmartBattery`, en un seul accès.
    ///
    /// `ChargerData` (motif de non-charge), `BatteryData` (capacités) et
    /// `AdapterDetails` (adaptateur) sont des dictionnaires imbriqués : les
    /// extraire séparément multiplierait les ouvertures du service. La
    /// référence IOKit est relâchée avant de rendre la main — la conserver
    /// au-delà de l'appel invite aux invalides d'usage.
    private func smartBatteryProperties() -> [String: Any] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                          IOServiceMatching("AppleSmartBattery"),
                                          &iterator) == kIOReturnSuccess else { return [:] }
        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard service != 0 else { return [:] }
        defer { IOObjectRelease(service) }

        var reference: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &reference,
                                                kCFAllocatorDefault, 0) == kIOReturnSuccess,
              let dictionary = reference?.takeRetainedValue() as? [String: Any]
        else { return [:] }
        return dictionary
    }
}

// MARK: - Bluetooth

/// Un niveau de charge rattaché à un périphérique Bluetooth.
///
/// Un casque peut exposer plusieurs valeurs : `left`, `right` et `case`.
/// `battery` désigne une valeur unique (souris, clavier…).
public struct BluetoothComponent: Sendable {
    public var kind: String        // "battery" | "left" | "right" | "case"
    public var level: Int          // 0...100
    public var isCharging: Bool

    public init(kind: String, level: Int, isCharging: Bool = false) {
        self.kind = kind
        self.level = level
        self.isCharging = isCharging
    }
}

public struct BluetoothDevice: Sendable {
    public var name: String
    public var components: [BluetoothComponent]

    public init(name: String, components: [BluetoothComponent]) {
        self.name = name
        self.components = components
    }
}

/// Niveaux de charge des accessoires Bluetooth (AirPods, souris, casques…).
///
/// ## Pourquoi `pmset`, et pas CoreBluetooth
///
/// Ces valeurs ne sont **pas** dans `IOPSCopyPowerSourcesInfo` : mesuré sur
/// cette machine, il ne renvoie que la batterie interne. CoreBluetooth, lui,
/// exige une autorisation TCC (`NSBluetoothAlwaysUsageDescription`) et un
/// balayage actif ; Toasty n'a ni l'un ni l'autre.
///
/// `pmset -g accps -xml` est le même service que celui qui alimente
/// l'indicateur de batterie des accessoires dans la barre de menus de macOS.
/// Il est bon marché (~15 ms) et ne demande aucun privilège. On le met en
/// cache : les niveaux des accessoires bougent lentement, inutile de lancer
/// un sous-processus toutes les 2 s.
///
/// Limite assumée : seuls les accessoires dont macOS connaît la batterie
/// apparaissent. Un périphérique sans niveau exposé est simplement absent.
public final class BluetoothReader: @unchecked Sendable {
    private var cached: (date: Date, devices: [BluetoothDevice])?
    private let timeToLive: TimeInterval = 20

    public init() {}

    public func read() -> [BluetoothDevice] {
        if let cached, Date().timeIntervalSince(cached.date) < timeToLive {
            return cached.devices
        }
        let devices = Self.collect()
        cached = (Date(), devices)
        return devices
    }

    private static func collect() -> [BluetoothDevice] {
        guard let output = accessoryPowerSources() else { return [] }

        var groups: [String: [[String: Any]]] = [:]
        var standalone: [[String: Any]] = []
        for entry in powerSourcePlistEntries(output) {
            // Le bloc « batterie interne » n'est pas un accessoire : il est
            // déjà lu par `BatteryReader`. Seuls les accessoires nous
            // intéressent.
            guard entry["Type"] as? String == "Accessory Source" else { continue }
            if let group = entry["Group Identifier"] as? String {
                groups[group, default: []].append(entry)
            } else {
                standalone.append(entry)
            }
        }

        var devices = standalone.compactMap(device(from:))
        for entries in groups.values {
            if let device = device(fromGroup: entries) { devices.append(device) }
        }
        return devices.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Périphérique dont les niveaux tiennent en une seule entrée.
    private static func device(from entry: [String: Any]) -> BluetoothDevice? {
        guard let name = entry["Name"] as? String else { return nil }
        let kind = (entry["Part Identifier"] as? String)?.lowercased() ?? "battery"
        guard let component = component(from: entry, kind: kind) else { return nil }
        return BluetoothDevice(name: name, components: [component])
    }

    /// Périphérique décrit par plusieurs entrées partageant un
    /// `Group Identifier` : un casque expose ses deux oreillettes (et son
    /// boîtier) comme autant de sources séparées.
    private static func device(fromGroup entries: [[String: Any]]) -> BluetoothDevice? {
        let combined = entries.first { $0["Part Identifier"] as? String == "Combined" }
        let caseEntry = entries.first { $0["Part Identifier"] as? String == "Case" }
        // `Combined` porte le nom « propre » ; le boîtier s'appelle par
        // exemple « Boîtier AirPods de Yves ».
        let name = combined?["Name"] as? String
            ?? entries.first { $0["Part Identifier"] as? String != "Case" }?["Name"] as? String
            ?? entries.first?["Name"] as? String
            ?? ""

        var components: [BluetoothComponent] = []
        for part in combined?["Combined Parts"] as? [[String: Any]] ?? [] {
            guard let kind = (part["Part Identifier"] as? String)?.lowercased(),
                  let component = component(from: part, kind: kind)
            else { continue }
            components.append(component)
        }
        if let caseEntry, let component = component(from: caseEntry, kind: "case") {
            components.append(component)
        }
        if components.isEmpty,
           let single = combined ?? entries.first,
           let component = component(from: single, kind: "battery") {
            components.append(component)
        }

        guard !components.isEmpty else { return nil }
        return BluetoothDevice(name: name, components: components)
    }

    private static func component(from entry: [String: Any], kind: String) -> BluetoothComponent? {
        guard let level = intValue(entry["Current Capacity"]) else { return nil }
        let charging = entry["Is Charging"] as? Bool ?? false
        return BluetoothComponent(kind: kind, level: level, isCharging: charging)
    }

    /// Décode la sortie de `pmset -g accps -xml`.
    ///
    /// `pmset` imprime **plusieurs** plists à la suite, un par source
    /// d'alimentation, chacun précédé de sa déclaration `<?xml`. On découpe
    /// donc sur ce marqueur, puis on limite chaque fragment à son `</plist>`
    /// — sinon les quelques octets qui suivent (retour à la ligne, prochaine
    /// déclaration) gêneraient l'analyseur.
    private static func powerSourcePlistEntries(_ output: String) -> [[String: Any]] {
        var entries: [[String: Any]] = []
        for fragment in output.components(separatedBy: "<?xml").dropFirst() {
            guard let end = fragment.range(of: "</plist>") else { continue }
            let xml = "<?xml" + fragment[fragment.startIndex..<end.upperBound]
            guard let data = xml.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any]
            else { continue }
            entries.append(dictionary)
        }
        return entries
    }

    /// Exécute `pmset -g accps -xml` et renvoie sa sortie standard.
    private static func accessoryPowerSources() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "accps", "-xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Lire jusqu'à EOF **avant** d'attendre la fin évite tout blocage si
        // la sortie dépassait la taille du tampon du pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
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
            usage.inUseMemory = Double(stats["In use system memory"] as? Int ?? 0)
            if best == nil || usage.deviceUtilization > best!.deviceUtilization {
                best = usage
            }
        }

        if let best { cached = best }
        return cached
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
        for index in 0..<array.count {
            let service = array[index] as CFTypeRef
            guard let owned = hidServiceCopyProperty(service, "Product" as CFString) else { continue }
            // Consomme le +1 : la chaîne ne doit pas être laissée à ARC, qui
            // la libérerait une seconde fois.
            let name = owned.takeRetainedValue() as? String
            guard let name, name.hasPrefix("PMU"), name.contains("tdie") else { continue }
            foundIndices.append(index)
        }
        matchedIndices = foundIndices
    }

    private func releaseResources() {
        servicesArray?.release()
        servicesArray = nil
        client?.release()
        client = nil
        matchedIndices = []
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

        var values: [Double] = []
        for arrayIndex in matchedIndices {
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
            values.append(celsius)
        }

        guard !values.isEmpty else { return Temperature() }
        let total = values.reduce(0) { $0 + $1 }
        return Temperature(
            socAverage: total / Double(values.count),
            socPeak: values.max(),
            dieCount: values.count
        )
    }
}

// MARK: - Processus

/// Liste les processus les plus gourmands en CPU via `libproc`.
///
/// Aucun helper privilégié ni sous-processus : on interroge l'API système
/// `proc_listallpids` / `proc_pidinfo` (`PROC_PIDTASKINFO`), qui expose le
/// temps CPU **cumulé** et la mémoire résidente de chaque processus.
///
/// Le pourcentage ne se lit pas directement : c'est un **débit**, donc une
/// différence entre deux échantillons rapportée au temps réel écoulé. Le
/// collecteur appelant déjà `read()` toutes les 2 s, ce lecteur mémorise le
/// tick précédent. Au premier appel, faute de référence, tous les débits
/// valent 0 — comme `NetworkReader`.
///
/// Attention à l'unité : `pti_total_user` et `pti_total_system` sont en
/// **ticks mach** (`mach_absolute_time`), pas en nanosecondes. Un tick ne
/// vaut 1 ns que sur les Mac Intel (timebase `1/1`) ; sur Apple Silicon la
/// base vaut 24 MHz, soit `125/3 ≈ 41,67 ns` par tick. Diviser directement
/// par `1e9` sous-estimerait donc la charge d'un facteur ~41,7 sur Apple
/// Silicon. On convertit via `mach_timebase_info`, ce qui donne le même
/// résultat sur les deux architectures.
///
/// Limite assumée : les processus appartenant à un autre utilisateur, ou
/// protégés par le noyau (SIP, `kernel_task`), refusent `proc_pidinfo` et
/// sont simplement ignorés. Les déduire exigerait des privilèges qu'un
/// moniteur de barre de menus n'a pas à réclamer.
public final class ProcessReader: @unchecked Sendable {
    private struct Sample {
        var cpuTime: UInt64
        var memory: UInt64
    }
    private var previous: [Int32: Sample] = [:]
    private var lastDate: Date?

    /// Nombre de nanosecondes par tick mach, une fois pour tout le processus.
    ///
    /// `mach_timebase_info` renvoie une fraction `numer/denom` : sur Apple
    /// Silicon `125/3` (≈ 41,67 ns/tick), sur Intel `1/1` (1 ns/tick). Le
    /// résultat est calculé au premier accès, de façon paresseuse et
    /// thread-safe, puis réutilisé.
    private static let nanosecondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.denom != 0 else { return 1 }
        return Double(info.numer) / Double(info.denom)
    }()

    public init() {}

    /// Liste des PID, dimensionnée par un premier appel qui ne remplit rien.
    ///
    /// `proc_listallpids(nil, 0)` renvoie le **nombre** de PID (le wrapper
    /// libproc divise déjà la taille d'octets par `sizeof(int)`). Le second
    /// appel renvoie le nombre réellement écrit, qui peut être plus petit si
    /// des processus ont disparu entre-temps.
    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress,
                             Int32(buffer.count * MemoryLayout<pid_t>.stride))
        }
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written)))
    }

    /// Nom court du processus (`proc_name`), ou `nil` s'il n'est pas lisible.
    private static func name(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public func read(limit: Int = 5) -> [ProcessUsage] {
        let now = Date()
        let elapsed = lastDate.map { now.timeIntervalSince($0) } ?? 0

        var current: [Int32: Sample] = [:]
        var usages: [ProcessUsage] = []
        let secondsNanoseconds = 1_000_000_000.0

        for pid in Self.allPIDs() where pid > 0 {
            var info = proc_taskinfo()
            let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info,
                                    Int32(MemoryLayout<proc_taskinfo>.size))
            guard size > 0 else { continue }

            let sample = Sample(cpuTime: info.pti_total_user &+ info.pti_total_system,
                                memory: info.pti_resident_size)
            current[pid] = sample

            // Un PID réutilisé peut afficher un compteur plus petit : dans ce
            // cas la différence serait absurde, on repart de zéro.
            var cpu: Double = 0
            if elapsed > 0, let old = previous[pid], sample.cpuTime >= old.cpuTime {
                // `cpuTime` est en ticks mach : on le ramène en nanosecondes
                // avant de le rapporter au temps réel écoulé.
                let nanoseconds = Double(sample.cpuTime - old.cpuTime) * Self.nanosecondsPerTick
                cpu = nanoseconds / (elapsed * secondsNanoseconds) * 100
            }

            usages.append(ProcessUsage(name: Self.name(for: pid) ?? "pid \(pid)",
                                       pid: Int32(pid),
                                       cpu: cpu,
                                       memory: Double(sample.memory)))
        }

        previous = current
        lastDate = now

        return Array(usages
            .sorted { $0.cpu == $1.cpu ? $0.memory > $1.memory : $0.cpu > $1.cpu }
            .prefix(limit))
    }
}

// MARK: - Contrôle des processus

/// Terminaison d'un processus, exposée à l'interface.
///
/// On reste sur `kill(2)` du noyau : aucune API privilégiée, et la portée est
/// celle de l'utilisateur qui a lancé Toasty — un processus appartenant à un
/// autre utilisateur (ou protégé par SIP) refusera avec `EPERM`, que l'appelant
/// traduit en message.
public enum ProcessControl {

    /// Le PID peut-il être terminé par cette application ?
    ///
    /// On refuse le noyau (`pid 0`, exposé comme `kernel_task`), `launchd`
    /// (`pid 1`) et Toasty elle-même : les trois feraient tomber la session ou
    /// l'application. La vérification est faite **avant** d'afficher le bouton,
    /// pour que l'affordance corresponde à ce qui est réellement possible.
    public static func canTerminate(_ pid: Int32) -> Bool {
        pid > 1 && pid != getpid()
    }

    /// Envoie `SIGTERM` au processus. Renvoie `true` si le noyau a accepté.
    ///
    /// `SIGTERM` (et non `SIGKILL`) laisse au processus le temps de fermer
    /// proprement ses fichiers et ses connexions. Un échec (`EPERM` pour un
    /// processus protégé, `ESRCH` s'il vient de quitter) est signalé par
    /// `false`, sans lever d'exception.
    @discardableResult
    public static func terminate(_ pid: Int32) -> Bool {
        canTerminate(pid) && kill(pid, SIGTERM) == 0
    }
}

// MARK: - Disque

/// Occupation du volume racine, via `statfs(2)`.
///
/// On lit `/` plutôt qu'un chemin arbitraire : c'est le volume qui porte le
/// système et, sur un Mac, celui qui compte. `f_bavail` (et non `f_bfree`)
/// donne l'espace réellement utilisable par l'utilisateur, celui que le
/// Finder affiche.
private enum DiskCapacity {
    static func read() -> (used: Double, total: Double, free: Double, fileSystem: String) {
        var info = statfs()
        guard statfs("/", &info) == 0 else { return (0, 0, 0, "") }

        let blockSize = Double(info.f_bsize)
        let total = Double(info.f_blocks) * blockSize
        let available = Double(info.f_bavail) * blockSize
        let used = max(0, total - available)

        // `f_fstypename` est un tableau C de longueur fixe : on le relit comme
        // une chaîne terminée par NUL. « apfs » devient « APFS » pour la même
        // raison que « SSD » : les sigles se lisent en majuscules.
        let fileSystem = withUnsafeBytes(of: info.f_fstypename) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }.uppercased()

        return (used, total, available, fileSystem)
    }
}

/// Débit disque, d'après les compteurs cumulés de `IOBlockStorageDriver`.
///
/// IOKit expose, pour chaque disque physique, un dictionnaire `Statistics`
/// contenant les octets lus/écrits depuis le démarrage. Comme pour le réseau,
/// le débit est une **différence** entre deux relevés rapportée au temps
/// écoulé : un compteur seul ne dit rien d'un débit.
///
/// Les images disque (DMG, sparse bundles) sont écartées : ce sont des
/// fichiers, pas des écritures physiques, et elles gonfleraient un débit qui
/// ne correspond à aucun disque réel.
public final class DiskActivityReader: @unchecked Sendable {
    private var previous: (read: Double, write: Double)?
    private var lastTimestamp: Date?

    public init() {}

    public func read() -> (read: Double, write: Double) {
        guard let counters = Self.counters() else { return (0, 0) }
        let now = Date()
        guard let last = lastTimestamp, let old = previous else {
            previous = counters
            lastTimestamp = now
            return (0, 0)
        }
        let elapsed = now.timeIntervalSince(last)
        previous = counters
        lastTimestamp = now
        guard elapsed > 0 else { return (0, 0) }

        // Un compteur qui recule (disque retiré/rebranché) donnerait une
        // différence absurde : on repart de zéro pour ce relevé.
        let read = counters.read >= old.read ? (counters.read - old.read) / elapsed : 0
        let write = counters.write >= old.write ? (counters.write - old.write) / elapsed : 0
        return (read, write)
    }

    private static func counters() -> (read: Double, write: Double)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iterator) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var read: Double = 0
        var write: Double = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard !isDiskImage(service) else { continue }
            guard let properties = ioRegistryProperties(service),
                  let statistics = properties["Statistics"] as? [String: Any]
            else { continue }
            read += doubleValue(statistics["Bytes (Read)"]) ?? 0
            write += doubleValue(statistics["Bytes (Write)"]) ?? 0
        }
        return (read, write)
    }

    /// Vrai si le service appartient à une image disque montée.
    ///
    /// Les images disque sont portées par `IOHDIXController` / `IOHDIXHDDrive`.
    /// On remonte la chaîne des parents : leur `IOBlockStorageDriver` éventuel
    /// ne doit pas compter comme de l'activité physique.
    private static func isDiskImage(_ service: io_object_t) -> Bool {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }

        for _ in 0..<12 {
            var buffer = [CChar](repeating: 0, count: 128)
            if IORegistryEntryGetName(current, &buffer) == KERN_SUCCESS,
               String(cString: buffer).localizedCaseInsensitiveContains("HDIX") {
                return true
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return false
            }
            IOObjectRelease(current)
            current = parent
        }
        return false
    }
}

// MARK: - SMART NVMe
//
// `IOKit/storage/IONVMeSMARTLib.h` n'est pas exposé au module Swift : on
// déclare donc à la main les identifiants d'interface et la disposition des
// deux structures COM (`IOCFPlugInInterface`, `IONVMeSMARTInterface`), comme
// Toasty le fait déjà pour IOHID. Aucun privilège requis : la page de log
// SMART est maintenue par le contrôleur et se lit comme n'importe quel accès
// IOKit.

/// `IUNKNOWN_C_GUTS` : les quatre premiers membres d'une interface COM IOKit.
private typealias IOQueryInterface =
    @convention(c) (UnsafeMutableRawPointer?, CFUUIDBytes, UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> kern_return_t
private typealias IOAddRefRelease = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

private struct IOCFPlugInInterface {
    var reserved: UnsafeMutableRawPointer?
    var queryInterface: IOQueryInterface?
    var addRef: IOAddRefRelease?
    var release: IOAddRefRelease?
    var probe: (@convention(c) (UnsafeMutableRawPointer?, CFDictionary?, io_service_t, UnsafeMutablePointer<Int32>?) -> kern_return_t)?
    var start: (@convention(c) (UnsafeMutableRawPointer?, CFDictionary?, io_service_t) -> kern_return_t)?
    var stop: (@convention(c) (UnsafeMutableRawPointer?) -> kern_return_t)?
}

private struct IONVMeSMARTInterface {
    var reserved: UnsafeMutableRawPointer?
    var queryInterface: IOQueryInterface?
    var addRef: IOAddRefRelease?
    var release: IOAddRefRelease?
    var version: UInt16 = 0
    var revision: UInt16 = 0
    var smartReadData: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> kern_return_t)?
}

private let nvmeSMARTUserClientTypeID: CFUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
    0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F
)!

private let nvmeSMARTInterfaceID: CFUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
    0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6
)!

private let cfPlugInInterfaceID: CFUUID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
    0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F
)!

@_silgen_name("IOCreatePlugInInterfaceForService")
private func ioCreatePlugInInterface(
    _ service: io_service_t,
    _ pluginType: CFUUID,
    _ interfaceType: CFUUID,
    _ theInterface: UnsafeMutableRawPointer?,
    _ theScore: UnsafeMutablePointer<Int32>?
) -> kern_return_t

@_silgen_name("IODestroyPlugInInterface")
private func ioDestroyPlugInInterface(_ interface: UnsafeMutableRawPointer?) -> kern_return_t

/// Santé du SSD lue dans la page de log SMART NVMe.
///
/// Cf. la norme NVMe, « SMART / Health Information Log » (identifiant 0x02) :
/// température en kelvins sur deux octets, pourcentage d'usure au 6ᵉ. On lit
/// dans un tampon brut de 512 octets plutôt que de redéclarer toute la
/// structure — la disposition ne nous intéresse qu'en ces deux points.
///
/// Coût : la lecture envoie une commande administrative au contrôleur, d'où
/// le cache. La température et la santé évoluent lentement.
public final class DiskSmartReader: @unchecked Sendable {
    public typealias Reading = (temperature: Double?, health: Int?)

    /// Cadence de rafraîchissement : le SMART bouge sur des heures, pas des
    /// secondes. 60 s est déjà généreux.
    private let timeToLive: TimeInterval = 60
    /// On ne paie pas la commande NVMe sur les premiers ticks, au démarrage :
    /// le panneau a le temps de s'afficher avant que la santé n'apparaisse.
    private let startupDelay: TimeInterval = 10
    private let startedAt = Date()

    private var cached: Reading?
    private var lastRead: Date?

    public init() {}

    public func read() -> Reading? {
        let now = Date()
        if let lastRead, now.timeIntervalSince(lastRead) < timeToLive {
            return cached
        }
        if now.timeIntervalSince(startedAt) < startupDelay {
            return cached
        }
        lastRead = now
        // Un échec ponctuel ne doit pas effacer une valeur déjà connue.
        if let reading = Self.collect() {
            cached = reading
        }
        return cached
    }

    private static func collect() -> Reading? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let device = IOIteratorNext(iterator), device != 0 {
            defer { IOObjectRelease(device) }
            guard (ioProperty(device, "NVMe SMART Capable") as? Bool) == true else { continue }
            guard let log = smartLog(for: device), log.count >= 6 else { continue }
            return Reading(temperature: temperature(from: log), health: health(from: log))
        }
        return nil
    }

    /// Température du die du SSD, en °C. Le contrôleur la stocke en kelvins
    /// aux octets 1-2, petit-boutiste (`critical_warning` occupe l'octet 0) ;
    /// une valeur sous 273 K signale un capteur muet.
    private static func temperature(from log: [UInt8]) -> Double? {
        let kelvin = UInt16(log[1]) | (UInt16(log[2]) << 8)
        guard kelvin > 273 else { return nil }
        return Double(kelvin - 273)
    }

    /// Santé en pourcentage : 100 moins le pourcentage de vie consommée.
    private static func health(from log: [UInt8]) -> Int? {
        let used = Int(log[5])
        guard used <= 100 else { return nil }
        return 100 - used
    }

    /// Ouvre l'interface SMART et lit la page de log dans un tampon de 512 o.
    private static func smartLog(for device: io_service_t) -> [UInt8]? {
        var plugInPointer: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let created = withUnsafeMutablePointer(to: &plugInPointer) { pointer in
            ioCreatePlugInInterface(device, nvmeSMARTUserClientTypeID, cfPlugInInterfaceID,
                                    UnsafeMutableRawPointer(pointer), &score)
        }
        guard created == kIOReturnSuccess,
              let plugIn = plugInPointer,
              let interface = plugIn.pointee
        else { return nil }
        defer { _ = ioDestroyPlugInInterface(UnsafeMutableRawPointer(plugIn)) }

        let plugInThis = UnsafeMutableRawPointer(plugIn)

        var smartPointer: UnsafeMutablePointer<UnsafeMutablePointer<IONVMeSMARTInterface>?>?
        let queried = withUnsafeMutablePointer(to: &smartPointer) { pointer in
            pointer.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) { rebound in
                interface.pointee.queryInterface?(plugInThis,
                                                  CFUUIDGetUUIDBytes(nvmeSMARTInterfaceID),
                                                  rebound)
            }
        }
        guard queried == kIOReturnSuccess,
              let smart = smartPointer?.pointee
        else { return nil }
        let smartThis = UnsafeMutableRawPointer(smartPointer!)
        defer { _ = smart.pointee.release?(smartThis) }

        var log = [UInt8](repeating: 0, count: 512)
        let result = log.withUnsafeMutableBytes { buffer in
            smart.pointee.smartReadData?(smartThis, buffer.baseAddress)
        }
        guard result == kIOReturnSuccess else { return nil }
        return log
    }
}

/// Agrège les trois sources disque en un `DiskUsage`.
public final class DiskReader: @unchecked Sendable {
    private let activity = DiskActivityReader()
    private let smart = DiskSmartReader()

    public init() {}

    public func read() -> DiskUsage {
        var usage = DiskUsage()

        let capacity = DiskCapacity.read()
        usage.isPresent = capacity.total > 0
        usage.used = capacity.used
        usage.total = capacity.total
        usage.free = capacity.free
        usage.fileSystem = capacity.fileSystem
        guard usage.isPresent else { return usage }

        let throughput = activity.read()
        usage.readPerSecond = throughput.read
        usage.writePerSecond = throughput.write

        if let reading = smart.read() {
            usage.smartTemperature = reading.temperature
            usage.smartHealth = reading.health
        }
        return usage
    }
}

// MARK: - Agrégateur

public final class MetricsCollector: @unchecked Sendable {
    private let cpu = CPUReader()
    private let memory = MemoryReader()
    private let network = NetworkReader()
    private let disk = DiskReader()
    private let battery = BatteryReader()
    private let gpu = GPUReader()
    private let temperature = TemperatureReader()
    private let process = ProcessReader()
    private let bluetooth = BluetoothReader()

    public init() {}

    public var coreCount: Int { cpu.coreCount }

    public func read() -> Snapshot {
        Snapshot(
            cpu: cpu.read(),
            memory: memory.read(),
            network: network.read(),
            disk: disk.read(),
            battery: battery.read(),
            gpu: gpu.read(),
            temperature: temperature.read(),
            processes: process.read(),
            bluetooth: bluetooth.read(),
            date: Date()
        )
    }
}
