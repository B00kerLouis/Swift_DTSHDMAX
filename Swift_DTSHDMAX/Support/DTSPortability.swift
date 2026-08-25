import Foundation

// Linux Foundation has no Objective-C runtime and therefore no
// `autoreleasepool`. The call sites use it purely to bound transient
// Foundation allocations on Darwin, so a direct invocation preserves
// behavior on platforms without an autorelease machinery.
#if !canImport(ObjectiveC)
@discardableResult
@inline(__always)
func autoreleasepool<Result>(invoking body: () throws -> Result) rethrows -> Result {
    try body()
}
#endif
