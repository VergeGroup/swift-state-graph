import SwiftDiagnostics
import SwiftSyntax

public enum MacroError: Swift.Error {
  case constantVariableIsNotSupported
  case computedVariableIsNotSupported
  case needsTypeAnnotation
  case didSetNotSupported
  case willSetNotSupported
  case userDefaultsRequiresDefaultValue
  case invalidBackingArgument
  case weakVariableNotSupported
  case unownedVariableNotSupported
}

extension MacroError: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @GraphStored"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @GraphStored"
    case .needsTypeAnnotation:
      return "@GraphStored requires explicit type annotation"
    case .didSetNotSupported:
      return "didSet is not supported with @GraphStored"
    case .willSetNotSupported:
      return "willSet is not supported with @GraphStored"
    case .userDefaultsRequiresDefaultValue:
      return "@GraphStored with UserDefaults backing requires a default value"
    case .invalidBackingArgument:
      return "Invalid backing argument for @GraphStored"
    case .weakVariableNotSupported:
      return "weak variables are not supported with @GraphStored"
    case .unownedVariableNotSupported:
      return "unowned variables are not supported with @GraphStored"
    }
  }

  public var diagnosticID: MessageID {
    MessageID(domain: "StateGraphMacro", id: "\(self)")
  }

  public var severity: DiagnosticSeverity {
    return .error
  }
}
