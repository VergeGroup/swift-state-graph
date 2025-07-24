import SwiftSyntax
import SwiftSyntaxMacros

struct MemoryStorageStrategy: BackingStorageStrategy {
  
  func validate(variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> Bool {
    // Common validations
    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: MacroError.needsTypeAnnotation, node: variableDecl)
      return false
    }
    if variableDecl.didSetBlock != nil {
      context.addDiagnostics(from: MacroError.didSetNotSupported, node: variableDecl)
      return false
    }
    if variableDecl.willSetBlock != nil {
      context.addDiagnostics(from: MacroError.willSetNotSupported, node: variableDecl)
      return false
    }
    return true
  }

  func makeStorageDeclaration(for variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> VariableDeclSyntax {
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
        let baseType = type.removingOptionality().trimmed
        let wrappedType: String
        if variableDecl.isImplicitlyUnwrappedOptional {
          wrappedType = "\(baseType)?"
        } else {
          wrappedType = "\(type.trimmed)"
        }
        return "Stored<\(raw: wrappedType)>" as TypeSyntax
      }

    // Initializer logic
    if (variableDecl.isOptional || variableDecl.isImplicitlyUnwrappedOptional) && !variableDecl.hasInitializer {
      let initializerExpr: ExprSyntax = #".init(name: "\#(raw: propertyName)", wrappedValue: nil)"#
      return storageDecl.addInitializer(InitializerClauseSyntax(value: initializerExpr))
    } else {
      return storageDecl.modifyingInit { initializer in
        let initializerExpr: ExprSyntax = #".init(name: "\#(raw: propertyName)", wrappedValue: \#(initializer.trimmed.value))"#
        return .init(value: initializerExpr)
      }
    }
  }

  func makeAccessorDeclarations(for variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> [AccessorDeclSyntax] {
    let propertyName = variableDecl.name
    let needsInitAccessor = determineIfInitAccessorNeeded(for: variableDecl, context: context)
    var accessors: [AccessorDeclSyntax] = []

    if needsInitAccessor {
      accessors.append(createMemoryInitAccessor(propertyName: propertyName))
    } else if !variableDecl.isStatic && !SyntaxHelpers.isTopLevelProperty(context: context) {
      accessors.append(createMemoryAccessAccessor(propertyName: propertyName))
    }

    accessors.append(createMemoryGetAccessor(propertyName: propertyName, variableDecl: variableDecl))
    accessors.append(createMemorySetAccessor(propertyName: propertyName))

    return accessors
  }

  // Private helpers for this strategy
  private func determineIfInitAccessorNeeded(for variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> Bool {
    if variableDecl.isStatic && variableDecl.hasInitializer { return false }
    if SyntaxHelpers.isTopLevelProperty(context: context) && variableDecl.hasInitializer { return false }
    return !variableDecl.hasInitializer && !variableDecl.isOptional && !variableDecl.isImplicitlyUnwrappedOptional
  }

  private func createMemoryInitAccessor(propertyName: String) -> AccessorDeclSyntax {
    return AccessorDeclSyntax(
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

  private func createMemoryAccessAccessor(propertyName: String) -> AccessorDeclSyntax {
    return AccessorDeclSyntax(
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

  private func createMemoryGetAccessor(propertyName: String, variableDecl: VariableDeclSyntax) -> AccessorDeclSyntax {
    let valueExpressionString = "$\(propertyName).wrappedValue" + (variableDecl.isImplicitlyUnwrappedOptional ? "!" : "")
    
    let accessor: AccessorDeclSyntax = """
      get {
        return \(raw: valueExpressionString)
      }
      """
    return accessor
  }

  private func createMemorySetAccessor(propertyName: String) -> AccessorDeclSyntax {
    return AccessorDeclSyntax("set { $\(raw: propertyName).wrappedValue = newValue }")
  }
}
