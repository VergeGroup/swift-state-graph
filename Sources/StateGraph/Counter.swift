import Synchronization
import os.lock

/// Fallback counter for platforms without `Atomic` support.
private let count_old: OSAllocatedUnfairLock<UInt64> = .init(
  uncheckedState: 0
)

/// Atomic counter used on platforms that support it.
@available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *)
private let count: Atomic<UInt64> = .init(0)

/// Generates a globally unique increasing number.
func makeUniqueNumber() -> UInt64 {
  
  if #available(macOS 15.0, iOS 18.0, watchOS 11.0, tvOS 18.0, visionOS 2.0, *) {
    return count.add(1, ordering: .relaxed).newValue
  } else {
    return count_old.withLock {
      $0 += 1
      return $0
    }
  }
  
}
