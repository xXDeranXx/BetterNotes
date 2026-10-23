import PencilKit
import SwiftUI
import UIKit

/// The pens on the toolbar. Each one is a `PKInkingTool` type with its own color and width.
nonisolated enum PenKind: String, Codable, CaseIterable, Sendable {
    case pen, monoline, fountainPen, watercolor, crayon, pencil, marker

    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: .pen
        case .monoline: .monoline
        case .fountainPen: .fountainPen
        case .watercolor: .watercolor
        case .crayon: .crayon
        case .pencil: .pencil
        case .marker: .marker
        }
    }

    var displayName: String {
        switch self {
        case .pen: "Pen"
        case .monoline: "Ballpoint"
        case .fountainPen: "Fountain Pen"
        case .watercolor: "Brush"
        case .crayon: "Crayon"
        case .pencil: "Pencil"
        case .marker: "Highlighter"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .monoline: "pencil.line"
        case .fountainPen: "pencil.and.scribble"
        case .watercolor: "paintbrush.pointed"
        case .crayon: "paintbrush"
        case .pencil: "pencil"
        case .marker: "highlighter"
        }
    }

    var defaultColor: String { self == .marker ? "#FFD60A" : "#000000" }

    var defaultWidth: Double {
        switch self {
        case .pen, .monoline, .pencil: 3
        case .fountainPen: 4
        case .watercolor, .crayon: 10
        case .marker: 18
        }
    }

    /// The widths PencilKit allows for this pen. A width outside them is clamped.
    var widthRange: ClosedRange<Double> {
        let range = inkType.validWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }
}

nonisolated enum EraserMode: String, Codable, Sendable {
    case stroke, pixel
}

/// What is selected on the toolbar.
nonisolated enum ToolChoice: Codable, Equatable, Sendable {
    case pen(PenKind)
    case eraser
    case lasso
    case shape
}

nonisolated enum ToolbarPosition: String, Codable, CaseIterable, Sendable {
    case top, leading, trailing
}

/// A pen's own color and width.
nonisolated struct PenSetting: Codable, Equatable, Sendable {
    var colorHex: String
    var width: Double
}

/// The shape tool's own choices: which shape, solid or dashed or dotted, filled or not, and
/// its own color and width (independent of the pens, like in Goodnotes).
nonisolated struct ShapeSetting: Codable, Equatable, Sendable {
    var kind: ShapeKind = .rectangle
    var lineStyle: LineStyle = .solid
    var isFilled = false
    var colorHex = "#000000"
    var width = 3.0

    /// Shapes are drawn with the pen ink (see `ShapeGeometry.strokes`).
    static let widthRange: ClosedRange<Double> = PenKind.pen.widthRange

    init() {}

    private enum CodingKeys: String, CodingKey { case kind, lineStyle, isFilled, colorHex, width }

    /// Every field is optional, like in `ToolSettings`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(ShapeKind.self, forKey: .kind)) ?? kind
        lineStyle = (try? c.decodeIfPresent(LineStyle.self, forKey: .lineStyle)) ?? lineStyle
        isFilled = (try? c.decodeIfPresent(Bool.self, forKey: .isFilled)) ?? isFilled
        colorHex = (try? c.decodeIfPresent(String.self, forKey: .colorHex)).flatMap(HexColor.normalized) ?? colorHex
        width = min(max((try? c.decodeIfPresent(Double.self, forKey: .width)) ?? width, Self.widthRange.lowerBound),
                    Self.widthRange.upperBound)
    }
}

/// A saved pen: type + color + width. One tap switches to exactly that pen.
nonisolated struct PenPreset: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind: PenKind
    var colorHex: String
    var width: Double
}

/// Everything about the toolbar that belongs to the device, not to a notebook (SPEC, M7a).
/// Saved in `UserDefaults`. Every field is optional on disk, so a file from an older or newer
/// version (or a damaged value) never costs the user their other choices.
nonisolated struct ToolSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maxFavorites = 12
    static let maxPresets = 12
    /// What PencilKit accepts for an eraser with a chosen size (`.fixedWidthBitmap`).
    static let eraserWidthRange: ClosedRange<Double> = {
        let range = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        return Double(range.lowerBound)...Double(range.upperBound)
    }()
    static let defaultFavorites = ["#000000", "#1E5BFF", "#E5484D", "#30A46C", "#F5A524", "#8E4EC6", "#FFFFFF"]

    var version = Self.currentVersion
    var selected: ToolChoice = .pen(.pen)
    var pens: [PenKind: PenSetting] = [:]
    var enabledPens: [PenKind] = [.pen, .fountainPen, .monoline, .pencil, .marker]
    var favoriteColors: [String] = Self.defaultFavorites
    var presets: [PenPreset] = []
    var eraserMode: EraserMode = .stroke
    var eraserWidth = 24.0
    var shape = ShapeSetting()
    var toolbarPosition: ToolbarPosition = .top
    var isToolbarCollapsed = false
    /// Off by default: the Pencil writes, fingers scroll (SPEC).
    var allowsFingerDrawing = false
    /// The palette opens to the right of the Pencil for left-handed writers, to the left otherwise.
    var isLeftHanded = true
    var twoFingerTapUndoes = true
    var threeFingerTapRedoes = true
    /// Keep the system tool picker instead of the own toolbar, until the toolbar is trusted.
    var usesSystemToolPicker = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, selected, pens, enabledPens, favoriteColors, presets, eraserMode, eraserWidth, shape
        case toolbarPosition, isToolbarCollapsed, allowsFingerDrawing, isLeftHanded, twoFingerTapUndoes
        case threeFingerTapRedoes, usesSystemToolPicker
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { try? c.decodeIfPresent(T.self, forKey: key) }
        selected = value(.selected) ?? selected
        // A dictionary keyed by an enum is stored as text keys; read it that way, and drop
        // unknown pens (a newer version may know more) instead of failing.
        let storedPens: [String: PenSetting] = value(.pens) ?? [:]
        for (name, setting) in storedPens {
            if let kind = PenKind(rawValue: name) { pens[kind] = setting }
        }
        let storedEnabled: [String] = value(.enabledPens) ?? []
        if !storedEnabled.isEmpty { enabledPens = storedEnabled.compactMap(PenKind.init(rawValue:)) }
        favoriteColors = (value(.favoriteColors) as [String]?)?.compactMap(HexColor.normalized) ?? favoriteColors
        presets = value(.presets) ?? []
        eraserMode = value(.eraserMode) ?? eraserMode
        eraserWidth = value(.eraserWidth) ?? eraserWidth
        shape = value(.shape) ?? shape
        toolbarPosition = value(.toolbarPosition) ?? toolbarPosition
        isToolbarCollapsed = value(.isToolbarCollapsed) ?? isToolbarCollapsed
        allowsFingerDrawing = value(.allowsFingerDrawing) ?? allowsFingerDrawing
        isLeftHanded = value(.isLeftHanded) ?? isLeftHanded
        twoFingerTapUndoes = value(.twoFingerTapUndoes) ?? twoFingerTapUndoes
        threeFingerTapRedoes = value(.threeFingerTapRedoes) ?? threeFingerTapRedoes
        usesSystemToolPicker = value(.usesSystemToolPicker) ?? usesSystemToolPicker
        sanitize()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.currentVersion, forKey: .version)
        try c.encode(selected, forKey: .selected)
        try c.encode(Dictionary(uniqueKeysWithValues: pens.map { ($0.key.rawValue, $0.value) }), forKey: .pens)
        try c.encode(enabledPens, forKey: .enabledPens)
        try c.encode(favoriteColors, forKey: .favoriteColors)
        try c.encode(presets, forKey: .presets)
        try c.encode(eraserMode, forKey: .eraserMode)
        try c.encode(eraserWidth, forKey: .eraserWidth)
        try c.encode(shape, forKey: .shape)
        try c.encode(toolbarPosition, forKey: .toolbarPosition)
        try c.encode(isToolbarCollapsed, forKey: .isToolbarCollapsed)
        try c.encode(allowsFingerDrawing, forKey: .allowsFingerDrawing)
        try c.encode(isLeftHanded, forKey: .isLeftHanded)
        try c.encode(twoFingerTapUndoes, forKey: .twoFingerTapUndoes)
        try c.encode(threeFingerTapRedoes, forKey: .threeFingerTapRedoes)
        try c.encode(usesSystemToolPicker, forKey: .usesSystemToolPicker)
    }

    /// Repairs values that make no sense (a bad color, a width out of range, an empty toolbar).
    private mutating func sanitize() {
        eraserWidth = min(max(eraserWidth, Self.eraserWidthRange.lowerBound), Self.eraserWidthRange.upperBound)
        for (kind, setting) in pens {
            pens[kind] = PenSetting(
                colorHex: HexColor.normalized(setting.colorHex) ?? kind.defaultColor,
                width: min(max(setting.width, kind.widthRange.lowerBound), kind.widthRange.upperBound))
        }
        presets = presets.compactMap { preset in
            guard let hex = HexColor.normalized(preset.colorHex) else { return nil }
            var fixed = preset
            fixed.colorHex = hex
            fixed.width = min(max(preset.width, preset.kind.widthRange.lowerBound), preset.kind.widthRange.upperBound)
            return fixed
        }
        var seen = Set<PenKind>()
        enabledPens = enabledPens.filter { seen.insert($0).inserted }
        if enabledPens.isEmpty { enabledPens = [.pen] }
        favoriteColors = Array(favoriteColors.prefix(Self.maxFavorites))
        presets = Array(presets.prefix(Self.maxPresets))
        if case .pen(let kind) = selected, !enabledPens.contains(kind) { selected = .pen(enabledPens[0]) }
    }

    // MARK: Pens

    func setting(for kind: PenKind) -> PenSetting {
        pens[kind] ?? PenSetting(colorHex: kind.defaultColor, width: kind.defaultWidth)
    }

    /// The pen that is selected, or the first pen on the toolbar when another tool is selected.
    var currentPen: PenKind {
        if case .pen(let kind) = selected { return kind }
        return enabledPens[0]
    }

    mutating func setColor(_ hex: String, for kind: PenKind) {
        guard let hex = HexColor.normalized(hex) else { return }
        var setting = self.setting(for: kind)
        setting.colorHex = hex
        pens[kind] = setting
    }

    mutating func setWidth(_ width: Double, for kind: PenKind) {
        var setting = self.setting(for: kind)
        setting.width = min(max(width, kind.widthRange.lowerBound), kind.widthRange.upperBound)
        pens[kind] = setting
    }

    mutating func setShapeColor(_ hex: String) {
        if let hex = HexColor.normalized(hex) { shape.colorHex = hex }
    }

    mutating func setShapeWidth(_ width: Double) {
        shape.width = min(max(width, ShapeSetting.widthRange.lowerBound), ShapeSetting.widthRange.upperBound)
    }

    mutating func setEraserWidth(_ width: Double) {
        eraserWidth = min(max(width, Self.eraserWidthRange.lowerBound), Self.eraserWidthRange.upperBound)
    }

    // MARK: Favorites and presets

    mutating func addFavorite(_ hex: String) {
        guard let hex = HexColor.normalized(hex), !favoriteColors.contains(hex) else { return }
        favoriteColors.append(hex)
        if favoriteColors.count > Self.maxFavorites { favoriteColors.removeFirst() }
    }

    mutating func removeFavorite(_ hex: String) {
        favoriteColors.removeAll { $0 == hex }
    }

    /// Saves the current pen as a preset; `false` if the list is full.
    @discardableResult
    mutating func addPresetFromCurrentPen() -> Bool {
        guard presets.count < Self.maxPresets else { return false }
        let kind = currentPen, setting = self.setting(for: kind)
        presets.append(PenPreset(kind: kind, colorHex: setting.colorHex, width: setting.width))
        return true
    }

    mutating func removePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
    }

    /// Switches to the preset's pen with its color and width.
    mutating func apply(_ preset: PenPreset) {
        if !enabledPens.contains(preset.kind) { enabledPens.append(preset.kind) }
        setColor(preset.colorHex, for: preset.kind)
        setWidth(preset.width, for: preset.kind)
        selected = .pen(preset.kind)
    }

    mutating func movePen(from source: IndexSet, to destination: Int) {
        enabledPens.move(fromOffsets: source, toOffset: destination)
    }

    mutating func setPen(_ kind: PenKind, enabled: Bool) {
        if enabled, !enabledPens.contains(kind) {
            enabledPens.append(kind)
        } else if !enabled, enabledPens.count > 1 {
            enabledPens.removeAll { $0 == kind }
            if case .pen(kind) = selected { selected = .pen(enabledPens[0]) }
        }
    }

    // MARK: PencilKit

    /// The tool a canvas should use for the current choice.
    func makeTool() -> PKTool {
        switch selected {
        case .pen(let kind):
            let setting = self.setting(for: kind)
            return PKInkingTool(
                kind.inkType, color: HexColor.color(setting.colorHex) ?? .black, width: CGFloat(setting.width))
        case .eraser:
            return eraserMode == .stroke ? PKEraserTool(.vector) : PKEraserTool(.fixedWidthBitmap, width: CGFloat(eraserWidth))
        case .lasso:
            return PKLassoTool()
        case .shape:
            // The canvas does not draw while the shape tool is on (the shape gesture does), but
            // it still needs a tool; this one matches the shape if PencilKit ever shows it.
            return PKInkingTool(.pen, color: HexColor.color(shape.colorHex) ?? .black, width: CGFloat(shape.width))
        }
    }
}

/// Reads and writes `ToolSettings` in `UserDefaults`.
nonisolated struct ToolSettingsStore {
    var defaults: UserDefaults = .standard
    static let key = "toolSettings"

    func load() -> ToolSettings {
        guard let data = defaults.data(forKey: Self.key),
            let settings = try? JSONDecoder().decode(ToolSettings.self, from: data)
        else { return ToolSettings() }
        return settings
    }

    func save(_ settings: ToolSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.key) }
    }
}
