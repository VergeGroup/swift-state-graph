import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// Provides macros owned by the StateGraphNormalization module.
@main
struct Plugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [
    InitAndUpdateMacro.self,
    OnInitMarkerMacro.self,
    OnUpdateMarkerMacro.self,
  ]
}
