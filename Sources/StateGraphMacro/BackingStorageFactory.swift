import SwiftSyntax
import SwiftSyntaxMacros

/// Configuration for backing storage type
enum BackingStorageType {
  case memory
  case userDefaults(Configuration)

  struct Configuration {
    let key: String
    let suite: String?
    let name: String?
  }
}

/// A factory for creating the appropriate `BackingStorageStrategy` based on
/// the macro's arguments.
enum BackingStorageFactory {

  /// Creates a `BackingStorageStrategy` by parsing the macro's attribute syntax.
  /// - Parameters:
  ///   - node: The attribute syntax representing the macro invocation.
  ///   - context: The macro expansion context.
  /// - Returns: A concrete implementation of `BackingStorageStrategy`.
  static func makeStrategy(
    from node: AttributeSyntax,
    context: some MacroExpansionContext
  ) -> BackingStorageStrategy {
    let backingType = parseBackingStorageType(from: node, context: context)
    
    switch backingType {
    case .memory:
      return MemoryStorageStrategy()
    case .userDefaults(let configuration):
      return UserDefaultsStorageStrategy(configuration: configuration)
    }
  }

  private static func parseBackingStorageType(
    from node: AttributeSyntax,
    context: some MacroExpansionContext
  ) -> BackingStorageType {
    guard let arguments = node.arguments?.as(LabeledExprListSyntax.self) else {
      return .memory // Default to memory if no arguments
    }

    guard let backedArgument = arguments.first(where: { $0.label?.text == "backed" }) else {
      return .memory
    }
    
    return parseBackingExpression(from: backedArgument.expression)
  }
  
  private static func parseBackingExpression(
    from expression: ExprSyntax
  ) -> BackingStorageType {
    if let functionCall = expression.as(FunctionCallExprSyntax.self),
       let callee = functionCall.calledExpression.as(MemberAccessExprSyntax.self),
       callee.declName.baseName.text == "userDefaults" {
      let config = parseUserDefaultsArguments(from: functionCall.arguments)
      return .userDefaults(config)
    }
    
    if let memberAccess = expression.as(MemberAccessExprSyntax.self),
       memberAccess.declName.baseName.text == "memory" {
      return .memory
    }
    
    return .memory
  }

  private static func parseUserDefaultsArguments(
    from arguments: LabeledExprListSyntax
  ) -> BackingStorageType.Configuration {
    var key: String?
    var suite: String?
    var name: String?

    for argument in arguments {
      guard let label = argument.label?.text else { continue }
      let stringValue = SyntaxHelpers.extractStringLiteral(from: argument.expression)

      switch label {
      case "key": key = stringValue
      case "suite": suite = stringValue
      case "name": name = stringValue
      default: break
      }
    }

    return .init(key: key ?? "", suite: suite, name: name)
  }
}
