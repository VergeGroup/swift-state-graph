//
//  IgnoredMacro.swift
//  swift-state-graph
//
//  Created by Muukii on 2025/04/25.
//

import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct IgnoredMacro: Macro {
  
}

extension IgnoredMacro: PeerMacro {
  public static func expansion(of node: AttributeSyntax, providingPeersOf declaration: some DeclSyntaxProtocol, in context: some MacroExpansionContext) throws -> [DeclSyntax] {
    return []
  }
}

