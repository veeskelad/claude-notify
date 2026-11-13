import AppKit
import Darwin
import Foundation
import IOKit.ps

// What the Mac is doing: CPU, memory and its pressure, swap, disk, network, temperature mode and
// the apps behind the load.
//
//   background   every 5 s, always: CPU, memory, pressure, swap, thermal state (disk once a minute).
//                A few system calls; it feeds the alerts that widen the notch.
//   foreground   every 2 s while a System view is on screen: also network and the top apps.
//
// Apps are counted the way people think of them: every process inside Google Chrome.app (helpers,
// renderers) adds up to "Google Chrome". Only the user's own processes are visible without root,
// which covers the apps that matter here.

enum MemoryPressure: Int, Comparable {
    case normal = 1, warning = 2, critical = 4
    static func < (a: MemoryPressure, b: MemoryPressure) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .normal: return L.t("normal", "норма")
        case .warning: return L.t("high", "высокое")
        case .critical: return L.t("critical", "критическое")
        }
    }
}

struct AppUsage: Identifiable, Equatable {
    let name: String
    let path: String        // the .app bundle (or the executable) — for the icon
    var cpu: Double         // percent of one core, like Activity Monitor
    var memory: UInt64      // physical footprint, bytes
    var id: String { path.isEmpty ? name : path }
}

struct SystemStats: Equatable {
    var cpu: Double = 0                 // 0...1, all cores
    var cpuHistory: [Double] = []       // newest last
    var cores = ProcessInfo.processInfo.activeProcessorCount
    var memoryUsed: UInt64 = 0          // active + wired + compressed (Activity Monitor's "Memory Used")
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var pressure: MemoryPressure = .normal
    var swapUsed: UInt64 = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var netIn: Double = 0               // bytes per second
    var netOut: Double = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var topCPU: [AppUsage] = []
    var topMemory: [AppUsage] = []
    var sampled = false                 // CPU has a real value (it needs two samples)
}

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
}

/// Something worth a glance: the notch widens with it until it clears or the user has looked.
enum SystemAlert: Equatable {
    case cpu(Double, String)            // average load, the app behind it
    case memory(MemoryPressure, String)
    case thermal(ProcessInfo.ThermalState)
    case disk(Int64)

    /// Same key = the same problem; a new key (or a worse level) shows again after a look.
    var key: String {
        switch self {
        case .cpu: return "cpu"
        case .memory(let p, _): return "memory\(p.rawValue)"
        case .thermal(let t): return "thermal\(t.rawValue)"
        case .disk(let free): return free < 5 * gb ? "disk-critical" : "disk"
        }
    }

    var critical: Bool {
        switch self {
        case .cpu: return false
        case .memory(let p, _): return p == .critical
        case .thermal(let t): return t == .critical
        case .disk(let free): return free < 5 * gb
        }
    }
}

private let gb: Int64 = 1_073_741_824

final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()
    @Published private(set) var battery: BatteryState?
    @Published private(set) var alert: SystemAlert?
    /// Alerts on/off (Settings); off clears the current one.
    var alertsEnabled = true { didSet { if !alertsEnabled { alert = nil } } }
    /// Called on the main queue when the charger is plugged in or removed.
    var onPowerChange: (BatteryState) -> Void = { _ in }

    private var timer: Timer?
    private var users = 0
    private var ticks = 0
    private var lastCPU: [UInt32]?      // user, system, idle, nice ticks
    private var lastNet: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?
    private var cpuWindow: [(at: Date, load: Double)] = []   // the last 30 s, for the CPU alert
    private var lastProc: [Int32: (time: UInt64, at: UInt64)] = [:]
    private var appOf: [Int32: (name: String, path: String)] = [:]
    private var powerSource: CFRunLoopSource?

    init() {
        battery = SystemMonitor.readBattery()
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx = ctx else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.powerChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.sample() }
        sample()
        schedule()
    }

    /// A System view appeared / went away; while anyone looks, sampling is faster and fuller.
    func retain() {
        users += 1
        guard users == 1 else { return }
        sample()
        // CPU, network and per-app load are differences between two samples: the second comes
        // quickly, so the view doesn't open on zeros.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.sample() }
        schedule()
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        lastNet = nil
        schedule()
    }

    private var foreground: Bool { users > 0 }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: foreground ? 2 : 5, repeats: true) { [weak self] _ in self?.sample() }
        timer?.tolerance = foreground ? 0.2 : 1
    }

    private func powerChanged() {
        let old = battery
        battery = SystemMonitor.readBattery()
        if let now = battery, now.pluggedIn != old?.pluggedIn { onPowerChange(now) }
    }

    // MARK: Sampling

    private func sample() {
        ticks += 1
        var s = stats
        let now = Date()
        if let cpu = cpuLoad() {   // nil on the first sample: nothing to compare with yet
            s.cpu = cpu
            s.sampled = true
            s.cpuHistory.append(cpu)
            if s.cpuHistory.count > 60 { s.cpuHistory.removeFirst(s.cpuHistory.count - 60) }
            cpuWindow.append((now, cpu))
            cpuWindow.removeAll { now.timeIntervalSince($0.at) > 30 }
        }
        s.memoryUsed = memoryUsed() ?? s.memoryUsed
        s.pressure = SystemMonitor.memoryPressure()
        s.swapUsed = SystemMonitor.swapUsed()
        s.thermal = ProcessInfo.processInfo.thermalState
        if foreground || ticks % 12 == 1 || s.diskTotal == 0 {
            if let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                s.diskFree = disk.volumeAvailableCapacityForImportantUsage ?? 0
                s.diskTotal = Int64(disk.volumeTotalCapacity ?? 0)
            }
        }
        if foreground, let (bytesIn, bytesOut) = networkBytes() {
            if let last = lastNet {
                let dt = max(0.5, now.timeIntervalSince(last.at))
                s.netIn = Double(bytesIn &- last.bytesIn) / dt
                s.netOut = Double(bytesOut &- last.bytesOut) / dt
            }
            lastNet = (bytesIn, bytesOut, now)
        }
        // Per-app load: while someone looks, or while the load is high enough to need a culprit.
        if foreground || cpuAverage >= 0.7 || s.pressure >= .warning {
            let apps = sampleApps()
            if !apps.isEmpty || s.topCPU.isEmpty {
                s.topCPU = Array(apps.filter { $0.cpu >= 0.5 }.sorted { $0.cpu > $1.cpu }.prefix(6))
                s.topMemory = Array(apps.sorted { $0.memory > $1.memory }.prefix(6))
            }
        } else if !lastProc.isEmpty {
            lastProc.removeAll()
        }
        if s != stats { stats = s }
        evaluateAlert()
    }

    private var cpuAverage: Double {
        guard !cpuWindow.isEmpty else { return 0 }
        return cpuWindow.map(\.load).reduce(0, +) / Double(cpuWindow.count)
    }

    // MARK: Alerts
    //
    // Each has a higher bar to raise than to clear, so the notch doesn't flicker at the edge.

    private func evaluateAlert() {
        guard alertsEnabled else { return }
        let s = stats
        var candidates: [SystemAlert] = []
        // The system reports these two with its own hysteresis.
        if s.thermal == .serious || s.thermal == .critical { candidates.append(.thermal(s.thermal)) }
        if s.pressure >= .warning { candidates.append(.memory(s.pressure, s.topMemory.first?.name ?? "")) }
        let diskOn = alertKey(.disk) ? s.diskFree < 15 * gb : s.diskFree < 10 * gb
        if s.diskTotal > 0 && diskOn { candidates.append(.disk(s.diskFree)) }
        let avg = cpuAverage
        let cpuOn = alertKey(.cpu) ? avg >= 0.6 : (avg >= 0.85 && cpuWindow.count >= 5)
        if cpuOn { candidates.append(.cpu(avg, s.topCPU.first?.name ?? "")) }

        // Critical first, then in the order above (heat, memory, disk, CPU).
        let next = candidates.first(where: \.critical) ?? candidates.first
        if next != alert {
            if let n = next, n.key != alert?.key { log("[system] alert \(n.key)") }
            if next == nil, let a = alert { log("[system] alert \(a.key) cleared") }
            alert = next
        }
    }

    private enum AlertKind { case cpu, disk }

    /// The alert of this kind is on now (then the lower bar to clear applies).
    private func alertKey(_ kind: AlertKind) -> Bool {
        switch (kind, alert) {
        case (.cpu, .cpu?), (.disk, .disk?): return true
        default: return false
        }
    }

    // MARK: Readings

    private func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]   // user, system, idle, nice
        defer { lastCPU = ticks }
        guard let last = lastCPU else { return nil }
        let d = zip(ticks, last).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        guard total > 0 else { return nil }
        return (d[0] + d[1] + d[3]) / total
    }

    private func memoryUsed() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        return (anonymous + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * page
    }

    /// The kernel's own verdict, the one behind Activity Monitor's pressure graph colours.
    static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    static func swapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// CPU (since the last call) and memory per app.
    private func sampleApps() -> [AppUsage] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let n = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard n > 0 else { return [] }
        let now = mach_absolute_time()
        var seen = Set<Int32>()
        var byApp: [String: AppUsage] = [:]
        for pid in pids.prefix(Int(n)) where pid > 0 {
            var info = rusage_info_v2()
            let r = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard r == 0 else { continue }   // another user's process: not visible without root
            seen.insert(pid)
            let time = info.ri_user_time + info.ri_system_time   // mach absolute time units
            var cpu = 0.0
            if let last = lastProc[pid], now > last.at, time >= last.time {
                cpu = Double(time - last.time) / Double(now - last.at) * 100
            }
            lastProc[pid] = (time, now)
            let app = appOf[pid] ?? SystemMonitor.app(pid)
            appOf[pid] = app
            var entry = byApp[app.path] ?? AppUsage(name: app.name, path: app.path, cpu: 0, memory: 0)
            entry.cpu += cpu
            entry.memory += info.ri_phys_footprint
            byApp[app.path] = entry
        }
        lastProc = lastProc.filter { seen.contains($0.key) }
        appOf = appOf.filter { seen.contains($0.key) }
        // rusage times and `now` share mach absolute time units, so the ratio needs no timebase.
        return Array(byApp.values)
    }

    /// The outermost .app around the executable ("Google Chrome" for its helpers), else the binary's name.
    private static func app(_ pid: Int32) -> (name: String, path: String) {
        var buf = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else {
            var name = [CChar](repeating: 0, count: 256)
            proc_name(pid, &name, UInt32(name.count))
            let s = String(cString: name)
            return (s.isEmpty ? "pid \(pid)" : s, "pid:\(s)")
        }
        let path = String(cString: buf)
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            let name = ((bundle as NSString).lastPathComponent as NSString).deletingPathExtension
            return (name, bundle)
        }
        return ((path as NSString).lastPathComponent, path)
    }

    /// Bytes received and sent on physical interfaces (en*), loopback and tunnels left out.
    private func networkBytes() -> (UInt64, UInt64)? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return nil }
        defer { freeifaddrs(first) }
        var bytesIn: UInt64 = 0, bytesOut: UInt64 = 0
        var cursor: UnsafeMutablePointer<ifaddrs>? = start
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            bytesIn += UInt64(data.pointee.ifi_ibytes)
            bytesOut += UInt64(data.pointee.ifi_obytes)
        }
        return (bytesIn, bytesOut)
    }

    static func readBattery() -> BatteryState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int,
                  max > 0 else { continue }
            return BatteryState(percent: Int((Double(current) / Double(max) * 100).rounded()),
                                charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                pluggedIn: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }
}

enum ByteFormat {
    /// "10,6 of 16 GB"
    static func gigabytes(_ bytes: Double, decimals: Int = 1) -> String {
        let f = NumberFormatter()
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        f.locale = Locale(identifier: L.russian ? "ru_RU" : "en_US")
        return f.string(from: NSNumber(value: bytes / 1_073_741_824)) ?? "0"
    }

    /// "1,2 GB", "640 MB"
    static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1000 { return L.t("\(Int(mb.rounded())) MB", "\(Int(mb.rounded())) МБ") }
        return L.t("\(gigabytes(Double(bytes))) GB", "\(gigabytes(Double(bytes))) ГБ")
    }

    /// "1,2 MB/s", "86 KB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return L.t("\(Int(kb.rounded())) KB/s", "\(Int(kb.rounded())) КБ/с") }
        let mb = (kb / 1024 * 10).rounded() / 10
        let text = L.russian ? String(mb).replacingOccurrences(of: ".", with: ",") : String(mb)
        return L.t("\(text) MB/s", "\(text) МБ/с")
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return L.t("normal", "норма")
        case .fair: return L.t("warm", "тёплый")
        case .serious: return L.t("hot, slowing down", "горячий, тормозит")
        case .critical: return L.t("overheating", "перегрев")
        @unknown default: return "—"
        }
    }
}
