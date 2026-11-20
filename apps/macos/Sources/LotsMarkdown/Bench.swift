// Launch and render timing. LM_BENCH=1 prints JSON events to stderr (bench/macos_open.py
// reads them); LM_TRACE=1 prints labelled milestones; LM_BENCH_EXIT=1 exits once the
// preview is ready.

import Foundation

let env = ProcessInfo.processInfo.environment
let benchMode = env["LM_BENCH"] == "1"
let benchExit = env["LM_BENCH_EXIT"] == "1"

/// Seconds since this process started (kernel start time).
func secondsSinceProcessStart() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
    let start = info.kp_proc.p_starttime
    var now = timeval()
    gettimeofday(&now, nil)
    return Double(now.tv_sec - start.tv_sec) + Double(now.tv_usec - start.tv_usec) / 1e6
}

func trace(_ label: String) {
    guard env["LM_TRACE"] == "1" else { return }
    FileHandle.standardError.write(Data(String(format: "%7.1f ms  %@\n", secondsSinceProcessStart() * 1000, label).utf8))
}

func bench(_ fields: [String: Any]) {
    guard benchMode, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    FileHandle.standardError.write(data + Data("\n".utf8))
}
