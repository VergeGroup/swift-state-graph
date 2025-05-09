
import SwiftSyntax

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
