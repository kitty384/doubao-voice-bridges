import AppKit

@main
enum DoubaoVoiceBridgeMain {
    static func main() {
        if let index = CommandLine.arguments.firstIndex(of: "--check-instance-lock"),
           CommandLine.arguments.count > index + 1 {
            let probe = SingleInstanceGuard()
            exit(probe.acquire(at: URL(fileURLWithPath: CommandLine.arguments[index + 1])) ? 0 : 2)
        }
        if CommandLine.arguments.contains("--logic-self-test") {
            let result = SafetyTests.run()
            for failure in result.failures { fputs("LOGIC_FAILURE \(failure)\n", stderr) }
            if result.failures.isEmpty { print("LOGIC_SELF_TEST_OK safety_cases=\(result.count)") }
            exit(result.failures.isEmpty ? 0 : 1)
        }
        if CommandLine.arguments.contains("--observe-trigger") {
            exit(TriggerObserver.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }
        if CommandLine.arguments.contains("--diagnostics") {
            Diagnostics.printReport()
            return
        }
        if CommandLine.arguments.contains("--self-test") {
            exit(SelfTests.run() ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let instance = SingleInstanceGuard()
        guard instance.acquire() else {
            fputs("远控听写已在运行，或无法取得实例锁；本次启动不会安装监听器。\n", stderr)
            return
        }
        let application = NSApplication.shared
        let appDelegate = AppDelegate()
        application.delegate = appDelegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(instance) { application.run() }
    }
}
