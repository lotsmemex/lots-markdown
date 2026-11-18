import AppKit
func t() -> Double { var i = kinfo_proc(); var s = MemoryLayout<kinfo_proc>.stride; var m: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]; sysctl(&m, 4, &i, &s, nil, 0); var n = timeval(); gettimeofday(&n, nil); return (Double(n.tv_sec - i.kp_proc.p_starttime.tv_sec) + Double(n.tv_usec - i.kp_proc.p_starttime.tv_usec) / 1e6) * 1000 }
let a = t()
let app = NSApplication.shared
let b = t()
final class D: NSObject, NSApplicationDelegate { var w: NSWindow!
  func applicationDidFinishLaunching(_ n: Notification) { let c = t()
    w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let d = t(); w.makeKeyAndOrderFront(nil); w.displayIfNeeded(); CATransaction.flush(); let e = t()
    print(String(format: "main %.0f  shared %.0f  didFinish %.0f  window %.0f  frame %.0f", a, b, c, d, e)); exit(0) } }
let d = D(); app.delegate = d; app.run()
