import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    GraphViewMacro.self,
    GraphComputedMacro.self,
    GraphComputedNodeMacro.self,
    IgnoredMacro.self,
    GraphStoredMacro.self,
  ]
}
