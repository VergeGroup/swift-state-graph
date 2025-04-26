//
//  ComputedMacro.swift
//  swift-state-graph
//
//  Created by Muukii on 2025/04/25.
//

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct ComputedMacro {

  public enum Error: Swift.Error {
    case needsTypeAnnotation
  }

}

extension ComputedMacro: PeerMacro {

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

    let isPublic = variableDecl.modifiers.contains(where: { $0.name.tokenKind == .keyword(.public) }
    )
    let isPrivate = variableDecl.modifiers.contains(where: {
      $0.name.tokenKind == .keyword(.private)
    })

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

    var _variableDecl = variableDecl.trimmed
    _variableDecl.attributes = [.init(.init(stringLiteral: "@Ignored"))]
    _variableDecl = _variableDecl.with(\.modifiers, [.init(name: .keyword(.private))])

    if variableDecl.isOptional {
      _variableDecl =
        _variableDecl
        .renamingIdentifier(with: "_backing_")
        .modifyingTypeAnnotation({ type in
          return "StateNode<\(type.trimmed)>?"
        })

      //      // add init
      //      _variableDecl = _variableDecl.with(
      //        \.bindings,
      //         .init(
      //          _variableDecl.bindings.map { binding in
      //            binding.with(\.initializer, .init(value: "StateNode.init(nil)" as ExprSyntax))
      //          })
      //      )

    } else {
      _variableDecl =
        _variableDecl
        .renamingIdentifier(with: "_backing_")
        .modifyingTypeAnnotation({ type in
          return "StateNode<\(type.trimmed)>?"
        })
      //        .modifyingInit({ initializer in
      //          return .init(value: "StateNode.init(\(initializer.trimmed.value))" as ExprSyntax)
      //        })
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

extension ComputedMacro: BodyMacro {

  public static func expansion(
    of node: AttributeSyntax,
    providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
    in context: some MacroExpansionContext
  ) throws -> [CodeBlockItemSyntax] {
    
    [
            """
            "hello," + \(declaration.body!)
            """
    ]
  }
}
