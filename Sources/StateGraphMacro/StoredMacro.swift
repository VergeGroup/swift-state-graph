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

    _variableDecl.attributes = [.init(.init(stringLiteral: "@GraphIgnored"))]

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
