import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct StoredMacro {
  public enum Error: Swift.Error {
    case constantVariableIsNotSupported
    case computedVariableIsNotSupported
    case needsTypeAnnotation
    case didSetNotSupported
    case willSetNotSupported
  }
}

extension StoredMacro: PeerMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingPeersOf declaration: some DeclSyntaxProtocol,
    in context: some MacroExpansionContext
  ) throws -> [DeclSyntax] {

    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    guard variableDecl.typeSyntax != nil else {
      context.addDiagnostics(from: Error.needsTypeAnnotation, node: declaration)
      return []
    }

    // check the current limitation
    do {
      if variableDecl.didSetBlock != nil {
        context.addDiagnostics(from: Error.didSetNotSupported, node: declaration)
        return []
      }

      if variableDecl.willSetBlock != nil {
        context.addDiagnostics(from: Error.willSetNotSupported, node: declaration)
        return []
      }
    }

    var newMembers: [DeclSyntax] = []

    let ignoreMacroAttached = variableDecl.attributes.contains {
      switch $0 {
      case .attribute(let attribute):
        return attribute.attributeName.description == "Ignored"
      case .ifConfigDecl:
        return false
      }
    }

    guard !ignoreMacroAttached else {
      return []
    }

    for binding in variableDecl.bindings {
      if binding.accessorBlock != nil {
        // skip computed properties
        continue
      }
    }

    let prefix = "$"

    var _variableDecl = variableDecl
      .trimmed
      .makeConstant()
      .inheritAccessControl(with: variableDecl)

    _variableDecl.attributes = [.init(.init(stringLiteral: "@StageGraphIgnored"))]

    _variableDecl =
      _variableDecl
      .renamingIdentifier(with: prefix)
      .modifyingTypeAnnotation({ type in
        if variableDecl.isWeak {
          return "StoredNode<Weak<\(type.removingOptionality().trimmed)>>"
        } else if variableDecl.isUnowned {
          return "StoredNode<Unowned<\(type.removingOptionality().trimmed)>>"
        } else {
          return "StoredNode<\(type.trimmed)>"
        }
      })

    if variableDecl.isOptional && variableDecl.hasInitializer == false {

    } else {
      _variableDecl = _variableDecl.modifyingInit({ initializer in

        if variableDecl.isWeak {
          return .init(
            value: ".init(wrappedValue: .init(\(initializer.trimmed.value)))" as ExprSyntax)
        } else if variableDecl.isUnowned {
          return .init(
            value: ".init(wrappedValue: .init(\(initializer.trimmed.value)))" as ExprSyntax)
        } else {
          return .init(value: ".init(wrappedValue: \(initializer.trimmed.value))" as ExprSyntax)
        }

      })
    }

    do {

      // remove accessors
      _variableDecl = _variableDecl.with(
        \.bindings,
        .init(
          _variableDecl.bindings.map { binding in
            binding.with(\.accessorBlock, nil)
          }
        )
      )

    }

    newMembers.append(DeclSyntax(_variableDecl))

    return newMembers
  }
}

extension StoredMacro: AccessorMacro {

  public static func expansion(
    of node: SwiftSyntax.AttributeSyntax,
    providingAccessorsOf declaration: some SwiftSyntax.DeclSyntaxProtocol,
    in context: some SwiftSyntaxMacros.MacroExpansionContext
  ) throws -> [SwiftSyntax.AccessorDeclSyntax] {

    guard let variableDecl = declaration.as(VariableDeclSyntax.self) else {
      return []
    }

    guard let binding = variableDecl.bindings.first,
      let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self)
    else {
      return []
    }

    let propertyName = identifierPattern.identifier.text

    guard variableDecl.isComputed == false else {
      context.addDiagnostics(from: Error.computedVariableIsNotSupported, node: declaration)
      return []
    }

    guard variableDecl.isConstant == false else {
      context.addDiagnostics(from: Error.constantVariableIsNotSupported, node: declaration)
      return []
    }

    guard variableDecl.isConstant == false else {
      fatalError()
    }

    if variableDecl.isWeak || variableDecl.isUnowned {

      let initAccessor = AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: .init(initialValue))
        }
        """
      )

      let readAccessor = AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue.value
        }
        """
      )

      let setAccessor = AccessorDeclSyntax(
        """
        set { 
          $\(raw: propertyName).wrappedValue.value = newValue
        }
        """
      )

      var accessors: [AccessorDeclSyntax] = []

      if binding.initializer == nil {
        accessors.append(initAccessor)
      }

      accessors.append(readAccessor)
      accessors.append(setAccessor)

      return accessors

    } else {

      let initAccessor = AccessorDeclSyntax(
        """
        @storageRestrictions(
          initializes: $\(raw: propertyName)
        )
        init(initialValue) {
          $\(raw: propertyName) = .init(wrappedValue: initialValue)
        }
        """
      )

      let readAccessor = AccessorDeclSyntax(
        """
        get {
          return $\(raw: propertyName).wrappedValue
        }
        """
      )

      let setAccessor = AccessorDeclSyntax(
        """
        set { 
          $\(raw: propertyName).wrappedValue = newValue
        }
        """
      )

      var accessors: [AccessorDeclSyntax] = []

      if binding.initializer == nil {
        accessors.append(initAccessor)
      }

      accessors.append(readAccessor)
      accessors.append(setAccessor)

      return accessors
    }
  }

}

extension VariableDeclSyntax {

  consuming func makeConstant() -> Self {
    self
      .with(\.bindingSpecifier, .keyword(.let))
      .with(\.modifiers, [])
  }

  consuming func inheritAccessControl(with other: VariableDeclSyntax) -> Self {

    let accessControlKinds: Set<TokenKind> = [
      .keyword(.private),
      .keyword(.fileprivate),
      .keyword(.internal),
      .keyword(.public),
      .keyword(.open),
    ]

    let accessControl = other.modifiers.filter {
      accessControlKinds.contains($0.name.tokenKind)
    }
    .map { $0 }

    return self.with(
      \.modifiers,
      modifiers.filter {
        !accessControlKinds.contains($0.name.tokenKind)
      } + accessControl)
  }

  consuming func makePrivate() -> Self {
    self.with(
      \.modifiers,
      [
        .init(name: .keyword(.private))
      ])
  }

  var isWeak: Bool {
    self.modifiers.contains {
      $0.name.tokenKind == .keyword(.weak)
    }
  }

  var isUnowned: Bool {
    self.modifiers.contains {
      $0.name.tokenKind == .keyword(.unowned)
    }
  }

  consuming func useModifier(sameAs: VariableDeclSyntax) -> Self {
    self.with(\.modifiers, sameAs.modifiers)
  }

  var hasInitializer: Bool {
    self.bindings.contains(where: { $0.initializer != nil })
  }

  var isConstant: Bool {
    return self.bindingSpecifier.tokenKind == .keyword(.let)
  }

  var isOptional: Bool {

    return self.bindings.contains(where: {
      $0.typeAnnotation?.type.is(OptionalTypeSyntax.self) ?? false
    })

  }

  var typeSyntax: TypeSyntax? {
    return self.bindings.first?.typeAnnotation?.type
  }

  func modifyingTypeAnnotation(_ modifier: (TypeSyntax) -> TypeSyntax) -> VariableDeclSyntax {
    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in
      if let typeAnnotation = binding.typeAnnotation {
        let newType = modifier(typeAnnotation.type)
        let newTypeAnnotation = typeAnnotation.with(\.type, newType)
        return binding.with(\.typeAnnotation, newTypeAnnotation)
      }
      return binding
    }

    return self.with(\.bindings, .init(newBindings))
  }

  func modifyingInit(_ modifier: (InitializerClauseSyntax) -> InitializerClauseSyntax)
    -> VariableDeclSyntax
  {

    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in
      if let initializer = binding.initializer {
        let newInitializer = modifier(initializer)
        return binding.with(\.initializer, newInitializer)
      }
      return binding
    }

    return self.with(\.bindings, .init(newBindings))
  }

  var name: String {
    return self.bindings.first?.pattern.as(IdentifierPatternSyntax.self)?.identifier.text ?? ""
  }

  func renamingIdentifier(with newName: String) -> VariableDeclSyntax {
    let newBindings = self.bindings.map { binding -> PatternBindingSyntax in

      if let identifierPattern = binding.pattern.as(IdentifierPatternSyntax.self) {

        let propertyName = identifierPattern.identifier.text

        let newIdentifierPattern = identifierPattern.with(
          \.identifier, "\(raw: newName)\(raw: propertyName)")
        return binding.with(\.pattern, .init(newIdentifierPattern))
      }
      return binding
    }

    return self.with(\.bindings, .init(newBindings))
  }

  func makeDidSetDoBlock() -> DoStmtSyntax {
    guard let didSetBlock = self.didSetBlock else {
      return .init(body: "{}")
    }

    return .init(body: didSetBlock)
  }

  func makeWillSetDoBlock() -> DoStmtSyntax {
    guard let willSetBlock = self.willSetBlock else {
      return .init(body: "{}")
    }

    return .init(body: willSetBlock)
  }

  var getBlock: CodeBlockItemListSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.get) {
              return accessor.body?.statements
            }
          }
        case .getter(let codeBlock):
          return codeBlock
        }
      }
    }
    return nil
  }

  var didSetBlock: CodeBlockSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.didSet) {
              return accessor.body
            }
          }
        case .getter(let _):
          return nil
        }
      }
    }
    return nil
  }

  var willSetBlock: CodeBlockSyntax? {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.willSet) {
              return accessor.body
            }
          }
        case .getter(let _):
          return nil
        }
      }
    }
    return nil
  }

  var isComputed: Bool {
    for binding in self.bindings {
      if let accessorBlock = binding.accessorBlock {
        switch accessorBlock.accessors {
        case .accessors(let accessors):
          for accessor in accessors {
            if accessor.accessorSpecifier.tokenKind == .keyword(.get) {
              return true
            }
          }
        case .getter:
          return true
        }
      }
    }
    return false
  }
}

extension TypeSyntax {
  func removingOptionality() -> Self {
    self.as(OptionalTypeSyntax.self).map {
      $0.wrappedType
    } ?? self
  }
}
