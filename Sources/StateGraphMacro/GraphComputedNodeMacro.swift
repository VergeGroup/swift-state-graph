import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Exposes a manually initialized `Computed` node through a read-only property.
public struct GraphComputedNodeMacro: PeerMacro, AccessorMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let variable = declaration.as(VariableDeclSyntax.self) else { return [] }
    try validate(variable)

    var projection = variable.trimmed
      .makeConstant()
      .inheritAccessControl(with: variable)
      .renamingIdentifier(with: "$")
      .modifyingTypeAnnotation { "Computed<\($0.trimmed)>" }
    projection.attributes = [.attribute("@GraphIgnored")]
    return [DeclSyntax(projection)]
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard let variable = declaration.as(VariableDeclSyntax.self),
          (try? validate(variable)) != nil
    else {
      // The peer expansion reports invalid declarations once.
      return []
    }

    return [
      """
      get {
        return $\(raw: variable.name).wrappedValue
      }
      """
    ]
  }

  private static func validate(_ variable: VariableDeclSyntax) throws {
    guard variable.bindings.count == 1, variable.typeSyntax != nil else {
      throw Error.needsTypeAnnotation
    }
    guard !variable.isConstant, !variable.hasInitializer, !variable.isWeak, !variable.isUnowned else {
      throw Error.requiresUninitializedVariable
    }
    guard variable.bindings.first?.accessorBlock == nil else {
      throw Error.cannotHaveBody
    }
  }

  /// Describes declarations that cannot forward to an explicitly initialized node.
  private enum Error: Swift.Error, DiagnosticMessage {
    case needsTypeAnnotation
    case requiresUninitializedVariable
    case cannotHaveBody

    var message: String {
      switch self {
      case .needsTypeAnnotation:
        return "@GraphComputedNode requires a single property with an explicit type"
      case .requiresUninitializedVariable:
        return "@GraphComputedNode requires a strong var without an initializer; initialize its projected node in init"
      case .cannotHaveBody:
        return "@GraphComputedNode cannot have a body or property observers; use @GraphComputed for a computed body"
      }
    }

    var diagnosticID: MessageID { MessageID(domain: "GraphComputedNodeMacro", id: "\(self)") }
    var severity: DiagnosticSeverity { .error }
  }
}
