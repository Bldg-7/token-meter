import Foundation

final class TerminationFlag {
    private let lock = NSLock()
    private var value: Bool = false

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }

    func isSet() -> Bool {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }
}

let shouldExit = TerminationFlag()

signal(SIGINT) { _ in
    shouldExit.set()
}

signal(SIGTERM) { _ in
    shouldExit.set()
}

let tick = Timer(timeInterval: 60.0, repeats: true) { _ in }
RunLoop.current.add(tick, forMode: .default)

while shouldExit.isSet() == false {
    RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 1.0))
}
