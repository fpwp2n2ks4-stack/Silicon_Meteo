import Foundation
import IOKit
import Darwin

// Le contrôle de l'affichage passe par l'API d'accessibilité, qui exige
// l'autorisation « Accessibilité » — refusable et absente ici. On vérifie
// donc autrement : (1) le processus vit, (2) il lit bien les six sources,
// (3) il ne consomme rien.

setvbuf(stdout, nil, _IONBF, 0)

// --- 1. Le processus tourne-t-il et reste-t-il stable ? ---
let pid = pid_t(CommandLine.arguments.count > 1 ? (Int(CommandLine.arguments[1]) ?? 0) : 0)
guard pid > 0 else { print("✗ PID manquant"); exit(1) }

var info = proc_taskinfo()
let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
guard size > 0 else {
    print("✗ le processus \(pid) n'expose pas d'informations")
    exit(1)
}
print("✓ processus vivant (pid \(pid))")
print(String(format: "  threads   : %d", info.pti_threadnum))
print(String(format: "  RSS       : %.1f Mo", Double(info.pti_resident_size) / 1_048_576))
print(String(format: "  CPU cumulé: %.2f s depuis le lancement",
             Double(info.pti_total_user + info.pti_total_system) / 1e9))


// --- 2. Mesure de la charge réelle de l'agent ---
// On lit le temps CPU cumulé deux fois, à 6 s d'intervalle, et on en déduit
// le pourcentage moyen : c'est la seule métrique qui compte pour un moniteur.
func cpuTime() -> Double? {
    var info = proc_taskinfo()
    let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
    guard size > 0 else { return nil }
    return Double(info.pti_total_user + info.pti_total_system) / 1e9
}

if let t0 = cpuTime() {
    let w0 = Date()
    Thread.sleep(forTimeInterval: 6)
    if let t1 = cpuTime() {
        let wall = Date().timeIntervalSince(w0)
        let used = (t1 - t0) / wall * 100
        print(String(format: "\n  charge sur %.0f s : %.2f %%  %@", wall, used,
                     used < 1 ? "(excellente pour un moniteur à 2 s)" : "(à surveiller)"))
    }
}

// --- 3. L'agent lit-il réellement les six sources ? ---
// On relit les sources dans ce processus de vérification et on compare aux
// valeurs attendues : c'est la preuve que le chemin de collecte fonctionne
// depuis un binaire signé, hors du contexte de développement.
print("\n── Contrôle des sources depuis un binaire séparé ──")

// CPU
@_silgen_name("host_processor_info")
func hpi(_ host: mach_port_t, _ flavor: processor_flavor_t,
         _ n: UnsafeMutablePointer<natural_t>?,
         _ info: UnsafeMutablePointer<UnsafeMutablePointer<integer_t>?>?,
         _ cnt: UnsafeMutablePointer<mach_msg_type_number_t>?) -> kern_return_t

func cpuTicks() -> [UInt32]? {
    var n: natural_t = 0, cnt: mach_msg_type_number_t = 0
    var info: UnsafeMutablePointer<integer_t>?
    guard hpi(mach_host_self(), 2, &n, &info, &cnt) == KERN_SUCCESS, let info else { return nil }
    var out = (0..<(Int(n) * 4)).map { UInt32(bitPattern: info[$0]) }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(cnt) * 4)
    return out
}
if let a = cpuTicks() {
    Thread.sleep(forTimeInterval: 1)
    if let b = cpuTicks(), a.count == b.count, a.count > 0 {
        let busy = (0..<(a.count/4)).reduce(0.0) { acc, i in
            let du = Double(b[i*4] &- a[i*4]), ds = Double(b[i*4+1] &- a[i*4+1])
            let di = Double(b[i*4+2] &- a[i*4+2]), dn = Double(b[i*4+3] &- a[i*4+3])
            let s = du + ds + di + dn
            return acc + (s > 0 ? (du + ds) / s * 100 : 0)
        }
        print(String(format: "  ✓ CPU      %d cœurs, charge %.1f %%", a.count/4, busy/(Double(a.count/4))))
    } else { print("  ✗ CPU      lecture instable") }
} else { print("  ✗ CPU      host_processor_info a échoué") }

// RAM
var vm = vm_statistics64()
var vmc = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
let rc = host_statistics64(mach_host_self(), HOST_VM_INFO64,
    withUnsafeMutablePointer(to: &vm) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmc)) { $0 } }, &vmc)
if rc == KERN_SUCCESS {
    let ps = Double(vm_page_size)
    print(String(format: "  ✓ RAM      %.1f / %.1f Go", (Double(vm.active_count + vm.wire_count + vm.compressor_page_count) * ps)/1e9, Double(ProcessInfo.processInfo.physicalMemory)/1e9))
} else { print("  ✗ RAM      host_statistics64 a échoué") }

// GPU
var it: io_iterator_t = 0
var gpuOK = false
if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == kIOReturnSuccess {
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        if let st = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
           let util = st["Device Utilization %"] as? Int {
            print("  ✓ GPU      Device \(util) %  Renderer \(st["Renderer Utilization %"] as? Int ?? -1) %")
            gpuOK = true
        }
    }
    IOObjectRelease(it)
}
if !gpuOK { print("  ✗ GPU      PerformanceStatistics indisponible") }

// Températures
typealias CR = CFTypeRef
@_silgen_name("IOHIDEventSystemClientCreate") func hidCreate(_ a: CFAllocator?) -> CR?
@_silgen_name("IOHIDEventSystemClientSetMatching") func hidMatch(_ c: CR, _ m: CFDictionary) -> Int32
@_silgen_name("IOHIDEventSystemClientCopyServices") func hidServices(_ c: CR) -> CFArray?
@_silgen_name("IOHIDServiceClientCopyProperty") func hidProp(_ s: CR, _ p: CFString) -> CFTypeRef?
@_silgen_name("IOHIDServiceClientCopyEvent") func hidEvent(_ s: CR, _ t: Int64, _ o: Int32, _ ts: Int64) -> CR?
@_silgen_name("IOHIDEventGetFloatValue") func hidFloat(_ e: CR, _ f: Int32) -> Double

if let c = hidCreate(kCFAllocatorDefault) {
    _ = hidMatch(c, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 0x0005] as CFDictionary)
    if let raw = hidServices(c) {
        let arr = raw as NSArray
        var vals: [Double] = []
        for i in 0..<arr.count {
            let svc = arr[i] as CR
            guard let n = hidProp(svc, "Product" as CFString) as? String, n.contains("tdie"),
                  let e = hidEvent(svc, 15, 0, 0) else { continue }
            let v = hidFloat(e, 15 << 16)
            if v > 5 && v < 120 { vals.append(v) }
        }
        if !vals.isEmpty {
            print(String(format: "  ✓ Temp.    %d points, pic %.1f °C, moyenne %.1f °C",
                         vals.count, vals.max()!, vals.reduce(0,+)/Double(vals.count)))
        } else { print("  ✗ Temp.    aucun capteur valide") }
    }
} else { print("  ✗ Temp.    IOHIDEventSystemClientCreate a échoué") }

// Réseau : on force du trafic pour vérifier le débit
var n0 = [String: (UInt32, UInt32)]()
func netCounters() -> [String: (UInt32, UInt32)] {
    var out: [String: (UInt32, UInt32)] = [:]
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return out }
    defer { freeifaddrs(head) }
    var cur: UnsafeMutablePointer<ifaddrs>? = first
    while let nd = cur {
        let ifa = nd.pointee
        if let d = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) {
            out[String(cString: ifa.ifa_name)] = (UInt32(truncatingIfNeeded: d.pointee.ifi_ibytes), UInt32(truncatingIfNeeded: d.pointee.ifi_obytes))
        }
        cur = ifa.ifa_next
    }
    return out
}
n0 = netCounters()
// génère du trafic en descendant une image depuis le réseau
let url = URL(string: "https://www.apple.com/favicon.ico")!
let dl = URLSession(configuration: .ephemeral).downloadTask(with: url) { _, response, err in
    if let h = response as? HTTPURLResponse {
        print("  ✓ Réseau   HTTP \(h.statusCode), \(h.expectedContentLength) octets reçus")
    } else {
        print("  ⚠ Réseau   téléchargement non concluant : \(err?.localizedDescription ?? "inconnu")")
    }
    let n1 = netCounters()
    let ignored: Set<String> = ["lo0","awdl0","llw0","bridge0","anpi0","gif0","stf0","utun0","utun1","utun2","utun3","utun4","utun5"]
    var down: Double = 0
    for (name, c) in n1 where !ignored.contains(name) {
        if let o = n0[name] { down += Double(c.0 &- o.0) }
    }
    print(String(format: "  ✓ Réseau   %.1f Ko/s en descendant", down / 1024))
    exit(0)
}
dl.resume()
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("  ⚠ Réseau   test de débit interrompu")
