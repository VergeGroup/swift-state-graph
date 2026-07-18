import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Expands `@GraphStored` into an in-memory `Stored` node and forwarding accessors.
public struct GraphStoredMacro {
  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsTypeAnnotation
    case weakVariableNotSupported
    case unownedVariableNotSupported
  }
}

extension GraphStoredMacro.Error: DiagnosticMessage {
  public var message: String {
    switch self {
    case .constantVariableIsNotSupported:
      return "Constant variables are not supported with @GraphStored"
    case .computedVariableIsNotSupported:
      return "Computed variables are not supported with @GraphStored"
    case .needsTypeAnnotation:
      return "@GraphStored requires explicit type annotation"
    case .weakVariableNotSupported:
      return "weak variables are not supported with @GraphStored"
    case .unownedVariableNotSupported:
      return "unowned variables are not supported with @GraphStored"
    }
  }

  public var diagnosticID: MessageID {
    MessageID(domain: "GraphStoredMacro", id: "\(self)")
  }

  public var severity: DiagnosticSeverity {
    .error
  }
}

extension GraphStoredMacro {
  /// Describes the declaration kind that lexically contains a stored property.
  private enum ContainingTypeKind {
    case `actor`
    case `class`
    case `enum`
    case `protocol`
    case `struct`
  }

  private static func validateDeclaration(
    _ variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext,
    node: some SyntaxProtocol
  ) -> Bool {
    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: Error.needsTypeAnnotation, node: node)
      return false
    }

    return true
  }

  private static func shouldIgnoreMacro(_ variableDecl: VariableDeclSyntax) -> Bool {
    variableDecl.attributes.contains {
      switch $0 {
      case .attribute(let attribute):
        return attribute.attributeName.description == "Ignored"
      case .ifConfigDecl:
        return false
      }
    }
  }

  private static func shouldUseNonmutatingSetter(
    for variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    guard !variableDecl.isStatic else {
      return false
    }

    switch nearestContainingTypeKind(context: context) {
    case .enum, .struct:
      return true
    case .actor, .class, .protocol, nil:
      return false
    }
  }

  private static func nearestContainingTypeKind(
    context: some MacroExpansionContext
  ) -> ContainingTypeKind? {
    for syntax in context.lexicalContext {
      if syntax.is(ActorDeclSyntax.self) {
        return .actor
      }
      if syntax.is(ClassDeclSyntax.self) {
        return .class
      }
      if syntax.is(EnumDeclSyntax.self) {
        return .enum
      }
      if syntax.is(ProtocolDeclSyntax.self) {
        return .protocol
      }
      if syntax.is(StructDeclSyntax.self) {
        return .struct
      }
    }

    return nil
  }

  private static func createStorageDeclaration(
    from variableDecl: VariableDeclSyntax
  ) -> VariableDeclSyntax {
    let propertyName = variableDecl.name

    var storageDecl = variableDecl
      .trimmed
      .makeConstant()
      .inheritAccessControl(with: variableDecl)

    storageDecl.attributes = [.init(.init(stringLiteral: "@GraphIgnored"))]

    if variableDecl.isStatic {
      var modifiers = storageDecl.modifiers
      if !modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) {
        modifiers.append(.init(name: .keyword(.static)))
      }
      storageDecl = storageDecl.with(\.modifiers, modifiers)
    }

    storageDecl = storageDecl
      .renamingIdentifier(with: "$")
      .modifyingTypeAnnotation { type in
        createStoredTypeAnnotation(for: type, variableDecl: variableDecl)
      }

    storageDecl = createInitializer(
      for: storageDecl,
      variableDecl: variableDecl,
      propertyName: propertyName
    )

    storageDecl = storageDecl.with(
      \.bindings,
      .init(
        storageDecl.bindings.map { binding in
          binding.with(\.accessorBlock, nil)
        }
      )
    )

    return storageDecl
  }

  private static func createStoredTypeAnnotation(
    for type: TypeSyntax,
    variableDecl: VariableDeclSyntax
  ) -> TypeSyntax {
    let baseType = type.removingOptionality().trimmed
    let wrappedType = variableDecl.isImplicitlyUnwrappedOptional
      ? "\(baseType)?"
      : "\(type.trimmed)"

    return "Stored<\(raw: wrappedType)>" as TypeSyntax
  }

  private static func createInitializer(
    for storageDecl: VariableDeclSyntax,
    variableDecl: VariableDeclSyntax,
    propertyName: String
  ) -> VariableDeclSyntax {
    if (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional)
      && !variableDecl.hasInitializer
    {
      let expression = #".init(name: "\#(raw: propertyName)", wrappedValue: nil)"# as ExprSyntax
      return storageDecl.addInitializer(
        InitializerClauseSyntax(value: expression)
      )
    }

    return storageDecl.modifyingInit { initializer in
      let expression = #".init(name: "\#(raw: propertyName)", wrappedValue: \#(initializer.trimmed.value))"# as ExprSyntax
      return .init(value: expression)
    }
  }
}

extension GraphStoredMacro: PeerMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {
    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    guard !shouldIgnoreMacro(variableDecl), !variableDecl.isComputed else {
      return []
    }

    guard validateDeclaration(variableDecl, context: context, node: declaration) else {
      return []
    }

    return [DeclSyntax(createStorageDeclaration(from: variableDecl))]
  }
}

extension GraphStoredMacro: AccessorMacro {
  public static func expansion(
    of node: AttributeSyntax,
    providingAccessorsOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [AccessorDeclSyntax] {
    guard
      let variableDecl = declaration.as(VariableDeclSyntax.self),
      let binding = variableDecl.bindings.first,
      let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else {
      return []
    }

    guard !variableDecl.isComputed else {
      context.addDiagnostics(from: Error.computedVariableIsNotSupported, node: declaration)
      return []
    }

    guard !variableDecl.isConstant else {
      context.addDiagnostics(from: Error.constantVariableIsNotSupported, node: declaration)
      return []
    }

    guard !variableDecl.isWeak else {
      context.addDiagnostics(from: Error.weakVariableNotSupported, node: declaration)
      return []
    }

    guard !variableDecl.isUnowned else {
      context.addDiagnostics(from: Error.unownedVariableNotSupported, node: declaration)
      return []
    }

    return createAccessors(
      propertyName: identifierPattern.identifier.text,
      variableDecl: variableDecl,
      context: context
    )
  }

  private static func createAccessors(
    propertyName: String,
    variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> [AccessorDeclSyntax] {
    var accessors: [AccessorDeclSyntax] = []

    if determineIfInitAccessorNeeded(for: variableDecl, context: context) {
      accessors.append(createInitAccessor(propertyName: propertyName))
    } else if !variableDecl.isStatic && !isTopLevelProperty(context: context) {
      accessors.append(createAccessInitAccessor(propertyName: propertyName))
    }

    accessors.append(
      createGetAccessor(
        propertyName: propertyName,
        needsUnwrap: variableDecl.isImplicitlyUnwrappedOptional
      )
    )
    accessors.append(
      createSetAccessor(
        assignmentTarget: "$\(propertyName).wrappedValue",
        variableDecl: variableDecl,
        context: context
      )
    )

    return accessors
  }

  private static func determineIfInitAccessorNeeded(
    for variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> Bool {
    if variableDecl.isStatic && variableDecl.hasInitializer {
      return false
    }

    if isTopLevelProperty(context: context) && variableDecl.hasInitializer {
      return false
    }

    if variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional {
      return false
    }

    return !variableDecl.hasInitializer
  }

  private static func isTopLevelProperty(
    context: some MacroExpansionContext
  ) -> Bool {
    for syntax in context.lexicalContext {
      if syntax.is(ClassDeclSyntax.self)
        || syntax.is(StructDeclSyntax.self)
        || syntax.is(EnumDeclSyntax.self)
        || syntax.is(ActorDeclSyntax.self)
        || syntax.is(ProtocolDeclSyntax.self)
        || syntax.is(ExtensionDeclSyntax.self)
      {
        return false
      }
    }

    return true
  }

  private static func createInitAccessor(
    propertyName: String
  ) -> AccessorDeclSyntax {
    AccessorDeclSyntax(
      """
      @storageRestrictions(
        initializes: $\(raw: propertyName)
      )
      init(initialValue) {
        $\(raw: propertyName) = .init(name: "\(raw: propertyName)", wrappedValue: initialValue)
      }
      """
    )
  }

  private static func createAccessInitAccessor(
    propertyName: String
  ) -> AccessorDeclSyntax {
    AccessorDeclSyntax(
      """
      @storageRestrictions(
        accesses: $\(raw: propertyName)
      )
      init(initialValue) {
        $\(raw: propertyName).wrappedValue = initialValue
      }
      """
    )
  }

  private static func createGetAccessor(
    propertyName: String,
    needsUnwrap: Bool
  ) -> AccessorDeclSyntax {
    let expression = needsUnwrap
      ? "$\(propertyName).wrappedValue!"
      : "$\(propertyName).wrappedValue"

    return AccessorDeclSyntax(
      """
      get {
        return \(raw: expression)
      }
      """
    )
  }

  private static func createSetAccessor(
    assignmentTarget: String,
    variableDecl: VariableDeclSyntax,
    context: some MacroExpansionContext
  ) -> AccessorDeclSyntax {
    let setterKeyword = shouldUseNonmutatingSetter(for: variableDecl, context: context)
      ? "nonmutating set"
      : "set"

    guard variableDecl.willSetBlock != nil || variableDecl.didSetBlock != nil else {
      return AccessorDeclSyntax(
        """
        \(raw: setterKeyword) {
          \(raw: assignmentTarget) = newValue
        }
        """
      )
    }

    let typeAnnotation = variableDecl.typeSyntax.map { ": \($0.trimmed)" } ?? ""
    var statements: [String] = []

    if let willSetBlock = variableDecl.willSetBlock {
      let newValueName = variableDecl.willSetParameterName
      let observerStatements = makeObserverStatements(from: willSetBlock)
      statements.append(
        """
        do {
        \(indent("let \(newValueName)\(typeAnnotation) = __graphStoredNewValue\n\(observerStatements)", by: 2))
        }
        """
      )
    }

    if variableDecl.didSetBlock != nil {
      let oldValueName = variableDecl.didSetParameterName
      statements.append("let \(oldValueName)\(typeAnnotation) = \(assignmentTarget)")
    }

    statements.append("\(assignmentTarget) = __graphStoredNewValue")

    if let didSetBlock = variableDecl.didSetBlock {
      statements.append(
        """
        do {
        \(indent(makeObserverStatements(from: didSetBlock), by: 2))
        }
        """
      )
    }

    return AccessorDeclSyntax(
      """
      \(raw: setterKeyword)(__graphStoredNewValue) {
      \(raw: indent(statements.joined(separator: "\n"), by: 2))
      }
      """
    )
  }

  private static func makeObserverStatements(from block: CodeBlockSyntax) -> String {
    block.trimmed.statements
      .map { $0.trimmed.description }
      .joined(separator: "\n")
  }

  private static func indent(_ string: String, by spaces: Int) -> String {
    let indentation = String(repeating: " ", count: spaces)
    return string
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line in
        line.isEmpty ? "" : "\(indentation)\(line)"
      }
      .joined(separator: "\n")
  }
}
