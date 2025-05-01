
struct SourceLocation: ~Copyable {
  
  let file: StaticString
  let line: UInt
  let column: UInt
  
  init(file: StaticString, line: UInt, column: UInt) {
    self.file = file
    self.line = line
    self.column = column
  }
  
  var text: String {
    "\(file):\(line):\(column)"
  }
  
}
