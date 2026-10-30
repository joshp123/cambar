import Darwin
import Foundation
// Average power and CPU per process from the kernel's energy counter, no sudo:
// swiftc -O Scripts/Support/ProcessEnergy.swift -o /tmp/process-energy && /tmp/process-energy 60 <pid>...
// Root processes, such as Tailscale's network extension, are unreadable.
let seconds = Double(CommandLine.arguments[1])!
let pids = CommandLine.arguments.dropFirst(2).compactMap { Int32($0) }
func read(_ pid: Int32) -> (UInt64, UInt64)? {
    var info = rusage_info_v6()
    let ok = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
        }
    }
    return ok == 0 ? (info.ri_energy_nj, info.ri_user_time + info.ri_system_time) : nil
}
let start = pids.map(read)
Thread.sleep(forTimeInterval: seconds)
for (pid, first) in zip(pids, start) {
    guard let first, let last = read(pid) else { print("\(pid) unreadable (errno \(errno))"); continue }
    let mW = Double(last.0 - first.0) / seconds / 1e6
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); let cpu = Double(last.1 - first.1) * Double(tb.numer) / Double(tb.denom) / seconds / 1e9 * 100
    print(String(format: "%d %.1f mW %.2f%% cpu", pid, mW, cpu))
}
