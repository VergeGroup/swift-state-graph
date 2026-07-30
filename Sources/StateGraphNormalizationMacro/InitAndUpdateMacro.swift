import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Splits one initializer body into the initializer and update-method bodies.
///
/// The macro deliberately copies only source statements. It never invents
/// storage or default values, so Swift continues to check definite
/// initialization using the initializer's actual assignments.
public struct InitAndUpdateMacro: BodyMacro, PeerMacro {

  /// The only container kinds whose update-method mutability is unambiguous.
  private enum ContainingTypeKind {
    case `class`
    case `struct`
  }

  /// The two ordered statement lists produced from a marked initializer body.
  private struct StatementPartition {
    let initialization: [CodeBlockItemSyntax]
    let update: [CodeBlockItemSyntax]
  }

  /// Diagnostics that identify declarations the peer method cannot reproduce.
  private enum Diagnostic: String, Swift.Error, DiagnosticMessage {
    case requiresInitializer
    case requiresClassOrStruct
    case requiresBody
    case failableInitializer
    case unsupportedInitializerModifier
    case unsupportedInitializerAttribute
    case markerRequiresTrailingClosure

    var message: String {
      switch self {
      case .requiresInitializer:
        return "@InitAndUpdate can only be attached to an initializer"
      case .requiresClassOrStruct:
        return "@InitAndUpdate requires an initializer declared directly in a class or struct"
      case .requiresBody:
        return "@InitAndUpdate requires an initializer body"
      case .failableInitializer:
        return "@InitAndUpdate does not support failable initializers"
      case .unsupportedInitializerModifier:
        return "@InitAndUpdate only supports an initializer access-level modifier"
      case .unsupportedInitializerAttribute:
        return "@InitAndUpdate does not support additional initializer attributes"
      case .markerRequiresTrailingClosure:
        return "#onInit and #onUpdate require a trailing closure"
      }
    }

    var diagnosticID: MessageID {
      MessageID(domain: "InitAndUpdateMacro", id: rawValue)
    }

    var severity: DiagnosticSeverity {
      .error
    }
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax] {
    guard let initializer = declaration.as(InitializerDeclSyntax.self) else {
      context.addDiagnostics(from: Diagnostic.requiresInitializer, node: node)
      return []
    }

    guard containingTypeKind(in: context) != nil else {
      context.addDiagnostics(from: Diagnostic.requiresClassOrStruct, node: node)
      return []
    }

    guard validate(initializer, in: context, reportingDiagnostics: true) else {
      return []
    }

    guard let body = initializer.body else {
      context.addDiagnostics(from: Diagnostic.requiresBody, node: node)
      return []
    }

    return partition(body.statements, in: context, reportingDiagnostics: true).initialization
  }

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard
      let initializer = declaration.as(InitializerDeclSyntax.self),
      let containingTypeKind = containingTypeKind(in: context),
      validate(initializer, in: context, reportingDiagnostics: false),
      let body = initializer.body
    else {
      // The body role reports attachment and validation diagnostics. Avoid
      // emitting each error twice when both attached roles are expanded.
      return []
    }

    let statements = partition(
      body.statements,
      in: context,
      reportingDiagnostics: false
    ).update

    let function = FunctionDeclSyntax(
      modifiers: updateModifiers(
        from: initializer.modifiers,
        containingTypeKind: containingTypeKind
      ),
      funcKeyword: .keyword(.func, trailingTrivia: .space),
      name: .identifier("update"),
      genericParameterClause: initializer.genericParameterClause,
      signature: FunctionSignatureSyntax(
        parameterClause: updateParameterClause(from: initializer.signature.parameterClause),
        effectSpecifiers: initializer.signature.effectSpecifiers
      ),
      genericWhereClause: initializer.genericWhereClause,
      body: CodeBlockSyntax(
        leftBrace: .leftBraceToken(),
        statements: .init(statements.map(\.trimmed)),
        rightBrace: .rightBraceToken()
      )
    )

    return [DeclSyntax(function)]
  }

  private static func containingTypeKind(
    in context: some MacroExpansionContext
  ) -> ContainingTypeKind? {
    for syntax in context.lexicalContext {
      if syntax.is(ClassDeclSyntax.self) {
        return .class
      }
      if syntax.is(StructDeclSyntax.self) {
        return .struct
      }
    }

    return nil
  }

  private static func validate(
    _ initializer: InitializerDeclSyntax,
    in context: some MacroExpansionContext,
    reportingDiagnostics: Bool
  ) -> Bool {
    guard initializer.optionalMark == nil else {
      report(Diagnostic.failableInitializer, at: initializer, in: context, when: reportingDiagnostics)
      return false
    }

    for modifier in initializer.modifiers where !isAccessLevelModifier(modifier) {
      report(
        Diagnostic.unsupportedInitializerModifier,
        at: modifier,
        in: context,
        when: reportingDiagnostics
      )
      return false
    }

    for attribute in initializer.attributes where !isInitAndUpdateAttribute(attribute) {
      report(
        Diagnostic.unsupportedInitializerAttribute,
        at: attribute,
        in: context,
        when: reportingDiagnostics
      )
      return false
    }

    return true
  }

  private static func isAccessLevelModifier(_ modifier: DeclModifierSyntax) -> Bool {
    switch modifier.name.text {
    case "private", "fileprivate", "internal", "package", "public", "open":
      return true
    default:
      return false
    }
  }

  private static func isInitAndUpdateAttribute(_ element: AttributeListSyntax.Element) -> Bool {
    guard case .attribute(let attribute) = element else {
      return false
    }

    return attribute.attributeName.trimmedDescription == "InitAndUpdate"
  }

  private static func report(
    _ diagnostic: Diagnostic,
    at node: some SyntaxProtocol,
    in context: some MacroExpansionContext,
    when shouldReport: Bool
  ) {
    guard shouldReport else {
      return
    }

    context.addDiagnostics(from: diagnostic, node: node)
  }

  private static func updateModifiers(
    from initializerModifiers: DeclModifierListSyntax,
    containingTypeKind: ContainingTypeKind
  ) -> DeclModifierListSyntax {
    var modifiers = DeclModifierListSyntax()

    if let accessLevel = initializerModifiers.first(where: isAccessLevelModifier) {
      modifiers.append(accessLevel)
    }

    if containingTypeKind == .struct {
      modifiers.append(
        DeclModifierSyntax(name: .keyword(.mutating, trailingTrivia: .space))
      )
    }

    return modifiers
  }

  /// Reuses the source spelling while removing the initializer body's leading
  /// indentation before the peer declaration is formatted in its new scope.
  private static func updateParameterClause(
    from parameterClause: FunctionParameterClauseSyntax
  ) -> FunctionParameterClauseSyntax {
    let parameters = parameterClause.parameters.map(\.trimmed)

    guard parameterClause.description.contains("\n") else {
      return .init(
        leftParen: .leftParenToken(),
        parameters: .init(parameters),
        rightParen: .rightParenToken()
      )
    }

    return .init(
      leftParen: .leftParenToken(),
      parameters: .init(
        parameters.map { parameter in
          parameter.with(\.leadingTrivia, .newline)
        }
      ),
      rightParen: .rightParenToken(leadingTrivia: .newline)
    )
  }

  private static func partition(
    _ statements: CodeBlockItemListSyntax,
    in context: some MacroExpansionContext,
    reportingDiagnostics: Bool
  ) -> StatementPartition {
    var initialization: [CodeBlockItemSyntax] = []
    var update: [CodeBlockItemSyntax] = []

    for statement in statements {
      guard let marker = marker(in: statement) else {
        initialization.append(statement)
        update.append(statement)
        continue
      }

      guard let markerStatements = marker.trailingClosure?.statements else {
        report(
          Diagnostic.markerRequiresTrailingClosure,
          at: marker,
          in: context,
          when: reportingDiagnostics
        )
        continue
      }

      switch marker.macroName.text {
      case "onInit":
        initialization.append(contentsOf: markerStatements)
      case "onUpdate":
        update.append(contentsOf: markerStatements)
      default:
        initialization.append(statement)
        update.append(statement)
      }
    }

    return .init(initialization: initialization, update: update)
  }

  private static func marker(in statement: CodeBlockItemSyntax) -> MacroExpansionExprSyntax? {
    guard case .expr(let expression) = statement.item else {
      return nil
    }

    guard let marker = expression.as(MacroExpansionExprSyntax.self) else {
      return nil
    }

    switch marker.macroName.text {
    case "onInit", "onUpdate":
      return marker
    default:
      return nil
    }
  }
}

/// Emits a targeted error when `#onInit` is used without its attached
/// initializer macro. `InitAndUpdateMacro` consumes valid markers before this
/// freestanding macro needs to produce an expression.
public struct OnInitMarkerMacro: ExpressionMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> ExprSyntax {
    try MarkerMacroSupport.expand(marker: "#onInit", node: node, in: context)
  }
}

/// Emits a targeted error when `#onUpdate` is used without its attached
/// initializer macro. `InitAndUpdateMacro` consumes valid markers before this
/// freestanding macro needs to produce an expression.
public struct OnUpdateMarkerMacro: ExpressionMacro {
  public static func expansion(
    of node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> ExprSyntax {
    try MarkerMacroSupport.expand(marker: "#onUpdate", node: node, in: context)
  }
}

/// Shared validation for the two freestanding marker macros.
private enum MarkerMacroSupport {
  private struct OutsideInitAndUpdateDiagnostic: DiagnosticMessage {
    let marker: String

    var message: String {
      "\(marker) can only be used in an initializer annotated with @InitAndUpdate"
    }

    var diagnosticID: MessageID {
      MessageID(domain: "InitAndUpdateMacro", id: "markerOutsideInitAndUpdate")
    }

    var severity: DiagnosticSeverity {
      .error
    }
  }

  static func expand(
    marker: String,
    node: some FreestandingMacroExpansionSyntax,
    in context: some MacroExpansionContext
  ) throws -> ExprSyntax {
    guard isInsideInitAndUpdateInitializer(context) else {
      context.diagnose(
        Diagnostic(
          node: Syntax(node),
          message: OutsideInitAndUpdateDiagnostic(marker: marker)
        )
      )
      return "()"
    }

    // Body macros receive and split the original marker. If the compiler ever
    // expands this marker independently, leave no executable work behind.
    return "()"
  }

  private static func isInsideInitAndUpdateInitializer(
    _ context: some MacroExpansionContext
  ) -> Bool {
    context.lexicalContext.contains { syntax in
      guard let initializer = syntax.as(InitializerDeclSyntax.self) else {
        return false
      }

      return initializer.attributes.contains { attribute in
        guard case .attribute(let attribute) = attribute else {
          return false
        }
        return attribute.attributeName.trimmedDescription == "InitAndUpdate"
      }
    }
  }
}
