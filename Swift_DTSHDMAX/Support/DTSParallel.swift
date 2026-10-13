import Foundation
#if os(macOS)
import Darwin
#endif

/// Small synchronous parallel primitive for the encoder's existing throwing APIs.
/// Work is split into contiguous index ranges so the result order is deterministic,
/// while each worker owns its local codec state and no sample loop uses an actor.
public enum DTSParallel {
    /// A foreground encode creates hundreds of small deterministic batches.
    /// Reusing one queue avoids repeatedly allocating dispatch queue state and
    /// gives an explicit user-requested encode foreground scheduling priority.
    private static let encoderQueue = DispatchQueue(
        label: "org.libhdmax",
        qos: .userInitiated,
        attributes: .concurrent
    )

    public static func workerCount(for itemCount: Int) -> Int {
        guard itemCount > 0 else { return 1 }
        let activeProcessors = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let reservedProcessors = activeProcessors > 2
            ? max(2, activeProcessors / 4)
            : activeProcessors - 1
        let encoderBudget = max(1, activeProcessors - reservedProcessors)
        return min(itemCount, min(performanceWorkerLimit, encoderBudget))
    }

    private static let performanceWorkerLimit: Int = {
#if os(macOS) && arch(arm64)
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 {
            return min(16, max(1, Int(cores)))
        }
#endif
        return 8
    }()

    public static func map<Result: Sendable>(
        count: Int,
        workerCount requestedWorkerCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil,
        _ operation: @escaping @Sendable (Int) throws -> Result
    ) throws -> [Result] {
        try start(count: count, workerCount: requestedWorkerCount, progress: progress, operation).wait()
    }

    /// One bounded batch may overlap serial Core preparation. Callers join it
    /// before serial output, and also join on every error path.
    static func start<Result: Sendable>(
        count: Int, workerCount requestedWorkerCount: Int? = nil,
        progress: ((Int, Int) -> Void)? = nil,
        _ operation: @escaping @Sendable (Int) throws -> Result
    ) throws -> DTSParallelBatch<Result> {
        guard count >= 0 else {
            throw DTSError.invalidArgument("parallel map count must not be negative")
        }
        guard count > 0 else {
            progress?(0, 0)
            return DTSParallelBatch(group: DispatchGroup(), box: ResultBox(count: 0, progress: nil))
        }

        let workers = min(
            count,
            max(1, requestedWorkerCount ?? workerCount(for: count))
        )
        let box = ResultBox<Result>(count: count, progress: progress)
        progress?(0, count)
        let group = DispatchGroup()
        for worker in 0..<workers {
            group.enter()
            encoderQueue.async {
                defer { group.leave() }
                let start = (count * worker) / workers
                let end = (count * (worker + 1)) / workers
                guard start < end else { return }
                for index in start..<end {
                    do {
                        box.store(try operation(index), at: index)
                    } catch {
                        box.store(error: error)
                    }
                }
            }
        }
        return DTSParallelBatch(group: group, box: box)
    }
}

final class DTSParallelBatch<Element: Sendable>: @unchecked Sendable {
    private let group: DispatchGroup
    private let box: ResultBox<Element>

    fileprivate init(group: DispatchGroup, box: ResultBox<Element>) {
        self.group = group; self.box = box
    }

    func wait() throws -> [Element] { group.wait(); return try box.results() }
    func waitForCompletion() { group.wait() }
}

private final class ResultBox<Element: Sendable>: @unchecked Sendable {
    private var storage: [Element?]
    private var firstError: Error?
    private var completedCount = 0
    private let progress: ((Int, Int) -> Void)?
    private let lock = NSLock()
    private let progressLock = NSLock()

    init(count: Int, progress: ((Int, Int) -> Void)?) {
        storage = Array(repeating: nil, count: count)
        self.progress = progress
    }

    func store(_ value: Element, at index: Int) {
        lock.lock()
        storage[index] = value
        completedCount += 1
        let completed = completedCount
        let total = storage.count
        // Reserve the callback order while holding the state lock, then release
        // encoder result storage before invoking arbitrary caller code.
        progressLock.lock()
        lock.unlock()
        progress?(completed, total)
        progressLock.unlock()
    }

    func store(error: Error) {
        lock.lock()
        if firstError == nil { firstError = error }
        lock.unlock()
    }

    func results() throws -> [Element] {
        lock.lock()
        defer { lock.unlock() }
        if let firstError { throw firstError }
        guard storage.allSatisfy({ $0 != nil }) else {
            throw DTSError.malformed("parallel encoder worker did not produce every result")
        }
        return storage.compactMap { $0 }
    }
}
