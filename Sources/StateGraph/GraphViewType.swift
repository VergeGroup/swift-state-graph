import os.lock
import Observation

/**
 Use @GraphView macro
 */
public protocol GraphViewType: Observable, Equatable, Hashable, AnyObject {
  
}

extension GraphViewType {
  
  public func hash(into hasher: inout Hasher) {
    hasher.combine(ObjectIdentifier(self))
  }
  
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs === rhs
  }
}
