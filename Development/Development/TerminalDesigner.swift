//
//  BookTerminalColorSchemeEditor.swift
//  iOS18Play
//
//  Created by Muukii on 2025/06/07.
//

import SwiftUI
import StateGraph
import UniformTypeIdentifiers

struct ANSIColorPalette: Codable, Equatable {
  var black: Color = .black
  var red: Color = .red
  var green: Color = .green
  var yellow: Color = .yellow
  var blue: Color = .blue
  var magenta: Color = .purple
  var cyan: Color = .cyan
  var white: Color = .white
  var brightBlack: Color = .gray
  var brightRed: Color = Color(red: 1.0, green: 0.4, blue: 0.4)
  var brightGreen: Color = Color(red: 0.4, green: 1.0, blue: 0.4)
  var brightYellow: Color = Color(red: 1.0, green: 1.0, blue: 0.4)
  var brightBlue: Color = Color(red: 0.4, green: 0.4, blue: 1.0)
  var brightMagenta: Color = Color(red: 1.0, green: 0.4, blue: 1.0)
  var brightCyan: Color = Color(red: 0.4, green: 1.0, blue: 1.0)
  var brightWhite: Color = Color(red: 0.9, green: 0.9, blue: 0.9)
  
  var background: Color = .black
  var foreground: Color = .white
}

struct ANSIColorScheme: Codable, UserDefaultsStorable, Identifiable {
  var id: UUID = UUID()
  var name: String = "Untitled"
  var dark: ANSIColorPalette = ANSIColorPalette()
  var light: ANSIColorPalette = ANSIColorPalette(
    black: Color(white: 0.1),
    red: Color(red: 0.8, green: 0.0, blue: 0.0),
    green: Color(red: 0.0, green: 0.6, blue: 0.0),
    yellow: Color(red: 0.8, green: 0.6, blue: 0.0),
    blue: Color(red: 0.0, green: 0.4, blue: 0.8),
    magenta: Color(red: 0.7, green: 0.0, blue: 0.7),
    cyan: Color(red: 0.0, green: 0.6, blue: 0.6),
    white: Color(white: 0.7),
    brightBlack: Color(white: 0.3),
    brightRed: Color(red: 1.0, green: 0.3, blue: 0.3),
    brightGreen: Color(red: 0.3, green: 0.8, blue: 0.3),
    brightYellow: Color(red: 1.0, green: 0.8, blue: 0.3),
    brightBlue: Color(red: 0.3, green: 0.6, blue: 1.0),
    brightMagenta: Color(red: 0.9, green: 0.3, blue: 0.9),
    brightCyan: Color(red: 0.3, green: 0.8, blue: 0.8),
    brightWhite: Color(white: 0.9),
    background: Color(white: 0.95),
    foreground: Color(white: 0.1)
  )
  
  func duplicate() -> ANSIColorScheme {
    var copy = self
    copy.id = UUID()
    copy.name = "\(name) Copy"
    return copy
  }
}

struct ColorSchemeCollection: Codable, UserDefaultsStorable {
  var schemes: [ANSIColorScheme] = [ANSIColorScheme(name: "Default")]
  var selectedSchemeId: UUID?
  
  init() {
    let defaultScheme = ANSIColorScheme(name: "Default")
    self.schemes = [defaultScheme]
    self.selectedSchemeId = defaultScheme.id
  }
}

extension Color: Codable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let red = try container.decode(Double.self, forKey: .red)
    let green = try container.decode(Double.self, forKey: .green)
    let blue = try container.decode(Double.self, forKey: .blue)
    let alpha = try container.decode(Double.self, forKey: .alpha)
    self.init(red: red, green: green, blue: blue, opacity: alpha)
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let uiColor = UIColor(self)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    try container.encode(Double(red), forKey: .red)
    try container.encode(Double(green), forKey: .green)
    try container.encode(Double(blue), forKey: .blue)
    try container.encode(Double(alpha), forKey: .alpha)
  }
  
  private enum CodingKeys: String, CodingKey {
    case red, green, blue, alpha
  }
}

extension ANSIColorScheme {
  func toITermColors() -> String {
    func colorDict(_ color: Color, colorSpace: String = "P3") -> String {
      let uiColor = UIColor(color)
      var red: CGFloat = 0
      var green: CGFloat = 0
      var blue: CGFloat = 0
      var alpha: CGFloat = 0
      uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
      
      return """
        <dict>
          <key>Alpha Component</key>
          <real>\(alpha)</real>
          <key>Blue Component</key>
          <real>\(blue)</real>
          <key>Color Space</key>
          <string>\(colorSpace)</string>
          <key>Green Component</key>
          <real>\(green)</real>
          <key>Red Component</key>
          <real>\(red)</real>
        </dict>
      """
    }
    
    func generateColorEntries(for palette: ANSIColorPalette, suffix: String) -> String {
      return """
        <key>Ansi 0 Color\(suffix)</key>
      \(colorDict(palette.black))
        <key>Ansi 1 Color\(suffix)</key>
      \(colorDict(palette.red))
        <key>Ansi 2 Color\(suffix)</key>
      \(colorDict(palette.green))
        <key>Ansi 3 Color\(suffix)</key>
      \(colorDict(palette.yellow))
        <key>Ansi 4 Color\(suffix)</key>
      \(colorDict(palette.blue))
        <key>Ansi 5 Color\(suffix)</key>
      \(colorDict(palette.magenta))
        <key>Ansi 6 Color\(suffix)</key>
      \(colorDict(palette.cyan))
        <key>Ansi 7 Color\(suffix)</key>
      \(colorDict(palette.white))
        <key>Ansi 8 Color\(suffix)</key>
      \(colorDict(palette.brightBlack))
        <key>Ansi 9 Color\(suffix)</key>
      \(colorDict(palette.brightRed))
        <key>Ansi 10 Color\(suffix)</key>
      \(colorDict(palette.brightGreen))
        <key>Ansi 11 Color\(suffix)</key>
      \(colorDict(palette.brightYellow))
        <key>Ansi 12 Color\(suffix)</key>
      \(colorDict(palette.brightBlue))
        <key>Ansi 13 Color\(suffix)</key>
      \(colorDict(palette.brightMagenta))
        <key>Ansi 14 Color\(suffix)</key>
      \(colorDict(palette.brightCyan))
        <key>Ansi 15 Color\(suffix)</key>
      \(colorDict(palette.brightWhite))
        <key>Background Color\(suffix)</key>
      \(colorDict(palette.background))
        <key>Bold Color\(suffix)</key>
      \(colorDict(palette.brightWhite))
        <key>Cursor Color\(suffix)</key>
      \(colorDict(palette.white.opacity(0.8)))
        <key>Cursor Text Color\(suffix)</key>
      \(colorDict(palette.background))
        <key>Foreground Color\(suffix)</key>
      \(colorDict(palette.foreground))
        <key>Selected Text Color\(suffix)</key>
      \(colorDict(palette.background))
        <key>Selection Color\(suffix)</key>
      \(colorDict(palette.foreground.opacity(0.3)))
      """
    }
    
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      \(generateColorEntries(for: dark, suffix: " (Dark)"))
      \(generateColorEntries(for: light, suffix: " (Light)"))
        <key>Cursor Guide Color</key>
        <dict>
          <key>Alpha Component</key>
          <real>0.25</real>
          <key>Blue Component</key>
          <real>0.99125725030899048</real>
          <key>Color Space</key>
          <string>P3</string>
          <key>Green Component</key>
          <real>0.92047786712646484</real>
          <key>Red Component</key>
          <real>0.74862593412399292</real>
        </dict>
      </dict>
      </plist>
      """
  }
}

extension UTType {
  static let iTermColors = UTType(exportedAs: "com.googlecode.iterm2.itermcolors")
}

struct ITermColorsDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.iTermColors] }
  
  let colorScheme: ANSIColorScheme
  
  init(colorScheme: ANSIColorScheme) {
    self.colorScheme = colorScheme
  }
  
  init(configuration: ReadConfiguration) throws {
    throw CocoaError(.fileReadCorruptFile)
  }
  
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let data = colorScheme.toITermColors().data(using: .utf8)!
    return FileWrapper(regularFileWithContents: data)
  }
}

final class TerminalColorSchemeStore: GraphObject {
  @GraphStored(backed: .userDefaults(key: "terminalColorSchemeCollection")) 
  var collection: ColorSchemeCollection = ColorSchemeCollection()
  
  var selectedScheme: ANSIColorScheme? {
    guard let selectedId = collection.selectedSchemeId else {
      return collection.schemes.first
    }
    return collection.schemes.first { $0.id == selectedId }
  }
  
  func selectScheme(_ scheme: ANSIColorScheme) {
    collection.selectedSchemeId = scheme.id
  }
  
  func addNewScheme() {
    let newScheme = ANSIColorScheme(name: "New Scheme")
    collection.schemes.append(newScheme)
    collection.selectedSchemeId = newScheme.id
  }
  
  func duplicateScheme(_ scheme: ANSIColorScheme) {
    let duplicate = scheme.duplicate()
    collection.schemes.append(duplicate)
    collection.selectedSchemeId = duplicate.id
  }
  
  func deleteScheme(_ scheme: ANSIColorScheme) {
    collection.schemes.removeAll { $0.id == scheme.id }
    if collection.selectedSchemeId == scheme.id {
      collection.selectedSchemeId = collection.schemes.first?.id
    }
  }
  
  func updateScheme(_ scheme: ANSIColorScheme) {
    if let index = collection.schemes.firstIndex(where: { $0.id == scheme.id }) {
      collection.schemes[index] = scheme
    }
  }
}

private struct ColorPickerRow: View {
  let title: String
  @Binding var color: Color
  
  var body: some View {
    HStack {
      Text(title)
        .frame(width: 120, alignment: .leading)
      ColorPicker("", selection: $color)
        .labelsHidden()
    }
  }
}

struct TerminalPreview: View {
  let colorPalette: ANSIColorPalette
  
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Terminal Preview")
        .font(.headline)
        .padding(.bottom, 8)
      
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorPalette.green)
          Text("ls -la")
            .foregroundColor(colorPalette.foreground)
        }
        
        Text("total 64")
          .foregroundColor(colorPalette.foreground)
        
        HStack(spacing: 0) {
          Text("drwxr-xr-x")
            .foregroundColor(colorPalette.blue)
          Text("  5 user  staff   160 ")
            .foregroundColor(colorPalette.foreground)
          Text("Dec  7 10:30 ")
            .foregroundColor(colorPalette.cyan)
          Text("Documents")
            .foregroundColor(colorPalette.blue)
        }
        
        HStack(spacing: 0) {
          Text("-rw-r--r--")
            .foregroundColor(colorPalette.foreground)
          Text("  1 user  staff  1024 ")
            .foregroundColor(colorPalette.foreground)
          Text("Dec  7 09:15 ")
            .foregroundColor(colorPalette.cyan)
          Text("README.md")
            .foregroundColor(colorPalette.foreground)
        }
        
        HStack(spacing: 0) {
          Text("-rwxr-xr-x")
            .foregroundColor(colorPalette.green)
          Text("  1 user  staff  2048 ")
            .foregroundColor(colorPalette.foreground)
          Text("Dec  6 14:22 ")
            .foregroundColor(colorPalette.cyan)
          Text("script.sh")
            .foregroundColor(colorPalette.green)
        }
        
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorPalette.green)
          Text("echo ")
            .foregroundColor(colorPalette.foreground)
          Text("\"")
            .foregroundColor(colorPalette.yellow)
          Text("Hello, World!")
            .foregroundColor(colorPalette.yellow)
          Text("\"")
            .foregroundColor(colorPalette.yellow)
        }
        
        Text("Hello, World!")
          .foregroundColor(colorPalette.foreground)
        
        HStack(spacing: 0) {
          Text("user@hostname:~$ ")
            .foregroundColor(colorPalette.green)
          Text("■")
            .foregroundColor(colorPalette.foreground)
            .blinking()
        }
      }
    }
    .font(.system(.body, design: .monospaced))
    .padding()
    .background(colorPalette.background)
    .border(Color.gray, width: 1)
  }
}

extension View {
  func blinking(duration: Double = 1.0) -> some View {
    self.opacity(0.3)
      .animation(.easeInOut(duration: duration).repeatForever(), value: UUID())
  }
}

struct ColorSchemeEditorWrapper: View {
  let store: TerminalColorSchemeStore
  let schemeId: UUID
  @State private var isExporting = false
  @State private var exportedDocument = ITermColorsDocument(colorScheme: ANSIColorScheme())
  
  var scheme: ANSIColorScheme? {
    store.collection.schemes.first { $0.id == schemeId }
  }
  
  var body: some View {
    if let scheme = scheme {
      VStack(spacing: 20) {
        HStack {
          Text("Terminal Color Designer")
            .font(.largeTitle)
            .bold()
          
          Spacer()
          
          Button("Export iTerm Colors") {
            exportedDocument = ITermColorsDocument(colorScheme: scheme)
            isExporting = true
          }
          .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        
        ColorSchemeEditor(
          store: store,
          scheme: scheme,
          onUpdate: { updatedScheme in
            store.updateScheme(updatedScheme)
          }
        )
      }
      .padding()
      .navigationBarTitleDisplayMode(.inline)
      .fileExporter(
        isPresented: $isExporting,
        document: exportedDocument,
        contentType: .iTermColors,
        defaultFilename: "\(scheme.name).itermcolors"
      ) { result in
        switch result {
        case .success(let url):
          print("Exported to: \(url)")
        case .failure(let error):
          print("Export failed: \(error)")
        }
      }
    } else {
      Text("Scheme not found")
        .foregroundColor(.secondary)
    }
  }
}

struct ColorSchemeEditor: View {
  let store: TerminalColorSchemeStore
  @State var scheme: ANSIColorScheme
  @State private var selectedMode: ColorMode = .dark
  let onUpdate: (ANSIColorScheme) -> Void
  
  enum ColorMode: String, CaseIterable {
    case dark = "Dark"
    case light = "Light"
  }
  
  var currentPalette: ANSIColorPalette {
    selectedMode == .dark ? scheme.dark : scheme.light
  }
  
  var body: some View {
    VStack(spacing: 20) {
      HStack {
        TextField("Scheme Name", text: $scheme.name)
          .textFieldStyle(RoundedBorderTextFieldStyle())
          .frame(width: 200)
          .onChange(of: scheme.name) { _ in
            onUpdate(scheme)
          }
        
        Spacer()
        
        Picker("Mode", selection: $selectedMode) {
          ForEach(ColorMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(SegmentedPickerStyle())
        .frame(width: 200)
      }
      
      TerminalPreview(colorPalette: currentPalette)
      
      VStack(spacing: 16) {
        HStack(alignment: .top, spacing: 20) {
          VStack(alignment: .leading, spacing: 8) {
            Text("ANSI Colors")
              .font(.headline)
            
            Group {
              if selectedMode == .dark {
                ColorPickerRow(title: "Black", color: Binding(
                  get: { scheme.dark.black },
                  set: { scheme.dark.black = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Red", color: Binding(
                  get: { scheme.dark.red },
                  set: { scheme.dark.red = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Green", color: Binding(
                  get: { scheme.dark.green },
                  set: { scheme.dark.green = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Yellow", color: Binding(
                  get: { scheme.dark.yellow },
                  set: { scheme.dark.yellow = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Blue", color: Binding(
                  get: { scheme.dark.blue },
                  set: { scheme.dark.blue = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Magenta", color: Binding(
                  get: { scheme.dark.magenta },
                  set: { scheme.dark.magenta = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Cyan", color: Binding(
                  get: { scheme.dark.cyan },
                  set: { scheme.dark.cyan = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "White", color: Binding(
                  get: { scheme.dark.white },
                  set: { scheme.dark.white = $0; onUpdate(scheme) }
                ))
              } else {
                ColorPickerRow(title: "Black", color: Binding(
                  get: { scheme.light.black },
                  set: { scheme.light.black = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Red", color: Binding(
                  get: { scheme.light.red },
                  set: { scheme.light.red = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Green", color: Binding(
                  get: { scheme.light.green },
                  set: { scheme.light.green = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Yellow", color: Binding(
                  get: { scheme.light.yellow },
                  set: { scheme.light.yellow = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Blue", color: Binding(
                  get: { scheme.light.blue },
                  set: { scheme.light.blue = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Magenta", color: Binding(
                  get: { scheme.light.magenta },
                  set: { scheme.light.magenta = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Cyan", color: Binding(
                  get: { scheme.light.cyan },
                  set: { scheme.light.cyan = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "White", color: Binding(
                  get: { scheme.light.white },
                  set: { scheme.light.white = $0; onUpdate(scheme) }
                ))
              }
            }
          }
          
          VStack(alignment: .leading, spacing: 8) {
            Text("Bright Colors")
              .font(.headline)
            
            Group {
              if selectedMode == .dark {
                ColorPickerRow(title: "Bright Black", color: Binding(
                  get: { scheme.dark.brightBlack },
                  set: { scheme.dark.brightBlack = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Red", color: Binding(
                  get: { scheme.dark.brightRed },
                  set: { scheme.dark.brightRed = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Green", color: Binding(
                  get: { scheme.dark.brightGreen },
                  set: { scheme.dark.brightGreen = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Yellow", color: Binding(
                  get: { scheme.dark.brightYellow },
                  set: { scheme.dark.brightYellow = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Blue", color: Binding(
                  get: { scheme.dark.brightBlue },
                  set: { scheme.dark.brightBlue = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Magenta", color: Binding(
                  get: { scheme.dark.brightMagenta },
                  set: { scheme.dark.brightMagenta = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Cyan", color: Binding(
                  get: { scheme.dark.brightCyan },
                  set: { scheme.dark.brightCyan = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright White", color: Binding(
                  get: { scheme.dark.brightWhite },
                  set: { scheme.dark.brightWhite = $0; onUpdate(scheme) }
                ))
              } else {
                ColorPickerRow(title: "Bright Black", color: Binding(
                  get: { scheme.light.brightBlack },
                  set: { scheme.light.brightBlack = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Red", color: Binding(
                  get: { scheme.light.brightRed },
                  set: { scheme.light.brightRed = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Green", color: Binding(
                  get: { scheme.light.brightGreen },
                  set: { scheme.light.brightGreen = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Yellow", color: Binding(
                  get: { scheme.light.brightYellow },
                  set: { scheme.light.brightYellow = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Blue", color: Binding(
                  get: { scheme.light.brightBlue },
                  set: { scheme.light.brightBlue = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Magenta", color: Binding(
                  get: { scheme.light.brightMagenta },
                  set: { scheme.light.brightMagenta = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright Cyan", color: Binding(
                  get: { scheme.light.brightCyan },
                  set: { scheme.light.brightCyan = $0; onUpdate(scheme) }
                ))
                ColorPickerRow(title: "Bright White", color: Binding(
                  get: { scheme.light.brightWhite },
                  set: { scheme.light.brightWhite = $0; onUpdate(scheme) }
                ))
              }
            }
          }
        }
        
        VStack(alignment: .leading, spacing: 8) {
          Text("Terminal")
            .font(.headline)
          
          HStack(spacing: 40) {
            if selectedMode == .dark {
              ColorPickerRow(title: "Background", color: Binding(
                get: { scheme.dark.background },
                set: { scheme.dark.background = $0; onUpdate(scheme) }
              ))
              ColorPickerRow(title: "Foreground", color: Binding(
                get: { scheme.dark.foreground },
                set: { scheme.dark.foreground = $0; onUpdate(scheme) }
              ))
            } else {
              ColorPickerRow(title: "Background", color: Binding(
                get: { scheme.light.background },
                set: { scheme.light.background = $0; onUpdate(scheme) }
              ))
              ColorPickerRow(title: "Foreground", color: Binding(
                get: { scheme.light.foreground },
                set: { scheme.light.foreground = $0; onUpdate(scheme) }
              ))
            }
          }
        }
      }
      .padding()
    }
  }
}

struct TerminalColorDesigner: View {
  let store = TerminalColorSchemeStore()
  @State private var showingDeleteConfirmation = false
  @State private var schemeToDelete: ANSIColorScheme?
  
  var body: some View {
    NavigationView {
      List {
        Section(header: Text("Schemes")) {
          ForEach(store.collection.schemes) { scheme in
            NavigationLink(
              destination: ColorSchemeEditorWrapper(store: store, schemeId: scheme.id)
                .onAppear {
                  store.selectScheme(scheme)
                }
            ) {
              HStack {
                Text(scheme.name)
                Spacer()
                if scheme.id == store.collection.selectedSchemeId {
                  Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                }
              }
            }
            .contextMenu {
              Button("Duplicate") {
                store.duplicateScheme(scheme)
              }
              if store.collection.schemes.count > 1 {
                Button("Delete", role: .destructive) {
                  schemeToDelete = scheme
                  showingDeleteConfirmation = true
                }
              }
            }
          }
        }
        
        Section {
          Button(action: {
            store.addNewScheme()
          }) {
            Label("Add New Scheme", systemImage: "plus.circle")
          }
        }
      }
      .listStyle(SidebarListStyle())
      .navigationTitle("Schemes")
      .frame(minWidth: 250)
      
      Text("Select a color scheme")
        .font(.title2)
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .alert("Delete Scheme?", isPresented: $showingDeleteConfirmation) {
      Button("Cancel", role: .cancel) {
        schemeToDelete = nil
      }
      Button("Delete", role: .destructive) {
        if let scheme = schemeToDelete {
          store.deleteScheme(scheme)
        }
        schemeToDelete = nil
      }
    } message: {
      Text("Are you sure you want to delete \"\(schemeToDelete?.name ?? "")\"? This action cannot be undone.")
    }
  }
}

#Preview("TerminalColorScheme") {
  TerminalColorDesigner()
}
