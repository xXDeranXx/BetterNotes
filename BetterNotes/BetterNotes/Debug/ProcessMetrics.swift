import Darwin
import os

// The whole Debug folder is temporary (SPEC, "Later", debug overlay): delete the folder, the
// `.debugOverlay()` line in `RootView` and the "Debug" section in `ToolbarSettingsView`, and it is gone.

/// Reads the app's own CPU and memory use from the kernel (Mach), the same numbers Xcode's
/// debug gauges show. Comparable to `process.cpuUsage()` and `process.memoryUsage()` in Node.
nonisolated enum ProcessMetrics {
    /// CPU use of all the app's threads in percent of one core, so it can go above 100 on a
    /// chip with several cores. The kernel reports a short moving average per thread.
    static func cpuPercent() -> Double {
        let task = mach_task_self_
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(task, &threads, &threadCount) == KERN_SUCCESS, let threads else { return 0 }
        defer {
            // The list and every thread port in it belong to us now and must be given back.
            for index in 0..<Int(threadCount) { mach_port_deallocate(task, threads[index]) }
            vm_deallocate(
                task, vm_address_t(UInt(bitPattern: threads)),
                vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    thread_info(threads[index], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 else { continue }
            total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
        }
        return total
    }

    /// The app's memory footprint in bytes: the number iPadOS uses when it decides to end an
    /// app that uses too much memory.
    static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// How many more bytes the app may use before iPadOS ends it. Always 0 in the simulator,
    /// which has no such limit.
    static func availableMemory() -> UInt64 {
        UInt64(os_proc_available_memory())
    }
}
