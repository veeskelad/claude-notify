import Darwin
import Foundation
import IOKit.ps

// The "System" widget: CPU, memory, disk and network, sampled every 2 s while the widget is on
// screen (nothing runs while the panel is closed). Battery is watched all the time through the
// power-source notification, which costs nothing between changes.

struct SystemStats: Equatable {
    var cpu: Double = 0                 // 0...1, all cores
    var memoryUsed: UInt64 = 0          // bytes: active + wired + compressed (Activity Monitor's "Memory Used")
    var memoryTotal: UInt64 = ProcessInfo.processInfo.physicalMemory
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var netIn: Double = 0               // bytes per second
    var netOut: Double = 0
    var sampled = false
}

struct BatteryState: Equatable {
    var percent: Int
    var charging: Bool
    var pluggedIn: Bool
}

final class SystemMonitor: ObservableObject {
    @Published private(set) var stats = SystemStats()
    @Published private(set) var battery: BatteryState?
    /// Called on the main queue when the charger is plugged in or removed.
    var onPowerChange: (BatteryState) -> Void = { _ in }

    private var timer: Timer?
    private var users = 0
    private var lastCPU: [UInt32]?      // user, system, idle, nice ticks
    private var lastNet: (bytesIn: UInt64, bytesOut: UInt64, at: Date)?
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
    }

    /// The widget appeared / went away; sampling runs while anyone looks.
    func retain() {
        users += 1
        guard timer == nil else { return }
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.sample() }
    }

    func release() {
        users = max(0, users - 1)
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        lastCPU = nil
        lastNet = nil
    }

    private func powerChanged() {
        let old = battery
        battery = SystemMonitor.readBattery()
        if let now = battery, now.pluggedIn != old?.pluggedIn { onPowerChange(now) }
    }

    // MARK: Sampling

    private func sample() {
        var s = stats
        s.cpu = cpuLoad() ?? s.cpu
        s.memoryUsed = memoryUsed() ?? s.memoryUsed
        if let disk = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = disk.volumeAvailableCapacityForImportantUsage ?? 0
            s.diskTotal = Int64(disk.volumeTotalCapacity ?? 0)
        }
        if let (bytesIn, bytesOut) = networkBytes() {
            let now = Date()
            if let last = lastNet {
                let dt = max(0.5, now.timeIntervalSince(last.at))
                s.netIn = Double(bytesIn &- last.bytesIn) / dt
                s.netOut = Double(bytesOut &- last.bytesOut) / dt
            }
            lastNet = (bytesIn, bytesOut, now)
        }
        s.sampled = true
        if s != stats { stats = s }
    }

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

    /// "1,2 MB/s", "86 KB/s"
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return L.t("\(Int(kb.rounded())) KB/s", "\(Int(kb.rounded())) КБ/с") }
        let mb = (kb / 1024 * 10).rounded() / 10
        let text = L.russian ? String(mb).replacingOccurrences(of: ".", with: ",") : String(mb)
        return L.t("\(text) MB/s", "\(text) МБ/с")
    }
}
