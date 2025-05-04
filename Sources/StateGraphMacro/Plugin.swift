import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    GraphViewMacro.self,
    StoredMacro.self,
    ComputedMacro.self,
    IgnoredMacro.self,
    ComputedMacro.self,
  ]
}
