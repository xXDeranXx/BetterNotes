import PencilKit
import Testing
import UIKit
@testable import BetterNotes

struct HexColorTests {
    @Test func normalizesWhatPeopleType() {
        #expect(HexColor.normalized("#1e5bff") == "#1E5BFF")
        #expect(HexColor.normalized("  1E5BFF ") == "#1E5BFF")
        #expect(HexColor.normalized("#f80") == "#FF8800")
        #expect(HexColor.normalized("#12345") == nil)
        #expect(HexColor.normalized("#GGGGGG") == nil)
        #expect(HexColor.normalized("") == nil)
    }

    @Test func roundTripsThroughUIColor() throws {
        for hex in ["#000000", "#FFFFFF", "#1E5BFF", "#E5484D", "#FFD60A"] {
            let color = try #require(HexColor.color(hex))
            #expect(HexColor.hex(of: color) == hex)
        }
        #expect(HexColor.hex(of: .black) == "#000000")
        #expect(HexColor.hex(of: .white) == "#FFFFFF")
    }
}

struct ToolSettingsTests {
    private func roundTrip(_ settings: ToolSettings) throws -> ToolSettings {
        try JSONDecoder().decode(ToolSettings.self, from: try JSONEncoder().encode(settings))
    }

    @Test func everythingSurvivesEncodingAndDecoding() throws {
        var settings = ToolSettings()
        settings.setColor("#336699", for: .fountainPen)
        settings.setWidth(7, for: .fountainPen)
        settings.addFavorite("#123456")
        settings.selected = .pen(.fountainPen)
        settings.addPresetFromCurrentPen()
        settings.eraserMode = .pixel
        settings.setEraserWidth(30)
        settings.toolbarPosition = .leading
        settings.isToolbarCollapsed = true
        settings.allowsFingerDrawing = true
        settings.twoFingerTapUndoes = false
        settings.setPen(.crayon, enabled: true)

        #expect(try roundTrip(settings) == settings)
    }

    @Test func eachPenKeepsItsOwnColorAndWidth() {
        var settings = ToolSettings()
        settings.setColor("#FF0000", for: .pen)
        settings.setWidth(6, for: .pen)
        #expect(settings.setting(for: .pen) == PenSetting(colorHex: "#FF0000", width: 6))
        #expect(settings.setting(for: .marker).colorHex == PenKind.marker.defaultColor)
        #expect(settings.setting(for: .pencil).width == PenKind.pencil.defaultWidth)
    }

    @Test func aBadHexCodeIsIgnored() {
        var settings = ToolSettings()
        settings.setColor("not a color", for: .pen)
        #expect(settings.setting(for: .pen).colorHex == "#000000")
    }

    @Test func widthsAreClampedToWhatPencilKitAllows() {
        var settings = ToolSettings()
        settings.setWidth(100_000, for: .pen)
        #expect(settings.setting(for: .pen).width == PenKind.pen.widthRange.upperBound)
        settings.setWidth(-5, for: .pen)
        #expect(settings.setting(for: .pen).width == PenKind.pen.widthRange.lowerBound)
    }

    @Test func eachToolBuildsTheRightPKTool() throws {
        var settings = ToolSettings()
        settings.setColor("#1E5BFF", for: .fountainPen)
        settings.setWidth(5, for: .fountainPen)
        settings.selected = .pen(.fountainPen)
        let pen = try #require(settings.makeTool() as? PKInkingTool)
        #expect(pen.inkType == .fountainPen)
        #expect(pen.width == 5)
        #expect(HexColor.hex(of: pen.color) == "#1E5BFF")

        settings.selected = .pen(.marker)
        #expect((settings.makeTool() as? PKInkingTool)?.inkType == .marker)

        settings.selected = .eraser
        settings.eraserMode = .stroke
        #expect((settings.makeTool() as? PKEraserTool)?.eraserType == .vector)
        settings.eraserMode = .pixel
        settings.eraserWidth = 30
        let pixel = try #require(settings.makeTool() as? PKEraserTool)
        #expect(pixel.eraserType == .fixedWidthBitmap && pixel.width == 30)  // PencilKit's name for an eraser with a chosen size
        #expect(ToolSettings.eraserWidthRange.contains(30))

        settings.selected = .lasso
        #expect(settings.makeTool() is PKLassoTool)
    }

    @Test func favoritesHaveNoDuplicatesAndAreCapped() {
        var settings = ToolSettings()
        settings.favoriteColors = []
        settings.addFavorite("#abcdef")
        settings.addFavorite("#ABCDEF")
        settings.addFavorite("oops")
        #expect(settings.favoriteColors == ["#ABCDEF"])
        for value in 0..<20 { settings.addFavorite(String(format: "#0000%02X", value)) }
        #expect(settings.favoriteColors.count == ToolSettings.maxFavorites)
        settings.removeFavorite("#000013")
        #expect(!settings.favoriteColors.contains("#000013"))
    }

    @Test func aPresetSwitchesToThatExactPen() {
        var settings = ToolSettings()
        settings.setColor("#336699", for: .fountainPen)
        settings.setWidth(7, for: .fountainPen)
        settings.selected = .pen(.fountainPen)
        settings.addPresetFromCurrentPen()
        let preset = settings.presets[0]

        settings.setColor("#000000", for: .fountainPen)
        settings.selected = .eraser
        settings.apply(preset)

        #expect(settings.selected == .pen(.fountainPen))
        #expect(settings.setting(for: .fountainPen) == PenSetting(colorHex: "#336699", width: 7))
    }

    @Test func presetsAreCapped() {
        var settings = ToolSettings()
        for _ in 0..<ToolSettings.maxPresets {
            let added = settings.addPresetFromCurrentPen()
            #expect(added)
        }
        let overflow = settings.addPresetFromCurrentPen()
        #expect(!overflow)
    }

    @Test func theToolbarNeverEndsUpEmpty() {
        var settings = ToolSettings()
        for kind in settings.enabledPens { settings.setPen(kind, enabled: false) }
        #expect(settings.enabledPens.count == 1)
        settings.selected = .pen(settings.enabledPens[0])
        settings.setPen(.crayon, enabled: true)
        settings.selected = .pen(.crayon)
        settings.setPen(.crayon, enabled: false)
        #expect(settings.selected == .pen(settings.enabledPens[0]))
    }

    @Test func damagedOrOldDataStillLoads() throws {
        let json = #"""
        {"version": 0, "eraserWidth": 9999, "toolbarPosition": "bottom",
         "pens": {"pen": {"colorHex": "nonsense", "width": 3}, "laserBeam": {"colorHex": "#000000", "width": 1}},
         "favoriteColors": ["#ff0000", "oops"], "enabledPens": ["pen", "teleporter"]}
        """#
        let settings = try JSONDecoder().decode(ToolSettings.self, from: Data(json.utf8))

        #expect(settings.eraserWidth == ToolSettings.eraserWidthRange.upperBound)
        #expect(settings.toolbarPosition == .top)  // unknown value -> default
        #expect(settings.setting(for: .pen).colorHex == "#000000")  // bad color repaired
        #expect(settings.pens.count == 1)  // unknown pen dropped
        #expect(settings.favoriteColors == ["#FF0000"])
        #expect(settings.enabledPens == [.pen])
    }

    @Test func savedSettingsSurviveARestart() throws {
        let suite = "ToolSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var store = ToolSettingsStore()
        store.defaults = defaults

        #expect(store.load() == ToolSettings())  // nothing saved yet
        var settings = ToolSettings()
        settings.addFavorite("#123456")
        settings.setColor("#AA00AA", for: .pen)
        store.save(settings)

        var secondRun = ToolSettingsStore()
        secondRun.defaults = defaults
        #expect(secondRun.load() == settings)
    }
}

struct LineDasherTests {
    private func length(_ piece: [CGPoint]) -> CGFloat {
        zip(piece, piece.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    @Test func aSolidLineIsOnePiece() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        #expect(LineDasher.pieces(of: line, style: .solid, width: 4) == [line])
    }

    @Test func dashesHaveTheRightLengthAndGap() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]
        let pieces = LineDasher.pieces(of: line, style: .dashed, width: 4)  // dash 16, gap 12

        #expect(pieces.count == 8)  // 0-16, 28-44, ..., 196-200 is the 8th and shorter
        #expect(abs(length(pieces[0]) - 16) < 0.001)
        #expect(abs(pieces[1][0].x - 28) < 0.001)
        #expect(abs(length(pieces[1]) - 16) < 0.001)
        #expect(pieces.allSatisfy { $0.count >= 2 })
        #expect(pieces.last!.last!.x <= 200.001)
    }

    @Test func dotsAreTinyPiecesWithGapsBetween() {
        let line = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
        let pieces = LineDasher.pieces(of: line, style: .dotted, width: 4)  // gap 10

        #expect(pieces.count >= 9)
        #expect(pieces.allSatisfy { length($0) <= 0.51 })
        #expect(abs(pieces[1][0].x - pieces[0][0].x - 10.5) < 0.001)
    }

    @Test func dashesContinueAroundACorner() {
        let corner = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 40)]
        let pieces = LineDasher.pieces(of: corner, style: .dashed, width: 4)

        let first = pieces[0]  // the first dash (16 long) turns the corner at 10
        #expect(first.count == 3)
        #expect(abs(length(first) - 16) < 0.001)
        #expect(abs(first[2].x - 10) < 0.001 && abs(first[2].y - 6) < 0.001)
    }

    @Test func strokesKeepTheInkColorAndWidth() throws {
        let ink = PKInk(.pen, color: UIColor(red: 0, green: 0, blue: 1, alpha: 1))
        let strokes = LineDasher.strokes(
            through: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)], style: .dashed, ink: ink, width: 4)

        #expect(strokes.count > 3)
        for stroke in strokes {
            #expect(stroke.ink.inkType == .pen)
            #expect(stroke.ink.color == ink.color)
            #expect(stroke.path.first?.size == CGSize(width: 4, height: 4))
        }
        let drawing = PKDrawing(strokes: strokes)
        #expect(drawing.strokes.count == strokes.count)
        #expect(drawing.bounds.width > 90)
    }

    @Test func aSinglePointStillMakesADot() {
        let stroke = LineDasher.stroke(through: [CGPoint(x: 5, y: 5)], ink: PKInk(.pen, color: .black), width: 4)
        #expect(stroke.path.count >= 2)
    }
}
