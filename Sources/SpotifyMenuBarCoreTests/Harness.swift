// Minimal assertion harness. This toolchain (Command Line Tools, no Xcode) ships
// neither XCTest nor swift-testing, so tests are a plain executable that exits
// non-zero on failure. See AGENTS.md -> "Verification".
import Foundation

private var failures = 0
private var checks = 0

/// Both sides share one generic type, so comparing mismatched types is a compile
/// error rather than a silently-passing string comparison.
func expect<T: Equatable>(_ actual: T, _ expected: T, _ what: String,
                          file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if actual != expected {
        failures += 1
        FileHandle.standardError.write(
            "FAIL \(what)\n  expected: \(expected)\n  actual:   \(actual)\n  at \(file):\(line)\n"
                .data(using: .utf8)!)
    }
}

func expectClose(_ actual: Double, _ expected: Double, _ what: String,
                 tolerance: Double = 0.5, file: StaticString = #file, line: UInt = #line) {
    checks += 1
    if abs(actual - expected) > tolerance {
        failures += 1
        FileHandle.standardError.write(
            "FAIL \(what)\n  expected: \(expected) +/- \(tolerance)\n  actual:   \(actual)\n  at \(file):\(line)\n"
                .data(using: .utf8)!)
    }
}

func summarize() -> Never {
    print("\(checks - failures)/\(checks) checks passed")
    exit(failures == 0 ? 0 : 1)
}
