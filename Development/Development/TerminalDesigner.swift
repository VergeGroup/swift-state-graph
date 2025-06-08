//
//  BookTerminalColorSchemeEditor.swift
//  iOS18Play
//
//  Created by Muukii on 2025/06/07.
//

import SwiftUI
import StateGraph
import UniformTypeIdentifiers
import PhotosUI

// MARK: - Views

struct TerminalColorDesigner: View {
  let store = TerminalColorSchemeStore()
  @State private var showingDeleteConfirmation = false
  @State private var schemeToDelete: ANSIColorScheme?
  @State private var showingDuplicateDialog = false
  @State private var schemeToDuplicate: ANSIColorScheme?
  @State private var duplicateName = ""
  @State private var showingRenameDialog = false
  @State private var schemeToRename: ANSIColorScheme?
  @State private var renameName = ""
  @State private var showingImagePicker = false
  @State private var selectedPhotoItem: PhotosPickerItem?
  @State private var showingColorPicker = false
  @State private var baseColor = Color.blue
  
  var body: some View {
    NavigationView {
      List {
        Section(header: Text("Schemes")) {
          ForEach(store.collection.schemes) { scheme in
            NavigationLink(
              destination: ColorSchemeEditorWrapper(store: store, schemeId: scheme.id)
            ) {
              HStack {
                Text(scheme.name)
                Spacer()                
              }
            }
            .contextMenu {
              Button("Rename") {
                schemeToRename = scheme
                renameName = scheme.name
                showingRenameDialog = true
              }
              Button("Duplicate") {
                schemeToDuplicate = scheme
                duplicateName = "\(scheme.name) Copy"
                showingDuplicateDialog = true
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
          
          PhotosPicker(selection: $selectedPhotoItem,
                      matching: .images) {
            Label("Create from Image", systemImage: "photo")
          }
          
          Button(action: {
            showingColorPicker = true
          }) {
            Label("Create from Color", systemImage: "paintpalette")
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
    .alert("Duplicate Scheme", isPresented: $showingDuplicateDialog) {
      TextField("Scheme Name", text: $duplicateName)
      Button("Cancel", role: .cancel) {
        schemeToDuplicate = nil
        duplicateName = ""
      }
      Button("Duplicate") {
        if let scheme = schemeToDuplicate, !duplicateName.isEmpty {
          store.duplicateScheme(scheme, withName: duplicateName)
        }
        schemeToDuplicate = nil
        duplicateName = ""
      }
    } message: {
      Text("Enter a name for the duplicated scheme")
    }
    .alert("Rename Scheme", isPresented: $showingRenameDialog) {
      TextField("Scheme Name", text: $renameName)
      Button("Cancel", role: .cancel) {
        schemeToRename = nil
        renameName = ""
      }
      Button("Rename") {
        if let scheme = schemeToRename, !renameName.isEmpty {
          store.renameScheme(scheme, to: renameName)
        }
        schemeToRename = nil
        renameName = ""
      }
    } message: {
      Text("Enter a new name for the scheme")
    }
    .onChange(of: selectedPhotoItem) { item in
      Task {
        if let item = item,
           let data = try? await item.loadTransferable(type: Data.self),
           let uiImage = UIImage(data: data) {
          await MainActor.run {
            let colorScheme = createColorScheme(from: uiImage)
            store.collection.schemes.append(colorScheme)
            selectedPhotoItem = nil
          }
        }
      }
    }
    .sheet(isPresented: $showingColorPicker) {
      ColorAlgorithmPicker(baseColor: $baseColor) { algorithm in
        let scheme = createColorScheme(from: baseColor, algorithm: algorithm)
        store.collection.schemes.append(scheme)
        showingColorPicker = false
      }
    }
  }
  
  private func createColorScheme(from image: UIImage) -> ANSIColorScheme {
    let colors = extractColors(from: image)
    
    var scheme = ANSIColorScheme(name: "Image Palette")
    
    // Create dark palette
    scheme.dark.background = colors.darkest
    scheme.dark.foreground = colors.lightest
    scheme.dark.black = colors.darkest
    scheme.dark.white = colors.lightest
    scheme.dark.red = colors.red
    scheme.dark.green = colors.green
    scheme.dark.blue = colors.blue
    scheme.dark.yellow = colors.yellow
    scheme.dark.magenta = colors.magenta
    scheme.dark.cyan = colors.cyan
    scheme.dark.brightBlack = colors.mediumDark
    scheme.dark.brightWhite = colors.mediumLight
    scheme.dark.brightRed = colors.brightRed
    scheme.dark.brightGreen = colors.brightGreen
    scheme.dark.brightBlue = colors.brightBlue
    scheme.dark.brightYellow = colors.brightYellow
    scheme.dark.brightMagenta = colors.brightMagenta
    scheme.dark.brightCyan = colors.brightCyan
    
    // Create light palette (inverted)
    scheme.light.background = colors.lightest
    scheme.light.foreground = colors.darkest
    scheme.light.black = colors.darkest
    scheme.light.white = colors.lightest
    scheme.light.red = colors.red
    scheme.light.green = colors.green
    scheme.light.blue = colors.blue
    scheme.light.yellow = colors.yellow
    scheme.light.magenta = colors.magenta
    scheme.light.cyan = colors.cyan
    scheme.light.brightBlack = colors.mediumDark
    scheme.light.brightWhite = colors.mediumLight
    scheme.light.brightRed = colors.brightRed.darkened(by: 0.2)
    scheme.light.brightGreen = colors.brightGreen.darkened(by: 0.2)
    scheme.light.brightBlue = colors.brightBlue.darkened(by: 0.2)
    scheme.light.brightYellow = colors.brightYellow.darkened(by: 0.2)
    scheme.light.brightMagenta = colors.brightMagenta.darkened(by: 0.2)
    scheme.light.brightCyan = colors.brightCyan.darkened(by: 0.2)
    
    return scheme
  }
  
  private func extractColors(from image: UIImage) -> ExtractedColors {
    // Resize image for faster processing
    let size = CGSize(width: 100, height: 100)
    UIGraphicsBeginImageContext(size)
    image.draw(in: CGRect(origin: .zero, size: size))
    let resizedImage = UIGraphicsGetImageFromCurrentImageContext()!
    UIGraphicsEndImageContext()
    
    // Get pixel data
    guard let cgImage = resizedImage.cgImage,
          let data = cgImage.dataProvider?.data,
          let pixels = CFDataGetBytePtr(data) else {
      return ExtractedColors.default
    }
    
    let width = cgImage.width
    let height = cgImage.height
    let bytesPerPixel = 4
    let bytesPerRow = bytesPerPixel * width
    
    var colorCounts: [UIColor: Int] = [:]
    
    // Sample pixels
    for y in stride(from: 0, to: height, by: 5) {
      for x in stride(from: 0, to: width, by: 5) {
        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
        let r = CGFloat(pixels[offset]) / 255.0
        let g = CGFloat(pixels[offset + 1]) / 255.0
        let b = CGFloat(pixels[offset + 2]) / 255.0
        
        let color = UIColor(red: r, green: g, blue: b, alpha: 1.0)
        colorCounts[color, default: 0] += 1
      }
    }
    
    // Get dominant colors
    let sortedColors = colorCounts.sorted { $0.value > $1.value }
      .map { $0.key }
      .prefix(50)
    
    var extractedColors = ExtractedColors()
    
    // Find darkest and lightest
    extractedColors.darkest = Color(sortedColors.min { $0.brightness < $1.brightness } ?? .black)
    extractedColors.lightest = Color(sortedColors.max { $0.brightness < $1.brightness } ?? .white)
    
    // Find medium tones
    let mediumColors = sortedColors.filter { $0.brightness > 0.3 && $0.brightness < 0.7 }
    extractedColors.mediumDark = Color(mediumColors.first { $0.brightness < 0.5 } ?? .gray)
    extractedColors.mediumLight = Color(mediumColors.first { $0.brightness > 0.5 } ?? .lightGray)
    
    // Extract vibrant colors
    let vibrantColors = sortedColors.filter { $0.saturation > 0.3 }
    
    // Find colors by hue
    extractedColors.red = Color(vibrantColors.first { $0.isRedHue } ?? .red)
    extractedColors.green = Color(vibrantColors.first { $0.isGreenHue } ?? .green)
    extractedColors.blue = Color(vibrantColors.first { $0.isBlueHue } ?? .blue)
    extractedColors.yellow = Color(vibrantColors.first { $0.isYellowHue } ?? .yellow)
    extractedColors.magenta = Color(vibrantColors.first { $0.isMagentaHue } ?? .purple)
    extractedColors.cyan = Color(vibrantColors.first { $0.isCyanHue } ?? .cyan)
    
    // Create bright versions
    extractedColors.brightRed = extractedColors.red.brightened(by: 0.3)
    extractedColors.brightGreen = extractedColors.green.brightened(by: 0.3)
    extractedColors.brightBlue = extractedColors.blue.brightened(by: 0.3)
    extractedColors.brightYellow = extractedColors.yellow.brightened(by: 0.3)
    extractedColors.brightMagenta = extractedColors.magenta.brightened(by: 0.3)
    extractedColors.brightCyan = extractedColors.cyan.brightened(by: 0.3)
    
    return extractedColors
  }
  
  private func createColorScheme(from baseColor: Color, algorithm: ColorAlgorithm) -> ANSIColorScheme {
    var scheme = ANSIColorScheme(name: "\(algorithm.name) Palette")
    let palette = algorithm.generatePalette(from: baseColor)
    
    // Apply generated palette to dark mode
    scheme.dark = palette.dark
    
    // Apply generated palette to light mode
    scheme.light = palette.light
    
    return scheme
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
      ColorSchemeEditor(
        store: store,
        scheme: scheme,
        onUpdate: { updatedScheme in
          store.updateScheme(updatedScheme)
        }
      )
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button(action: {
            exportedDocument = ITermColorsDocument(colorScheme: scheme)
            isExporting = true
          }) {
            Label("Export", systemImage: "square.and.arrow.up")
          }
        }
      }
      .navigationTitle(scheme.name)
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
  
  var currentPalette: ANSIColorPalette {
    selectedMode == .dark ? scheme.dark : scheme.light
  }
  
  var body: some View {
    VStack(spacing: 0) {
      ColorSchemeHeader(
        scheme: $scheme,
        selectedMode: $selectedMode,
        currentPalette: currentPalette,
        onUpdate: onUpdate
      )
      
      ColorGridView(
        scheme: $scheme,
        selectedMode: selectedMode,
        onUpdate: onUpdate
      )
    }
  }
}

struct ColorSchemeHeader: View {
  @Binding var scheme: ANSIColorScheme
  @Binding var selectedMode: ColorMode
  let currentPalette: ANSIColorPalette
  let onUpdate: (ANSIColorScheme) -> Void
  
  var body: some View {
    VStack(spacing: 12) {
      HStack {
        TextField("Scheme Name", text: $scheme.name)
          .textFieldStyle(.plain)
          .font(.title3)
          .fontWeight(.semibold)
          .onChange(of: scheme.name) { _ in
            onUpdate(scheme)
          }
        
        Spacer()
        
        Picker("", selection: $selectedMode) {
          ForEach(ColorMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(SegmentedPickerStyle())
        .frame(width: 120)
      }
      
      TerminalPreview(colorPalette: currentPalette)
        .frame(height: 100)
    }
    .padding()
    .background(Color(UIColor.systemBackground))
    .overlay(
      Rectangle()
        .fill(Color(UIColor.separator))
        .frame(height: 0.5),
      alignment: .bottom
    )
  }
}

struct ColorGridView: View {
  @Binding var scheme: ANSIColorScheme
  let selectedMode: ColorMode
  let onUpdate: (ANSIColorScheme) -> Void
  
  var body: some View {
    ScrollView {
      VStack(spacing: 0) {
        LazyVGrid(columns: [
          GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 10)
        ], spacing: 10) {
          Group {
            ColorPickerItem(name: "Black", color: colorBinding(\.black))
            ColorPickerItem(name: "Red", color: colorBinding(\.red))
            ColorPickerItem(name: "Green", color: colorBinding(\.green))
            ColorPickerItem(name: "Yellow", color: colorBinding(\.yellow))
            ColorPickerItem(name: "Blue", color: colorBinding(\.blue))
            ColorPickerItem(name: "Magenta", color: colorBinding(\.magenta))
            ColorPickerItem(name: "Cyan", color: colorBinding(\.cyan))
            ColorPickerItem(name: "White", color: colorBinding(\.white))
          }
          
          Group {
            ColorPickerItem(name: "Bright Black", color: colorBinding(\.brightBlack))
            ColorPickerItem(name: "Bright Red", color: colorBinding(\.brightRed))
            ColorPickerItem(name: "Bright Green", color: colorBinding(\.brightGreen))
            ColorPickerItem(name: "Bright Yellow", color: colorBinding(\.brightYellow))
            ColorPickerItem(name: "Bright Blue", color: colorBinding(\.brightBlue))
            ColorPickerItem(name: "Bright Magenta", color: colorBinding(\.brightMagenta))
            ColorPickerItem(name: "Bright Cyan", color: colorBinding(\.brightCyan))
            ColorPickerItem(name: "Bright White", color: colorBinding(\.brightWhite))
          }
          
          Group {
            ColorPickerItem(name: "Background", color: colorBinding(\.background))
            ColorPickerItem(name: "Foreground", color: colorBinding(\.foreground))
          }
        }
        .padding()
      }
    }
  }
  
  private func colorBinding(_ keyPath: WritableKeyPath<ANSIColorPalette, Color>) -> Binding<Color> {
    if selectedMode == .dark {
      return Binding(
        get: { scheme.dark[keyPath: keyPath] },
        set: { 
          scheme.dark[keyPath: keyPath] = $0
          onUpdate(scheme)
        }
      )
    } else {
      return Binding(
        get: { scheme.light[keyPath: keyPath] },
        set: { 
          scheme.light[keyPath: keyPath] = $0
          onUpdate(scheme)
        }
      )
    }
  }
}

struct ColorPickerItem: View {
  let name: String
  @Binding var color: Color
  
  var body: some View {
    UltraCompactColorPicker(title: name, color: $color)
  }
}

struct TerminalPreview: View {
  let colorPalette: ANSIColorPalette
  
  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: 0) {
        Text("$ ")
          .foregroundColor(colorPalette.green)
        Text("git diff")
          .foregroundColor(colorPalette.foreground)
      }
      
      HStack(spacing: 0) {
        Text("+ ")
          .foregroundColor(colorPalette.green)
        Text("const ")
          .foregroundColor(colorPalette.blue)
        Text("server")
          .foregroundColor(colorPalette.foreground)
        Text(" = ")
          .foregroundColor(colorPalette.foreground)
        Text("new ")
          .foregroundColor(colorPalette.magenta)
        Text("Server")
          .foregroundColor(colorPalette.yellow)
        Text("()")
          .foregroundColor(colorPalette.foreground)
      }
      
      HStack(spacing: 0) {
        Text("- ")
          .foregroundColor(colorPalette.red)
        Text("console")
          .foregroundColor(colorPalette.cyan)
        Text(".")
          .foregroundColor(colorPalette.foreground)
        Text("log")
          .foregroundColor(colorPalette.cyan)
        Text("(")
          .foregroundColor(colorPalette.foreground)
        Text("'debug'")
          .foregroundColor(colorPalette.green)
        Text(")")
          .foregroundColor(colorPalette.foreground)
      }
      
      HStack(spacing: 0) {
        Text("! ")
          .foregroundColor(colorPalette.yellow)
        Text("[WARNING] ")
          .foregroundColor(colorPalette.yellow)
        Text("Deprecated API")
          .foregroundColor(colorPalette.foreground)
      }
      
      HStack(spacing: 0) {
        Text("$ ")
          .foregroundColor(colorPalette.green)
        Text("■")
          .foregroundColor(colorPalette.foreground)
          .blinking()
      }
    }
    .font(.system(size: 11, weight: .medium, design: .monospaced))
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(colorPalette.background)
    .cornerRadius(10)
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .stroke(Color(UIColor.separator), lineWidth: 0.5)
    )
  }
}

// MARK: - UI Components

struct ColorAlgorithmPicker: View {
  @Binding var baseColor: Color
  let onSelect: (ColorAlgorithm) -> Void
  @State private var selectedAlgorithm: ColorAlgorithm = .complementary
  
  let algorithms: [ColorAlgorithm] = [
    .complementary,
    .analogous,
    .triadic,
    .tetradic,
    .monochromatic,
    .splitComplementary,
    .doubleComplementary,
    .pentadic,
    .shades,
    .tints,
    .tones,
    .warmCool
  ]
  
  var body: some View {
    NavigationView {
      VStack(spacing: 0) {
        // Fixed header
        VStack(spacing: 12) {
          Text("Select Base Color")
            .font(.headline)
          
          ColorPicker("Base Color", selection: $baseColor)
            .labelsHidden()
            .frame(width: 100, height: 100)
            .background(
              RoundedRectangle(cornerRadius: 12)
                .fill(Color(UIColor.secondarySystemGroupedBackground))
            )
        }
        .padding()
        .background(Color(UIColor.systemGroupedBackground))
        
        Text("Select Color Algorithm")
          .font(.headline)
          .padding(.top, 8)
          .padding(.bottom, 16)
        
        // Scrollable content
        ScrollView {
          LazyVGrid(columns: [
            GridItem(.flexible(minimum: 180, maximum: 200), spacing: 16),
            GridItem(.flexible(minimum: 180, maximum: 200), spacing: 16)
          ], spacing: 16) {
            ForEach(algorithms, id: \.self) { algorithm in
              Button(action: {
                selectedAlgorithm = algorithm
              }) {
                VStack(spacing: 8) {
                  ColorPalettePreview(
                    colors: algorithm.previewColors(from: baseColor),
                    size: 26
                  )
                  .frame(height: 30)
                  
                  Text(algorithm.name)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                  
                  Text(algorithm.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(minHeight: 30)
                }
                .padding(12)
                .frame(maxWidth: .infinity, minHeight: 120)
                .background(
                  RoundedRectangle(cornerRadius: 12)
                    .fill(selectedAlgorithm == algorithm ? 
                          Color.accentColor.opacity(0.2) : 
                          Color(UIColor.secondarySystemGroupedBackground))
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 12)
                    .stroke(selectedAlgorithm == algorithm ? 
                           Color.accentColor : 
                           Color.clear, lineWidth: 2)
                )
              }
              .buttonStyle(PlainButtonStyle())
            }
          }
          .padding(.horizontal)
          .padding(.bottom, 20)
        }
        
        // Fixed footer
        HStack {
          Button("Cancel") {
            onSelect(.complementary) // Dummy call, won't be used
          }
          .keyboardShortcut(.cancelAction)
          
          Spacer()
          
          Button("Create Scheme") {
            onSelect(selectedAlgorithm)
          }
          .keyboardShortcut(.defaultAction)
          .disabled(false)
        }
        .padding()
        .background(
          Rectangle()
            .fill(Color(UIColor.systemGroupedBackground))
            .overlay(
              Rectangle()
                .fill(Color(UIColor.separator))
                .frame(height: 0.5),
              alignment: .top
            )
        )
      }
      .navigationTitle("Create Color Scheme")
      .navigationBarTitleDisplayMode(.inline)
      .background(Color(UIColor.systemGroupedBackground))
    }
  }
}

struct ColorPalettePreview: View {
  let colors: [Color]
  let size: CGFloat
  
  var body: some View {
    HStack(spacing: 2) {
      ForEach(Array(colors.prefix(6).enumerated()), id: \.offset) { _, color in
        RoundedRectangle(cornerRadius: 4)
          .fill(color)
          .frame(width: size, height: size)
      }
    }
  }
}

struct UltraCompactColorPicker: View {
  let title: String
  @Binding var color: Color
  
  var body: some View {
    VStack(spacing: 6) {
      ColorPicker("", selection: $color)
        .labelsHidden()
        .frame(width: 44, height: 44)
        .background(
          RoundedRectangle(cornerRadius: 8)
            .fill(Color(UIColor.secondarySystemGroupedBackground))
        )
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Color(UIColor.separator), lineWidth: 0.5)
        )
      
      Text(title)
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
  }
}

struct CompactColorPicker: View {
  let title: String
  @Binding var color: Color
  
  var body: some View {
    HStack(spacing: 12) {
      ColorPicker("", selection: $color)
        .labelsHidden()
        .frame(width: 28, height: 28)
      
      Text(title)
        .font(.system(.body, design: .rounded))
        .foregroundColor(.primary)
      
      Spacer()
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(Color(UIColor.secondarySystemGroupedBackground))
    .cornerRadius(10)
  }
}

struct ColorSection: View {
  let title: String
  let colors: [(String, Binding<Color>)]
  
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(title)
        .font(.headline)
        .foregroundColor(.secondary)
      
      LazyVGrid(columns: [
        GridItem(.adaptive(minimum: 140), spacing: 16)
      ], spacing: 12) {
        ForEach(colors, id: \.0) { name, binding in
          CompactColorPicker(title: name, color: binding)
        }
      }
    }
  }
}

// MARK: - View Extensions

extension View {
  func blinking(duration: Double = 1.0) -> some View {
    self.opacity(0.3)
      .animation(.easeInOut(duration: duration).repeatForever(), value: UUID())
  }
}

// MARK: - Models

enum ColorMode: String, CaseIterable {
  case dark = "Dark"
  case light = "Light"
}

enum ColorAlgorithm: String, CaseIterable {
  case complementary
  case analogous
  case triadic
  case tetradic
  case monochromatic
  case splitComplementary
  case doubleComplementary
  case pentadic
  case shades
  case tints
  case tones
  case warmCool
  
  var name: String {
    switch self {
    case .complementary: return "Complementary"
    case .analogous: return "Analogous"
    case .triadic: return "Triadic"
    case .tetradic: return "Tetradic"
    case .monochromatic: return "Monochromatic"
    case .splitComplementary: return "Split-Complementary"
    case .doubleComplementary: return "Double Complementary"
    case .pentadic: return "Pentadic"
    case .shades: return "Shades"
    case .tints: return "Tints"
    case .tones: return "Tones"
    case .warmCool: return "Warm & Cool"
    }
  }
  
  var description: String {
    switch self {
    case .complementary: return "Opposite colors on the wheel"
    case .analogous: return "Adjacent colors for harmony"
    case .triadic: return "Three evenly spaced colors"
    case .tetradic: return "Four colors in two pairs"
    case .monochromatic: return "Shades of a single color"
    case .splitComplementary: return "Base + two adjacent complements"
    case .doubleComplementary: return "Two complementary pairs"
    case .pentadic: return "Five colors for variety"
    case .shades: return "Base color mixed with black"
    case .tints: return "Base color mixed with white"
    case .tones: return "Base color mixed with gray"
    case .warmCool: return "Warm and cool contrast"
    }
  }
  
  func previewColors(from base: Color) -> [Color] {
    let uiBase = UIColor(base)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    uiBase.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    
    switch self {
    case .complementary:
      return [base, Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)]
    case .analogous:
      return [
        Color(hue: (h - 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        base,
        Color(hue: (h + 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .triadic:
      return [
        base,
        Color(hue: (h + 0.333).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.667).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .tetradic:
      return [
        base,
        Color(hue: (h + 0.25).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.75).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .monochromatic:
      return [
        Color(hue: h, saturation: s, brightness: b * 0.3),
        Color(hue: h, saturation: s, brightness: b * 0.5),
        base,
        Color(hue: h, saturation: s * 0.7, brightness: b * 1.2),
        Color(hue: h, saturation: s * 0.5, brightness: b * 1.4)
      ]
    case .splitComplementary:
      return [
        base,
        Color(hue: (h + 0.417).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.583).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .doubleComplementary:
      return [
        base,
        Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.583).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .pentadic:
      return [
        base,
        Color(hue: (h + 0.2).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.4).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.6).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b),
        Color(hue: (h + 0.8).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      ]
    case .shades:
      return [
        Color(hue: h, saturation: s, brightness: b),
        Color(hue: h, saturation: s, brightness: b * 0.8),
        Color(hue: h, saturation: s, brightness: b * 0.6),
        Color(hue: h, saturation: s, brightness: b * 0.4),
        Color(hue: h, saturation: s, brightness: b * 0.2)
      ]
    case .tints:
      return [
        Color(hue: h, saturation: s, brightness: b),
        Color(hue: h, saturation: s * 0.8, brightness: b + (1-b) * 0.2),
        Color(hue: h, saturation: s * 0.6, brightness: b + (1-b) * 0.4),
        Color(hue: h, saturation: s * 0.4, brightness: b + (1-b) * 0.6),
        Color(hue: h, saturation: s * 0.2, brightness: b + (1-b) * 0.8)
      ]
    case .tones:
      return [
        Color(hue: h, saturation: s, brightness: b),
        Color(hue: h, saturation: s * 0.8, brightness: b * 0.9),
        Color(hue: h, saturation: s * 0.6, brightness: b * 0.8),
        Color(hue: h, saturation: s * 0.4, brightness: b * 0.7),
        Color(hue: h, saturation: s * 0.3, brightness: b * 0.6)
      ]
    case .warmCool:
      let warm1 = Color(hue: 0.083, saturation: s, brightness: b) // Orange
      let warm2 = Color(hue: 0.167, saturation: s, brightness: b) // Yellow
      let cool1 = Color(hue: 0.5, saturation: s, brightness: b) // Cyan
      let cool2 = Color(hue: 0.667, saturation: s, brightness: b) // Blue
      return [warm1, warm2, base, cool1, cool2]
    }
  }
  
  func generatePalette(from base: Color) -> (dark: ANSIColorPalette, light: ANSIColorPalette) {
    let uiBase = UIColor(base)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    uiBase.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    
    var darkPalette = ANSIColorPalette()
    var lightPalette = ANSIColorPalette()
    
    switch self {
    case .complementary:
      let complement = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      // Dark palette
      darkPalette.background = Color(hue: h, saturation: s, brightness: 0.1)
      darkPalette.foreground = Color(hue: h, saturation: 0.1, brightness: 0.9)
      darkPalette.black = Color(hue: h, saturation: s, brightness: 0.05)
      darkPalette.white = Color(hue: h, saturation: 0.05, brightness: 0.95)
      darkPalette.red = Color(hue: 0, saturation: s, brightness: b)
      darkPalette.green = Color(hue: 0.333, saturation: s, brightness: b)
      darkPalette.blue = base
      darkPalette.yellow = Color(hue: 0.167, saturation: s, brightness: b)
      darkPalette.magenta = complement
      darkPalette.cyan = Color(hue: 0.5, saturation: s, brightness: b)
      
    case .analogous:
      let analog1 = Color(hue: (h - 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let analog2 = Color(hue: (h + 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      darkPalette.background = Color(hue: h, saturation: s * 0.8, brightness: 0.1)
      darkPalette.foreground = Color(hue: h, saturation: 0.1, brightness: 0.9)
      darkPalette.blue = base
      darkPalette.green = analog1
      darkPalette.cyan = analog2
      darkPalette.red = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.yellow = Color(hue: (h + 0.167).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.magenta = Color(hue: (h - 0.167).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
    case .triadic:
      let triad1 = Color(hue: (h + 0.333).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let triad2 = Color(hue: (h + 0.667).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      darkPalette.background = Color.black
      darkPalette.foreground = Color.white
      darkPalette.blue = base
      darkPalette.red = triad1
      darkPalette.green = triad2
      darkPalette.yellow = Color(hue: (h + 0.167).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.magenta = Color(hue: (h + 0.833).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.cyan = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
    case .tetradic:
      let tetrad1 = Color(hue: (h + 0.25).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let tetrad2 = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let tetrad3 = Color(hue: (h + 0.75).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      darkPalette.blue = base
      darkPalette.green = tetrad1
      darkPalette.red = tetrad2
      darkPalette.yellow = tetrad3
      darkPalette.cyan = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s * 0.7, brightness: b)
      darkPalette.magenta = Color(hue: (h + 0.833).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
    case .monochromatic:
      darkPalette.background = Color(hue: h, saturation: s, brightness: 0.05)
      darkPalette.foreground = Color(hue: h, saturation: s * 0.1, brightness: 0.95)
      darkPalette.black = Color(hue: h, saturation: s, brightness: 0.0)
      darkPalette.white = Color(hue: h, saturation: s * 0.05, brightness: 1.0)
      darkPalette.red = Color(hue: h, saturation: s * 0.9, brightness: b * 0.8)
      darkPalette.green = Color(hue: h, saturation: s * 0.7, brightness: b * 0.9)
      darkPalette.blue = base
      darkPalette.yellow = Color(hue: h, saturation: s * 0.6, brightness: b * 1.1)
      darkPalette.magenta = Color(hue: h, saturation: s * 1.0, brightness: b * 0.7)
      darkPalette.cyan = Color(hue: h, saturation: s * 0.8, brightness: b * 1.0)
      
    case .splitComplementary:
      let split1 = Color(hue: (h + 0.417).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let split2 = Color(hue: (h + 0.583).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      darkPalette.blue = base
      darkPalette.red = split1
      darkPalette.green = split2
      darkPalette.yellow = Color(hue: (h + 0.167).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.magenta = Color(hue: (h + 0.75).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.cyan = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s * 0.8, brightness: b)
      
    case .doubleComplementary:
      let comp1 = Color(hue: (h + 0.5).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let adj1 = Color(hue: (h + 0.083).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      let adj1Comp = Color(hue: (h + 0.583).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
      darkPalette.background = Color.black
      darkPalette.foreground = Color.white
      darkPalette.blue = base
      darkPalette.red = comp1
      darkPalette.green = adj1
      darkPalette.yellow = adj1Comp
      darkPalette.magenta = Color(hue: (h + 0.333).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.cyan = Color(hue: (h + 0.667).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
    case .pentadic:
      darkPalette.background = Color(hue: h, saturation: s * 0.5, brightness: 0.05)
      darkPalette.foreground = Color.white
      darkPalette.blue = base
      darkPalette.red = Color(hue: (h + 0.2).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.green = Color(hue: (h + 0.4).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.yellow = Color(hue: (h + 0.6).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.magenta = Color(hue: (h + 0.8).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      darkPalette.cyan = Color(hue: (h + 0.1).truncatingRemainder(dividingBy: 1.0), saturation: s, brightness: b)
      
    case .shades:
      darkPalette.background = Color(hue: h, saturation: s, brightness: 0.02)
      darkPalette.foreground = Color(hue: h, saturation: s * 0.1, brightness: 0.95)
      darkPalette.black = Color(hue: h, saturation: s, brightness: 0.0)
      darkPalette.white = Color(hue: h, saturation: s * 0.05, brightness: 0.95)
      darkPalette.red = Color(hue: h, saturation: s, brightness: b * 0.9)
      darkPalette.green = Color(hue: h, saturation: s, brightness: b * 0.8)
      darkPalette.blue = base
      darkPalette.yellow = Color(hue: h, saturation: s, brightness: b * 0.7)
      darkPalette.magenta = Color(hue: h, saturation: s, brightness: b * 0.6)
      darkPalette.cyan = Color(hue: h, saturation: s, brightness: b * 0.5)
      
    case .tints:
      darkPalette.background = Color(hue: h, saturation: s * 0.1, brightness: 0.05)
      darkPalette.foreground = Color(hue: h, saturation: s * 0.05, brightness: 0.98)
      darkPalette.black = Color(hue: h, saturation: s * 0.3, brightness: 0.1)
      darkPalette.white = Color(hue: h, saturation: s * 0.02, brightness: 1.0)
      darkPalette.red = base
      darkPalette.green = Color(hue: h, saturation: s * 0.8, brightness: b + (1-b) * 0.2)
      darkPalette.blue = Color(hue: h, saturation: s * 0.6, brightness: b + (1-b) * 0.4)
      darkPalette.yellow = Color(hue: h, saturation: s * 0.4, brightness: b + (1-b) * 0.6)
      darkPalette.magenta = Color(hue: h, saturation: s * 0.7, brightness: b + (1-b) * 0.3)
      darkPalette.cyan = Color(hue: h, saturation: s * 0.5, brightness: b + (1-b) * 0.5)
      
    case .tones:
      darkPalette.background = Color(hue: h, saturation: s * 0.2, brightness: 0.08)
      darkPalette.foreground = Color(hue: h, saturation: s * 0.1, brightness: 0.92)
      darkPalette.black = Color(hue: h, saturation: s * 0.3, brightness: 0.05)
      darkPalette.white = Color(hue: h, saturation: s * 0.05, brightness: 0.95)
      darkPalette.red = base
      darkPalette.green = Color(hue: h, saturation: s * 0.8, brightness: b * 0.9)
      darkPalette.blue = Color(hue: h, saturation: s * 0.6, brightness: b * 0.8)
      darkPalette.yellow = Color(hue: h, saturation: s * 0.4, brightness: b * 0.7)
      darkPalette.magenta = Color(hue: h, saturation: s * 0.7, brightness: b * 0.85)
      darkPalette.cyan = Color(hue: h, saturation: s * 0.5, brightness: b * 0.75)
      
    case .warmCool:
      darkPalette.background = Color(hue: 0.667, saturation: 0.8, brightness: 0.05) // Cool bg
      darkPalette.foreground = Color(hue: 0.083, saturation: 0.1, brightness: 0.95) // Warm fg
      darkPalette.red = Color(hue: 0.0, saturation: s, brightness: b)
      darkPalette.yellow = Color(hue: 0.083, saturation: s, brightness: b)
      darkPalette.green = Color(hue: 0.167, saturation: s, brightness: b)
      darkPalette.cyan = Color(hue: 0.5, saturation: s, brightness: b)
      darkPalette.blue = Color(hue: 0.667, saturation: s, brightness: b)
      darkPalette.magenta = Color(hue: 0.833, saturation: s, brightness: b)
    }
    
    // Set bright colors for all algorithms
    darkPalette.brightBlack = darkPalette.black.brightened(by: 0.3)
    darkPalette.brightWhite = darkPalette.white
    darkPalette.brightRed = darkPalette.red.brightened(by: 0.2)
    darkPalette.brightGreen = darkPalette.green.brightened(by: 0.2)
    darkPalette.brightBlue = darkPalette.blue.brightened(by: 0.2)
    darkPalette.brightYellow = darkPalette.yellow.brightened(by: 0.2)
    darkPalette.brightMagenta = darkPalette.magenta.brightened(by: 0.2)
    darkPalette.brightCyan = darkPalette.cyan.brightened(by: 0.2)
    
    // Generate light palette (inverted with adjustments)
    lightPalette = darkPalette
    lightPalette.background = Color(hue: h, saturation: s * 0.05, brightness: 0.98)
    lightPalette.foreground = Color(hue: h, saturation: s * 0.8, brightness: 0.2)
    lightPalette.black = darkPalette.white.darkened(by: 0.9)
    lightPalette.white = darkPalette.black.brightened(by: 0.9)
    
    // Adjust colors for light mode
    lightPalette.red = darkPalette.red.darkened(by: 0.2)
    lightPalette.green = darkPalette.green.darkened(by: 0.2)
    lightPalette.blue = darkPalette.blue.darkened(by: 0.2)
    lightPalette.yellow = darkPalette.yellow.darkened(by: 0.3)
    lightPalette.magenta = darkPalette.magenta.darkened(by: 0.2)
    lightPalette.cyan = darkPalette.cyan.darkened(by: 0.2)
    
    return (darkPalette, lightPalette)
  }
}

struct ExtractedColors {
  var darkest: Color = .black
  var lightest: Color = .white
  var mediumDark: Color = .gray
  var mediumLight: Color = Color(white: 0.8)
  var red: Color = .red
  var green: Color = .green
  var blue: Color = .blue
  var yellow: Color = .yellow
  var magenta: Color = .purple
  var cyan: Color = .cyan
  var brightRed: Color = Color(red: 1.0, green: 0.4, blue: 0.4)
  var brightGreen: Color = Color(red: 0.4, green: 1.0, blue: 0.4)
  var brightBlue: Color = Color(red: 0.4, green: 0.4, blue: 1.0)
  var brightYellow: Color = Color(red: 1.0, green: 1.0, blue: 0.4)
  var brightMagenta: Color = Color(red: 1.0, green: 0.4, blue: 1.0)
  var brightCyan: Color = Color(red: 0.4, green: 1.0, blue: 1.0)
  
  static let `default` = ExtractedColors()
}

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
  
  init() {
    let defaultScheme = ANSIColorScheme(name: "Default")
    self.schemes = [defaultScheme]
  }
}

// MARK: - Store

final class TerminalColorSchemeStore: GraphObject {
  @GraphStored(backed: .userDefaults(key: "terminalColorSchemeCollection")) 
  var collection: ColorSchemeCollection = ColorSchemeCollection()
  
  func addNewScheme() {
    let newScheme = ANSIColorScheme(name: "New Scheme")
    collection.schemes.append(newScheme)
  }
  
  func duplicateScheme(_ scheme: ANSIColorScheme, withName name: String? = nil) {
    var duplicate = scheme.duplicate()
    if let name = name {
      duplicate.name = name
    }
    collection.schemes.append(duplicate)
  }
  
  func deleteScheme(_ scheme: ANSIColorScheme) {
    collection.schemes.removeAll { $0.id == scheme.id }
  }
  
  func updateScheme(_ scheme: ANSIColorScheme) {
    if let index = collection.schemes.firstIndex(where: { $0.id == scheme.id }) {
      collection.schemes[index] = scheme
    }
  }
  
  func renameScheme(_ scheme: ANSIColorScheme, to newName: String) {
    if let index = collection.schemes.firstIndex(where: { $0.id == scheme.id }) {
      collection.schemes[index].name = newName
    }
  }
}

// MARK: - Extensions

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

extension UTType {
  static let iTermColors = UTType(exportedAs: "com.googlecode.iterm2.itermcolors")
}

extension UIColor {
  var brightness: CGFloat {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return b
  }
  
  var saturation: CGFloat {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return s
  }
  
  var hue: CGFloat {
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    return h
  }
  
  var isRedHue: Bool {
    let h = hue
    return h < 0.08 || h > 0.92
  }
  
  var isGreenHue: Bool {
    let h = hue
    return h > 0.25 && h < 0.42
  }
  
  var isBlueHue: Bool {
    let h = hue
    return h > 0.5 && h < 0.75
  }
  
  var isYellowHue: Bool {
    let h = hue
    return h > 0.08 && h < 0.25
  }
  
  var isMagentaHue: Bool {
    let h = hue
    return h > 0.75 && h < 0.92
  }
  
  var isCyanHue: Bool {
    let h = hue
    return h > 0.42 && h < 0.5
  }
}

extension Color {
  init(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
    self.init(UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1.0))
  }
  
  func brightened(by amount: CGFloat) -> Color {
    let uiColor = UIColor(self)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    
    return Color(UIColor(hue: h, 
                        saturation: max(0, s - amount * 0.3),
                        brightness: min(1, b + amount),
                        alpha: a))
  }
  
  func darkened(by amount: CGFloat) -> Color {
    let uiColor = UIColor(self)
    var h: CGFloat = 0
    var s: CGFloat = 0
    var b: CGFloat = 0
    var a: CGFloat = 0
    uiColor.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    
    return Color(UIColor(hue: h,
                        saturation: min(1, s + amount * 0.3),
                        brightness: max(0, b - amount),
                        alpha: a))
  }
}

// MARK: - Document

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

// MARK: - Export

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

// MARK: - Preview

#Preview("TerminalColorScheme") {
  TerminalColorDesigner()
}