import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    GraphViewMacro.self,
    ComputedMacro.self,
    IgnoredMacro.self,
    UnifiedStoredMacro.self,
  ]
}
