import SwiftSyntax
import SwiftSyntaxMacros

struct UserDefaultsStorageStrategy: BackingStorageStrategy {
  let configuration: BackingStorageType.Configuration

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
    // UserDefaults specific validation
    if !variableDecl.hasInitializer {
      context.addDiagnostics(from: MacroError.userDefaultsRequiresDefaultValue, node: variableDecl)
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
        return "UserDefaultsStored<\(type.trimmed)>" as TypeSyntax
      }

    // Initializer logic
    let finalNodeName = configuration.name ?? propertyName
    return storageDecl.modifyingInit { initializer in
      var initExpr: ExprSyntax
      if let suite = configuration.suite {
        initExpr = #".init(name: "\#(raw: finalNodeName)", suite: "\#(raw: suite)", key: "\#(raw: configuration.key)", defaultValue: \#(initializer.trimmed.value))"#
      } else {
        initExpr = #".init(name: "\#(raw: finalNodeName)", key: "\#(raw: configuration.key)", defaultValue: \#(initializer.trimmed.value))"#
      }
      return .init(value: initExpr)
    }
  }

  func makeAccessorDeclarations(for variableDecl: VariableDeclSyntax, context: some MacroExpansionContext) -> [AccessorDeclSyntax] {
    let propertyName = variableDecl.name
    var accessors: [AccessorDeclSyntax] = []

    if !variableDecl.hasInitializer {
      // This case is already caught by validate, but as a safeguard:
      let accessor = AccessorDeclSyntax(
        """
        @storageRestrictions(initializes: $\(raw: propertyName))
        init(initialValue) {
          fatalError("UserDefaultsStored requires a default value, this should have been caught during compilation.")
        }
        """
      )
      accessors.append(accessor)
    }

    accessors.append(AccessorDeclSyntax("get { return $\(raw: propertyName).wrappedValue }"))
    accessors.append(AccessorDeclSyntax("set { $\(raw: propertyName).wrappedValue = newValue }"))
    
    return accessors
  }
}
