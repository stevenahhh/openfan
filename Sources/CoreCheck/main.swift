import CryptoKit
import Foundation
import CheckKit
import OpenFanCore
import OpenFanSMC

// Executable check for OpenFanCore: fan curve model, preset store and helper wire protocol.
// XCTest / Swift Testing are unavailable on a Command Line Tools only install, so this binary
// exits non-zero on any failed assertion.

let check = Checker("CoreCheck")

// MARK: - Helpers

func silentCurve() -> FanCurve {
    FanCurve(points: [
        CurvePoint(t: 50, p: 0),
        CurvePoint(t: 70, p: 15),
        CurvePoint(t: 85, p: 45),
        CurvePoint(t: 95, p: 100),
    ])
}

func fallbackLibrary() -> PresetLibrary {
    PresetLibrary(version: 0, active: "unset", presets: [])
}

func expectCurveError(_ label: String, _ expected: CurveError, _ points: [CurvePoint], line: UInt = #line) {
    do {
        try FanCurve(points: points).validate()
        check.expect(false, "\(label): expected \(expected), got no error", line: line)
    } catch let error as CurveError {
        check.expectEqual(error, expected, label, line: line)
    } catch {
        check.expect(false, "\(label): expected \(expected), got \(error)", line: line)
    }
}

func expectProtoError(_ label: String, _ expected: ProtocolError, _ text: String, line: UInt = #line) {
    do {
        _ = try HelperCommand.parse(text)
        check.expect(false, "\(label): expected \(expected), got no error", line: line)
    } catch let error as ProtocolError {
        check.expectEqual(error, expected, label, line: line)
    } catch {
        check.expect(false, "\(label): expected \(expected), got \(error)", line: line)
    }
}

func expectRoundTrip(_ label: String, _ text: String, serializedAs expected: String? = nil) {
    let parsed = check.expectNoThrow("\(label): parse") { try HelperCommand.parse(text) }
    guard let command = parsed else { return }
    let serialized = command.serialized
    if let expected {
        check.expectEqual(serialized, expected, "\(label): serialized form")
    }
    let reparsed = check.expectNoThrow("\(label): re-parse") { try HelperCommand.parse(serialized) }
    guard let again = reparsed else { return }
    check.expectEqual(again, command, "\(label): round trip")
}

// MARK: - FanCurve.validate

check.expectNoThrow("silent curve validates") { try silentCurve().validate() }

expectCurveError("validate rejects 0 points", .tooFewPoints(0), [])
expectCurveError("validate rejects 1 point", .tooFewPoints(1), [CurvePoint(t: 50, p: 20)])
var thirteenPoints: [CurvePoint] = []
for index in 0..<13 { thirteenPoints.append(CurvePoint(t: Double(index) * 5, p: Double(index) * 5)) }
expectCurveError("validate rejects 13 points", .tooManyPoints(13), thirteenPoints)
expectCurveError("validate rejects non-increasing t", .notStrictlyIncreasing(index: 1),
                 [CurvePoint(t: 60, p: 10), CurvePoint(t: 50, p: 20)])
expectCurveError("validate rejects equal t", .notStrictlyIncreasing(index: 1),
                 [CurvePoint(t: 60, p: 10), CurvePoint(t: 60, p: 20)])
expectCurveError("validate rejects t below range", .temperatureOutOfRange(index: 0),
                 [CurvePoint(t: -1, p: 0), CurvePoint(t: 10, p: 10)])
expectCurveError("validate rejects t above range", .temperatureOutOfRange(index: 1),
                 [CurvePoint(t: 120, p: 0), CurvePoint(t: 131, p: 10)])
expectCurveError("validate rejects NaN t", .temperatureOutOfRange(index: 0),
                 [CurvePoint(t: .nan, p: 0), CurvePoint(t: 10, p: 10)])
expectCurveError("validate rejects p over 100", .percentOutOfRange(index: 1),
                 [CurvePoint(t: 50, p: 0), CurvePoint(t: 60, p: 101)])
expectCurveError("validate rejects p below 0", .percentOutOfRange(index: 0),
                 [CurvePoint(t: 50, p: -1), CurvePoint(t: 60, p: 10)])
expectCurveError("validate rejects decreasing p", .decreasingPercent(index: 1),
                 [CurvePoint(t: 50, p: 50), CurvePoint(t: 60, p: 10)])
var twelvePoints: [CurvePoint] = []
for index in 0..<12 { twelvePoints.append(CurvePoint(t: Double(index) * 5, p: Double(index) * 5)) }
check.expectNoThrow("validate accepts 12 points") { try FanCurve(points: twelvePoints).validate() }

// MARK: - FanCurve.percent(at:)

let silent = silentCurve()
check.expectClose(silent.percent(at: 40), 0, tolerance: 0.0001, "clamp below first point")
check.expectClose(silent.percent(at: 50), 0, tolerance: 0.0001, "first point exact")
check.expectClose(silent.percent(at: 60), 7.5, tolerance: 0.0001, "interpolate midpoint")
check.expectClose(silent.percent(at: 70), 15, tolerance: 0.0001, "interior vertex exact")
check.expectClose(silent.percent(at: 80), 35, tolerance: 0.0001, "interpolate second segment")
check.expectClose(silent.percent(at: 95), 100, tolerance: 0.0001, "last point exact")
check.expectClose(silent.percent(at: 120), 100, tolerance: 0.0001, "clamp above last point")

// MARK: - PresetLibrary.defaults

let defaults = PresetLibrary.defaults()
check.expectEqual(defaults.version, 3, "defaults version")
check.expectEqual(defaults.active, PresetLibrary.autoID, "defaults active is auto")
check.expectEqual(defaults.presets.count, 5, "defaults has 5 presets")
check.expectEqual(defaults.presets.map { $0.id }, ["silent", "quiet45", "balanced", "performance", "full"], "defaults ids")
check.expectEqual(defaults.presets.map { $0.name }, ["Silent", "Quiet 45 °C", "Balanced", "Performance", "Full"], "defaults names")
let silentPreset = defaults.preset(id: "silent")
check.expect(silentPreset != nil, "silent preset exists")
check.expectEqual(silentPreset?.points ?? [], [
    CurvePoint(t: 30, p: 0),
    CurvePoint(t: 50, p: 5),
    CurvePoint(t: 70, p: 15),
    CurvePoint(t: 85, p: 45),
    CurvePoint(t: 95, p: 100),
], "Silent points exactly as listed")
check.expectEqual(silentPreset.map { HelperCommand.curve(input: $0.input, points: $0.points).serialized } ?? "",
                  "CURVE max 30:0,50:5,70:15,85:45,95:100", "Silent input is max")
check.expectEqual(defaults.preset(id: "full")?.points ?? [], [
    CurvePoint(t: 0, p: 100), CurvePoint(t: 130, p: 100),
], "Full points exactly as listed")
check.expect(defaults.presets.allSatisfy(\.isBuiltIn), "the defaults are all built-ins")
for preset in defaults.presets where !preset.isHold && preset.id != PresetLibrary.fullID {
    check.expectClose(preset.curve.percent(at: 30), 0, tolerance: 0.0001, "\(preset.id) stops the fans at 30 C")
}
check.expectClose(defaults.preset(id: PresetLibrary.fullID)!.curve.percent(at: 20), 100, tolerance: 0.0001,
                  "Full holds full speed at any temperature")
for preset in defaults.presets {
    if preset.isHold {
        check.expect(preset.isValid, "default hold \(preset.id) validates")
    } else {
        check.expectNoThrow("default preset \(preset.id) validates") { try preset.curve.validate() }
    }
}
let maxInput = silentPreset!.input

// Hold presets keep a target instead of a curve.
let quiet = defaults.preset(id: PresetLibrary.quietHoldID)
check.expect(quiet != nil, "the Quiet 45 °C preset exists")
check.expectEqual(quiet?.name ?? "", "Quiet 45 °C", "quiet preset name")
check.expectEqual(quiet?.isBuiltIn ?? false, true, "quiet preset is built in")
check.expectEqual(quiet?.isHold ?? false, true, "quiet preset is a hold")
check.expect(quiet?.input == .system, "quiet preset holds the system temperature")
check.expectEqual(quiet?.target ?? 0, 45, "quiet preset target is 45 C")
check.expectEqual(quiet?.points ?? [], [], "quiet preset has no curve points")
check.expectEqual(quiet?.isValid ?? false, true, "quiet preset is valid")
check.expectEqual(quiet?.editorNote.isEmpty ?? true, false, "a built-in hold has an editor note")
if let quiet, let silentPreset {
    let curveJSON = (try? JSONEncoder().encode(silentPreset)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    let holdJSON = (try? JSONEncoder().encode(quiet)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    check.expect(!curveJSON.contains("\"target\""), "a curve preset encodes without a target key")
    check.expect(holdJSON.contains("\"target\":45"), "a hold preset encodes its target")
}
check.expectEqual(Preset.holdRange(for: .system), 40...50, "system hold range")
check.expectEqual(Preset.holdRange(for: .max), 70...100, "max hold range")
check.expectEqual(Preset.holdRange(for: .cpu), 70...100, "cpu hold range")
check.expectEqual(Preset.holdRange(for: .gpu), 70...100, "gpu hold range")
check.expectEqual(Preset.holdRange(for: .battery), 30...40, "battery hold range")
check.expect(Preset(id: "h", name: "H", input: .system, points: [], target: 45).isValid,
             "a system hold inside the helper range is valid")
check.expect(!Preset(id: "h", name: "H", input: .system, points: [], target: 200).isValid,
             "a hold above the helper range is invalid")
check.expect(!Preset(id: "h", name: "H", input: .system, points: [], target: .nan).isValid,
             "a non-finite hold is invalid")
check.expect(!Preset(id: "h", name: "H", input: .battery, points: [], target: 35).isValid,
             "a battery hold is invalid")
check.expect(!Preset(id: "c", name: "C", input: .max, points: [CurvePoint(t: 50, p: 0)]).isValid,
             "an invalid curve is invalid")
let quietCopy = defaults.newCustomPreset(copying: quiet)
check.expectEqual(quietCopy.target ?? 0, 45, "a copy of a hold keeps its target")
check.expect(quietCopy.input == .system, "a copy of a hold keeps its input")
check.expectEqual(quietCopy.id, "custom-1", "a copy of a hold gets a fresh id")
check.expect(!quietCopy.isBuiltIn, "a copy of a hold is a user preset")

// The editor's copy/new rules and the notes it shows for presets it cannot edit.
let copyOfBuiltIn = defaults.newCustomPreset(copying: defaults.preset(id: "balanced"))
check.expectEqual(copyOfBuiltIn.name, "Balanced Copy", "a copy is named after its source")
check.expectEqual(copyOfBuiltIn.points, defaults.preset(id: "balanced")?.points ?? [], "a copy keeps the source curve")
check.expectEqual(copyOfBuiltIn.input, defaults.preset(id: "balanced")?.input ?? .cpu, "a copy keeps the source input")
check.expect(!copyOfBuiltIn.isBuiltIn, "a copy is a user preset")
check.expect(!PresetLibrary.builtIns.contains { $0.id == copyOfBuiltIn.id }, "a copy does not reuse a built-in id")
let starterPreset = defaults.newCustomPreset(copying: nil)
check.expectEqual(starterPreset.points, PresetLibrary.starterPoints, "a new preset starts on the starter curve")
check.expectEqual(starterPreset.name, "New Preset", "a new preset gets a name")
check.expectEqual(defaults.freeName(based: "Balanced"), "Balanced 2", "a name already taken gets a number")
check.expectEqual(defaults.freeName(based: "Mine"), "Mine", "a free name is kept as asked")
check.expectEqual(defaults.preset(id: PresetLibrary.fullID)?.editorNote.contains("maximum speed") ?? false, true,
                  "Full says it runs at maximum speed")
check.expectEqual(defaults.preset(id: "silent")?.editorNote.contains("Built-in preset") ?? false, true,
                  "a built-in is described as read-only")
check.expectEqual(copyOfBuiltIn.editorNote, "", "a user preset has no note")

// MARK: - PresetStore

let tmpRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("OpenFanCoreCheck-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
let storeURL = tmpRoot.appendingPathComponent("nested/presets.json")
let bakURL = URL(fileURLWithPath: storeURL.path + ".bak")

// Missing file -> defaults written.
let store = PresetStore(url: storeURL)
check.expect(!FileManager.default.fileExists(atPath: storeURL.path), "store file starts missing")
let loadedMissing = check.expectNoThrow("load() on missing file") { try store.load() }
check.expectEqual(loadedMissing ?? fallbackLibrary(), defaults, "missing file load returns defaults")
check.expect(FileManager.default.fileExists(atPath: storeURL.path), "missing file load writes defaults to disk")
check.expect(FileManager.default.fileExists(atPath: tmpRoot.appendingPathComponent("nested").path),
             "save creates the parent directory")

// Corrupt file -> moved to .bak, defaults restored.
let corruptText = "{ this is not json"
try? corruptText.data(using: .utf8)!.write(to: storeURL)
let loadedCorrupt = check.expectNoThrow("load() on corrupt file") { try store.load() }
check.expectEqual(loadedCorrupt ?? fallbackLibrary(), defaults, "corrupt file falls back to defaults")
check.expect(FileManager.default.fileExists(atPath: bakURL.path), "corrupt file moved to .bak")
check.expectEqual((try? String(contentsOf: bakURL, encoding: .utf8)) ?? "", corruptText, ".bak holds the corrupt bytes")

// save() then load() is equal, and the file is human readable with sorted keys.
let storeWrite = PresetStore(url: storeURL)
check.expectNoThrow("setActive writes defaults with active performance") { try storeWrite.setActive("performance") }
let reloadedWrite = check.expectNoThrow("reload after setActive") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedWrite, storeWrite.library, "save then load equal")
let savedText = (try? String(contentsOf: storeURL, encoding: .utf8)) ?? ""
check.expect(savedText.contains("\n"), "saved file is pretty printed")
if let activeKey = savedText.range(of: "\"active\""),
   let presetsKey = savedText.range(of: "\"presets\""),
   let versionKey = savedText.range(of: "\"version\"") {
    check.expect(activeKey.lowerBound < presetsKey.lowerBound && presetsKey.lowerBound < versionKey.lowerBound,
                 "top-level keys are sorted")
} else {
    check.expect(false, "saved file contains version/active/presets keys")
}

// setActive persists.
let storeActive = PresetStore(url: storeURL)
check.expectNoThrow("setActive balanced") { try storeActive.setActive("balanced") }
let reloadedActive = check.expectNoThrow("reload after setActive balanced") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedActive?.active ?? "", "balanced", "active persisted")

// upsert appends then replaces, both persisted.
let custom = Preset(id: "custom", name: "Custom", input: maxInput, points: [
    CurvePoint(t: 40, p: 10), CurvePoint(t: 80, p: 90),
])
check.expectNoThrow("upsert appends") { try storeActive.upsert(custom) }
let reloadedUpsert = check.expectNoThrow("reload after upsert") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedUpsert?.preset(id: "custom"), custom, "upsert persisted")
check.expectEqual(reloadedUpsert?.presets.count ?? 0, 6, "upsert kept the defaults")
check.expectNoThrow("upsert replaces") { try storeActive.upsert(Preset(id: "custom", name: "Custom2", input: maxInput, points: [
    CurvePoint(t: 40, p: 10), CurvePoint(t: 80, p: 95),
])) }
let reloadedReplace = check.expectNoThrow("reload after replace") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedReplace?.presets.count ?? 0, 6, "replace did not add a preset")
check.expectEqual(reloadedReplace?.preset(id: "custom")?.name ?? "", "Custom2", "replace updated the name")

check.expectNoThrow("remove custom") { try storeActive.remove(id: "custom") }
let reloadedRemove = check.expectNoThrow("reload after remove") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedRemove?.preset(id: "custom"), nil, "remove persisted")
check.expectEqual(reloadedRemove?.presets.count ?? 0, 5, "remove dropped one preset")

check.expectThrows("a built-in cannot be removed") { try storeActive.remove(id: "balanced") }
check.expectThrows("a built-in cannot be upserted") {
    try storeActive.upsert(Preset(id: "silent", name: "Sneaky", input: maxInput, points: custom.points))
}
let reloadedRefused = check.expectNoThrow("reload after refused writes") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedRefused?.preset(id: "silent")?.name ?? "", "Silent", "the built-in is unchanged")
check.expectEqual(reloadedRefused?.presets.count ?? 0, 5, "a refused write saves nothing")

let activeCustom = Preset(id: "custom-7", name: "Active", input: maxInput, points: [
    CurvePoint(t: 40, p: 10), CurvePoint(t: 80, p: 90),
])
check.expectNoThrow("upsert the active custom") { try storeActive.upsert(activeCustom) }
check.expectNoThrow("activate the custom") { try storeActive.setActive("custom-7") }
check.expectNoThrow("remove the active custom") { try storeActive.remove(id: "custom-7") }
let reloadedRemoveActive = check.expectNoThrow("reload after removing the active preset") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedRemoveActive?.active ?? "", PresetLibrary.autoID, "removing the active preset resets to auto")
check.expectEqual(reloadedRemoveActive?.presets.count ?? 0, 5, "the custom preset is gone")

// load() drops invalid presets and repairs a dangling active id.
let badJSON = """
{"version":1,"active":"broken","presets":[
{"id":"broken","name":"Broken","input":"max","points":[{"t":50,"p":0}]},
{"id":"good","name":"Good","input":"max","points":[{"t":30,"p":10},{"t":80,"p":90}]}
]}
"""
try? badJSON.data(using: .utf8)!.write(to: storeURL)
let repaired = check.expectNoThrow("load drops invalid presets") { try PresetStore(url: storeURL).load() }
check.expectEqual(repaired?.presets.count ?? -1, 6, "invalid preset dropped, built-ins kept")
check.expectEqual(repaired?.preset(id: "broken"), nil, "broken preset removed")
check.expectEqual(repaired?.preset(id: "good")?.name ?? "", "Good", "valid preset kept")
check.expectEqual(repaired?.active ?? "", PresetLibrary.autoID, "dangling active repaired to auto")

// A version 1 file: an untouched built-in copy is dropped, an edited one becomes a user preset the active
// selection follows, and the file is rewritten with only the user's presets.
let legacyJSON = """
{"version":1,"active":"performance","presets":[
{"id":"silent","name":"Silent","input":"max","points":[{"t":50,"p":0},{"t":70,"p":15},{"t":85,"p":45},{"t":95,"p":100}]},
{"id":"performance","name":"Custom","input":"max","points":[{"t":43,"p":0},{"t":55,"p":15},{"t":84,"p":100}]},
{"id":"custom","name":"Mine","input":"max","points":[{"t":30,"p":10},{"t":80,"p":90}]}]}
"""
try? legacyJSON.data(using: .utf8)!.write(to: storeURL)
let migrated = check.expectNoThrow("load migrates a version 1 file") { try PresetStore(url: storeURL).load() }
check.expectEqual(migrated?.presets.count ?? 0, 7, "the built-ins plus both user presets")
check.expectEqual(migrated?.preset(id: "silent")?.points ?? [], defaults.preset(id: "silent")?.points ?? [],
                  "an untouched built-in copy is dropped")
check.expectEqual(migrated?.preset(id: "performance")?.name ?? "", "Performance", "the built-in comes back")
check.expectEqual(migrated?.preset(id: "custom-1")?.points ?? [], [
    CurvePoint(t: 43, p: 0), CurvePoint(t: 55, p: 15), CurvePoint(t: 84, p: 100),
], "the edited copy becomes a user preset")
check.expectEqual(migrated?.preset(id: "custom-1")?.name ?? "", "Custom", "the edited copy keeps its name")
check.expectEqual(migrated?.active ?? "", "custom-1", "the active selection follows the edited copy")
check.expectEqual(migrated?.preset(id: "custom")?.name ?? "", "Mine", "the user preset is kept")
let reloadedMigration = check.expectNoThrow("reload after migration") { try PresetStore(url: storeURL).load() }
check.expectEqual(reloadedMigration, migrated, "migration is idempotent")
check.expectEqual(reloadedMigration?.version ?? 0, 3, "the file is rewritten as version 3")

try? FileManager.default.removeItem(at: tmpRoot)

// MARK: - Hold preset persistence and visibility

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("openfan-hold-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("presets.json")

    // A custom hold keeps its target across save and load.
    let store = PresetStore(url: url)
    _ = check.expectNoThrow("hold store: load defaults") { try store.load() }
    let customHold = Preset(id: "custom-hold", name: "My Hold", input: .cpu, points: [], target: 85)
    check.expectNoThrow("upsert a custom hold") { try store.upsert(customHold) }
    check.expectNoThrow("activate the custom hold") { try store.setActive("custom-hold") }
    let reloaded = check.expectNoThrow("reload the custom hold") { try PresetStore(url: url).load() }
    check.expectEqual(reloaded?.preset(id: "custom-hold")?.target ?? 0, 85, "a custom hold keeps its target")
    check.expect(reloaded?.preset(id: "custom-hold")?.input == .cpu, "a custom hold keeps its input")
    check.expectEqual(reloaded?.active ?? "", "custom-hold", "a custom hold can be active")

    // A version 2 file has no targets: it decodes, and every preset is a curve.
    let v2JSON = """
    {"version":2,"active":"mine","presets":[{"id":"mine","name":"Mine","input":"max","points":[{"t":30,"p":10},{"t":80,"p":90}]}]}
    """
    let v2Data = Data(v2JSON.utf8)
    try? v2Data.write(to: url)
    let decodedV2 = check.expectNoThrow("decode a version 2 file") {
        try JSONDecoder().decode(PresetLibrary.self, from: v2Data)
    }
    check.expect(decodedV2?.presets.allSatisfy { !$0.isHold } ?? false, "version 2 presets are all curves")
    let v2 = check.expectNoThrow("load a version 2 file") { try PresetStore(url: url).load() }
    check.expectEqual(v2?.version ?? 0, 3, "a version 2 file is rewritten as version 3")
    check.expect(v2?.preset(id: "mine")?.target == nil, "a preset without target decodes with a nil target")
    check.expectEqual(v2?.preset(id: "mine")?.name ?? "", "Mine", "the version 2 preset is kept")
    check.expectEqual(v2?.active ?? "", "mine", "the version 2 active preset is kept")

    // A stored hold that the helper would refuse is dropped by merging.
    let badHoldsJSON = """
    {"version":3,"active":"too-hot","presets":[
    {"id":"too-hot","name":"Too Hot","input":"cpu","points":[],"target":200},
    {"id":"battery-hold","name":"Battery Hold","input":"battery","points":[],"target":35},
    {"id":"good-hold","name":"Good Hold","input":"gpu","points":[],"target":80},
    {"id":"good-curve","name":"Good Curve","input":"max","points":[{"t":30,"p":10},{"t":80,"p":90}]}
    ]}
    """
    try? Data(badHoldsJSON.utf8).write(to: url)
    let filtered = check.expectNoThrow("load drops unusable holds") { try PresetStore(url: url).load() }
    check.expectEqual(filtered?.preset(id: "too-hot"), nil, "a hold above the helper range is dropped")
    check.expectEqual(filtered?.preset(id: "battery-hold"), nil, "a battery hold is dropped")
    check.expectEqual(filtered?.preset(id: "good-hold")?.target ?? 0, 80, "a valid hold is kept")
    check.expect(filtered?.preset(id: "good-curve")?.isHold == false, "a valid curve is kept")
    check.expectEqual(filtered?.active ?? "", PresetLibrary.autoID, "a dropped active hold repairs to auto")

    // Visibility depends on the machine: a system hold needs TVS0, and every hold waits for Ftst machines.
    let withCustomHold = PresetLibrary(active: PresetLibrary.autoID,
                                       presets: defaults.presets + [Preset(id: "custom-hold", name: "My Hold",
                                                                           input: .cpu, points: [], target: 85)])
    let all = withCustomHold.visiblePresets(hasSystem: true, hasForceTest: false)
    check.expectEqual(all.count, withCustomHold.presets.count, "every preset is visible on a TVS0 machine without Ftst")
    let noSystem = withCustomHold.visiblePresets(hasSystem: false, hasForceTest: false)
    check.expect(!noSystem.contains { $0.id == PresetLibrary.quietHoldID }, "quiet45 is hidden without TVS0")
    check.expect(noSystem.contains { $0.id == "custom-hold" }, "a non-system hold is visible without TVS0")
    let ftst = withCustomHold.visiblePresets(hasSystem: true, hasForceTest: true)
    check.expect(ftst.allSatisfy { !$0.isHold }, "every hold is hidden with Ftst")
    check.expectEqual(ftst.map(\.id), ["silent", "balanced", "performance", "full"], "Ftst keeps every curve preset")
}

// MARK: - HelperCommand round trips

expectRoundTrip("PING", "PING", serializedAs: "PING")
expectRoundTrip("STATUS", "STATUS", serializedAs: "STATUS")
expectRoundTrip("AUTO", "AUTO", serializedAs: "AUTO")
expectRoundTrip("CURVE max", "CURVE max 50:0,70:15,85:45,95:100",
                serializedAs: "CURVE max 50:0,70:15,85:45,95:100")
expectRoundTrip("CURVE cpu", "CURVE cpu 40:20,55:40,70:70,85:100",
                serializedAs: "CURVE cpu 40:20,55:40,70:70,85:100")
expectRoundTrip("CURVE gpu", "CURVE gpu 30:100,100:100",
                serializedAs: "CURVE gpu 30:100,100:100")
expectRoundTrip("CURVE decimals", "CURVE max 40:20.5,60.5:80.25",
                serializedAs: "CURVE max 40:20.50,60.50:80.25")
expectRoundTrip("CURVE lowercase verb", "curve max 30:0,90:100",
                serializedAs: "CURVE max 30:0,90:100")
expectRoundTrip("FIXED int", "FIXED 40", serializedAs: "FIXED 40")
expectRoundTrip("FIXED decimal", "FIXED 62.5", serializedAs: "FIXED 62.50")
expectRoundTrip("HOLD system", "HOLD system 45", serializedAs: "HOLD system 45")
expectRoundTrip("HOLD cpu decimal", "HOLD cpu 72.25", serializedAs: "HOLD cpu 72.25")
expectRoundTrip("HOLD lowercase verb", "hold max 85.5", serializedAs: "HOLD max 85.50")
let holdSystem = check.expectNoThrow("HOLD system parses") { try HelperCommand.parse("HOLD system 45") }
check.expectEqual(holdSystem, HelperCommand.hold(input: .system, target: 45), "HOLD system 45 parses to .hold(.system, 45)")
let holdMax = check.expectNoThrow("HOLD lowercase verb parses") { try HelperCommand.parse("hold max 85.5") }
check.expectEqual(holdMax, HelperCommand.hold(input: .max, target: 85.5), "hold max 85.5 parses to .hold(.max, 85.5)")

// MARK: - HelperCommand rejections

expectProtoError("empty line", .emptyLine, "")
expectProtoError("whitespace line", .emptyLine, "   ")
expectProtoError("too long", .tooLong(max: HelperPaths.maxLineBytes), String(repeating: "PING", count: 200))
expectProtoError("unknown verb", .unknownCommand("FOO"), "FOO")
expectProtoError("unknown verb with args", .unknownCommand("PINGX"), "PINGX 1 2")
expectProtoError("PING extra args", .malformed("PING takes no arguments"), "PING now")
expectProtoError("STATUS extra args", .malformed("STATUS takes no arguments"), "STATUS now")
expectProtoError("AUTO extra args", .malformed("AUTO takes no arguments"), "AUTO now")
expectProtoError("CURVE no args", .malformed("CURVE needs <input> <points>"), "CURVE")
expectProtoError("CURVE one arg", .malformed("CURVE needs <input> <points>"), "CURVE max")
expectProtoError("CURVE unknown input", .badValue("unknown curve input bogus"), "CURVE bogus 1:1,2:2")
expectProtoError("CURVE one point", .badValue("curve needs at least 2 points (has 1)"), "CURVE max 50:0")
expectProtoError("CURVE missing colon", .malformed("point is not t:p: 50"), "CURVE max 50,60:10")
expectProtoError("CURVE non-increasing t", .badValue(CurveError.notStrictlyIncreasing(index: 1).description),
                 "CURVE max 60:10,50:20")
expectProtoError("CURVE decreasing p", .badValue(CurveError.decreasingPercent(index: 1).description),
                 "CURVE max 50:50,60:10")
expectProtoError("CURVE p out of range", .badValue(CurveError.percentOutOfRange(index: 1).description),
                 "CURVE max 50:0,60:200")
expectProtoError("CURVE t out of range", .badValue(CurveError.temperatureOutOfRange(index: 1).description),
                 "CURVE max 120:0,140:10")
expectProtoError("CURVE non-finite temperature", .badValue("non-finite temperature: inf"), "CURVE max inf:0,10:10")
expectProtoError("CURVE non-finite percent", .badValue("non-finite percent: nan"), "CURVE max 50:0,60:nan")
expectProtoError("CURVE bad number", .badValue("non-finite percent: abc"), "CURVE max 50:0,60:abc")
expectProtoError("CURVE 13 points", .badValue(CurveError.tooManyPoints(13).description),
                 "CURVE max 0:0,5:5,10:10,15:15,20:20,25:25,30:30,35:35,40:40,45:45,50:50,55:55,60:60")
expectProtoError("FIXED no arg", .malformed("FIXED needs <percent>"), "FIXED")
expectProtoError("FIXED too many args", .malformed("FIXED needs <percent>"), "FIXED 40 50")
expectProtoError("FIXED over 100", .badValue("fixed percent outside 0...100: 101"), "FIXED 101")
expectProtoError("FIXED negative", .badValue("fixed percent outside 0...100: -1"), "FIXED -1")
expectProtoError("FIXED non-numeric", .badValue("fixed percent is not a finite number: abc"), "FIXED abc")
expectProtoError("FIXED non-finite", .badValue("fixed percent is not a finite number: nan"), "FIXED nan")
expectProtoError("HOLD no args", .malformed("HOLD needs <input> <target>"), "HOLD system")
expectProtoError("HOLD too many args", .malformed("HOLD needs <input> <target>"), "HOLD system 45 1")
expectProtoError("HOLD battery", .badValue("hold cannot follow the battery"), "HOLD battery 40")
expectProtoError("HOLD unknown input", .badValue("unknown hold input bogus"), "HOLD bogus 45")
expectProtoError("HOLD non-numeric", .badValue("hold target is not a finite number: abc"), "HOLD system abc")
expectProtoError("HOLD nan", .badValue("hold target is not a finite number: nan"), "HOLD system nan")
expectProtoError("HOLD inf", .badValue("hold target is not a finite number: inf"), "HOLD system inf")
expectProtoError("HOLD below range", .badValue("hold target outside 20...110: 19.9"), "HOLD system 19.9")
expectProtoError("HOLD above range", .badValue("hold target outside 20...110: 110.1"), "HOLD system 110.1")

// MARK: - HelperStatus serialize / parse

let statusCurve = HelperStatus(mode: .curve, inputTemperature: 62.5, targetRPM: [3200, 4100.5], writes: 7, error: nil)
check.expectEqual(statusCurve.serialized, "OK mode=curve temp=62.5 rpm=3200.0,4100.5 writes=7",
                  "status serialized without error")
check.expectEqual(HelperStatus.parse(statusCurve.serialized), statusCurve, "status round trip without error")

let statusError = HelperStatus(mode: .monitor, inputTemperature: nil, targetRPM: [], writes: 0, error: "smc:0x82")
check.expectEqual(statusError.serialized, "OK mode=monitor temp=- rpm=- writes=0 err=smc:0x82",
                  "status serialized with error")
check.expectEqual(HelperStatus.parse(statusError.serialized), statusError, "status round trip with error")

let statusAuto = HelperStatus(mode: .auto)
check.expectEqual(statusAuto.serialized, "OK mode=auto temp=- rpm=- writes=0", "status auto serialized")
check.expectEqual(HelperStatus.parse(statusAuto.serialized), statusAuto, "status auto round trip")

let statusPanic = HelperStatus(mode: .panic, inputTemperature: 96, targetRPM: [7826], writes: 12)
check.expectEqual(HelperStatus.parse(statusPanic.serialized), statusPanic, "status panic round trip")
let statusFixed = HelperStatus(mode: .fixed, inputTemperature: 50, targetRPM: [5000, 5000], writes: 3)
check.expectEqual(HelperStatus.parse(statusFixed.serialized), statusFixed, "status fixed round trip")
let statusHold = HelperStatus(mode: .hold, inputTemperature: 45, targetRPM: [3166, 3168], writes: 9)
check.expectEqual(statusHold.serialized, "OK mode=hold temp=45.0 rpm=3166.0,3168.0 writes=9", "status hold serialized")
check.expectEqual(HelperStatus.parse(statusHold.serialized), statusHold, "status hold round trip")

check.expect(HelperStatus.parse("") == nil, "status parse rejects empty")
check.expect(HelperStatus.parse("garbage") == nil, "status parse rejects junk")
check.expect(HelperStatus.parse("OK temp=50 rpm=- writes=0") == nil, "status parse rejects missing mode")
check.expect(HelperStatus.parse("OK mode=bogus temp=- rpm=- writes=0") == nil, "status parse rejects unknown mode")
check.expect(HelperStatus.parse("OK mode=curve temp=50 rpm=abc writes=0") == nil, "status parse rejects non-numeric rpm")
check.expect(HelperStatus.parse("OK mode=curve temp=abc rpm=- writes=0") == nil, "status parse rejects non-numeric temp")
check.expect(HelperStatus.parse("OK mode=curve temp=50 rpm=- writes=x") == nil, "status parse rejects non-numeric writes")
check.expect(HelperStatus.parse("OK mode=curve temp=50 rpm=- writes=0 extra") == nil, "status parse rejects trailing junk")
check.expect(HelperStatus.parse("NO mode=curve temp=50 rpm=- writes=0") == nil, "status parse rejects missing OK")

// MARK: - Battery input

check.expect(FanControlInput.allCases.contains(.battery), "battery is a selectable curve input")
expectRoundTrip("CURVE battery", "CURVE battery 20:10,40:30", serializedAs: "CURVE battery 20:10,40:30")
expectProtoError("CURVE battery non-finite", .badValue("non-finite temperature: nan"), "CURVE battery nan:1,50:2")
expectProtoError("CURVE battery misspelled", .badValue("unknown curve input batt"), "CURVE batt 20:0,40:100")
expectProtoError("CURVE battery one point", .badValue("curve needs at least 2 points (has 1)"), "CURVE battery 30:10")

do {
    let preset = Preset(id: "bat", name: "Battery", input: .battery, points: silentCurve().points)
    let encoded = try? JSONEncoder().encode(preset)
    check.expect(encoded.map { String(decoding: $0, as: UTF8.self).contains("\"input\":\"battery\"") } ?? false,
                 "a battery preset is stored with input \"battery\"")
    let decoded = encoded.flatMap { try? JSONDecoder().decode(Preset.self, from: $0) }
    check.expectEqual(decoded, preset, "a battery preset survives an encode/decode round trip")
}

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("openfan-corecheck-v1-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("presets.json")
    _ = try? PresetStore(url: url).load()
    let before = try? Data(contentsOf: url)
    let library = try? PresetStore(url: url).load()
    let after = try? Data(contentsOf: url)
    check.expect(before != nil && before == after, "loading an existing v1 presets file leaves its bytes untouched")
    check.expect(library?.presets.filter { !$0.isHold }.allSatisfy { $0.input == .max } ?? false,
                 "the v1 curve presets keep their max input")
}

// MARK: - Memory pressure

check.expectEqual(MemoryPressure(rawValue: 1), .normal, "level 1 is normal (green)")
check.expectEqual(MemoryPressure(rawValue: 2), .warning, "level 2 is warning (yellow)")
check.expectEqual(MemoryPressure(rawValue: 4), .critical, "level 4 is critical (red)")
for raw in [0, 3, 5, 8, 16, -1] {
    check.expectEqual(MemoryPressure(rawValue: raw), nil, "level \(raw) is not a pressure state")
}
check.expectEqual(MemoryPressure.allCases.count, 3, "exactly three pressure states")
check.expect(MemoryPressure.read() != nil, "kern.memorystatus_vm_pressure_level is readable on this machine")
print("[CoreCheck]     live pressure level: \(MemoryPressure.read().map { String($0.rawValue) } ?? "nil")")

// MARK: - Menu bar template

do {
    let v = MenuBarValues(max: 46.2, cpu: 45.9, gpu: 43.1, battery: 31.0, fanRPMs: [3166, 3168], presetName: "Performance")
    func r(_ template: String) -> String { MenuBarTemplate.render(template, v) }
    let degree = "\u{00B0}"
    check.expectEqual(r("{max}\(degree) {rpm}"), "46\(degree) 3.2k", "default template shows the hottest die and the peak rpm")
    check.expectEqual(r("CPU {cpu}\(degree) \u{00B7} {rpm}"), "CPU 46\(degree) \u{00B7} 3.2k", "literal text around tokens is kept")
    check.expectEqual(r("{cpu}/{gpu}/{bat}"), "46/43/31", "cpu, gpu and battery tokens")
    check.expectEqual(r("{rpm0} {rpm1} {rpm}"), "3.2k 3.2k 3.2k", "per-fan and peak rpm tokens")
    check.expectEqual(r("{preset}"), "Performance", "preset token")
    check.expectEqual(r("{foo}"), "{foo}", "an unknown token stays literal")
    check.expectEqual(r("{rpm2}"), "{rpm2}", "a fan token outside the list stays literal")
    check.expectEqual(r("{max"), "{max", "an unmatched opening brace stays literal")
    check.expectEqual(r("max}"), "max}", "an unmatched closing brace stays literal")
    check.expectEqual(r("{}"), "{}", "empty braces stay literal")
    check.expectEqual(r("{{max}}"), "{46}", "nested braces expand only the inner token")
    check.expectEqual(r(""), "", "an empty template renders no text")

    let none = MenuBarValues()
    check.expectEqual(MenuBarTemplate.render("{max}\(degree) {rpm}", none), "--\(degree) --", "missing readings render --")
    check.expectEqual(MenuBarTemplate.render("{preset}", none), "--", "a missing preset renders --")
    check.expectEqual(MenuBarTemplate.render("{rpm1}", MenuBarValues(fanRPMs: [2500])), "--", "a fan that does not exist renders --")
    check.expectEqual(MenuBarTemplate.render("{rpm}", MenuBarValues(fanRPMs: [nil, 2400])), "2.4k", "the peak ignores a fan without a reading")
    check.expectEqual(MenuBarTemplate.render("{rpm}", MenuBarValues(fanRPMs: [950])), "950", "rpm below 1000 prints whole")
    check.expectEqual(MenuBarTemplate.render("{rpm}", MenuBarValues(fanRPMs: [7826])), "7.8k", "rpm from 1000 prints in thousands")
    check.expectEqual(MenuBarTemplate.render("{max}", MenuBarValues(max: .nan)), "--", "NaN renders --")
    check.expectEqual(MenuBarTemplate.render("{max}", MenuBarValues(max: .infinity)), "--", "infinity renders --")
    check.expectEqual(MenuBarTemplate.render("{rpm}", MenuBarValues(fanRPMs: [-5])), "--", "a negative rpm renders --")
    check.expectEqual(MenuBarTemplate.render("{preset}", MenuBarValues(max: 46, presetName: "{max}")), "{max}", "substituted values are not expanded again")

    check.expectEqual(r(String(repeating: "x", count: 100)).count, MenuBarTemplate.maxRenderedLength, "output is capped")
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
    check.expectEqual(r(String(repeating: family, count: 50)), String(repeating: family, count: MenuBarTemplate.maxRenderedLength), "the cap never splits an emoji family")
    check.expectEqual(r(String(repeating: "\u{C628}\u{B3C4}", count: 30)).count, MenuBarTemplate.maxRenderedLength, "CJK text is capped by characters")

    check.expectEqual(MenuBarTemplate.sensors(in: ""), [], "an empty template needs no sensor")
    check.expectEqual(MenuBarTemplate.sensors(in: "{preset}"), [], "the preset name needs no sensor")
    check.expectEqual(MenuBarTemplate.sensors(in: AppSettings.defaultTemplate), [.cpu, .gpu, .fans], "the default template reads CPU, GPU and the fans")
    check.expectEqual(MenuBarTemplate.sensors(in: "{bat}"), [.battery], "battery needs the battery sensors only")
    check.expectEqual(MenuBarTemplate.sensors(in: "{cpu} {rpm0}"), [.cpu, .fans], "each token adds its own group")
    check.expectEqual(MenuBarTemplate.sensors(in: "{nope}{cpu"), [], "an unknown or unclosed token needs nothing")
}

// MARK: - Fan speed wording

do {
    let fan = FanInfo(index: 0, minRPM: 2317, maxRPM: 7826)
    let percent = FanSpeedFormat(fan: fan, showsRPM: false)
    let rpm = FanSpeedFormat(fan: fan, showsRPM: true)
    check.expectEqual(percent.text(forCurvePercent: 0), "Auto", "a curve at 0 hands the fans back to macOS")
    check.expectEqual(rpm.text(forCurvePercent: -5), "Auto", "below 0 is still Auto")
    check.expectEqual(percent.text(forCurvePercent: 3), "32%", "a curve value of 3 is 32 % of top speed: the fan's range starts at its minimum")
    check.expectEqual(rpm.text(forCurvePercent: 3), "2482 rpm", "and the same value in rpm")
    check.expectEqual(percent.text(forCurvePercent: 0.01), "30%", "the slowest speed the fan can run is 30 % of top speed")
    check.expectEqual(percent.text(forCurvePercent: 100), "100%", "a curve value of 100 is top speed")
    check.expectEqual(rpm.text(forCurvePercent: 100), "7826 rpm", "top speed in rpm")
    check.expectEqual(FanSpeedFormat(fan: nil, showsRPM: false).text(forCurvePercent: 50), "--", "without a fan there is nothing to convert")
}

// MARK: - Settings store

do {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("openfan-settings-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("settings.json")

    let store = SettingsStore(url: url)
    check.expectEqual(store.load(), AppSettings(), "a missing file loads the defaults")
    check.expect(!FileManager.default.fileExists(atPath: url.path), "loading the defaults does not create the file")

    store.setTemplate("CPU {cpu}")
    store.setShowPressureDot(false)
    store.setFanUnitsRPM(true)
    _ = check.expectNoThrow("settings save") { try store.save() }
    let reloaded = SettingsStore(url: url).load()
    check.expectEqual(reloaded.menuBarTemplate, "CPU {cpu}", "a saved template survives a reload")
    check.expectEqual(reloaded.showPressureDot, false, "a saved dot toggle survives a reload")
    check.expectEqual(reloaded.fanUnitsRPM, true, "a saved fan unit choice survives a reload")

    try? Data("{ not json".utf8).write(to: url)
    check.expectEqual(SettingsStore(url: url).load(), AppSettings(), "a corrupt file loads the defaults")
    check.expect(FileManager.default.fileExists(atPath: url.path + ".bak"), "a corrupt file is kept as settings.json.bak")
    check.expect(!FileManager.default.fileExists(atPath: url.path), "the corrupt file leaves its original path")

    try? Data(#"{"menuBarTemplate":"x"}"#.utf8).write(to: url)
    check.expectEqual(SettingsStore(url: url).load().showPressureDot, true, "a missing key takes its default")
    check.expectEqual(SettingsStore(url: url).load().fanUnitsRPM, false, "fan units default to percent")

    try? Data(#"{"menuBarTemplate":"   "}"#.utf8).write(to: url)
    check.expectEqual(SettingsStore(url: url).load().menuBarTemplate, "   ", "a blank template is kept as written")

    try? Data("{\"menuBarTemplate\":\"\(String(repeating: "a", count: 500))\"}".utf8).write(to: url)
    check.expectEqual(SettingsStore(url: url).load().menuBarTemplate.count, AppSettings.maxTemplateLength, "an oversized template is cut to the limit")

    store.setTemplate(String(repeating: "b", count: 500))
    check.expectEqual(store.settings.menuBarTemplate.count, AppSettings.maxTemplateLength, "setTemplate cuts to the limit")
}

// MARK: - Updates

do {
    check.expectEqual(AppVersion("1.4")?.description, "1.4", "1.4 parses")
    check.expectEqual(AppVersion("v1.10")?.description, "1.10", "v1.10 parses")
    for bad in ["", "1", "1.4.1", "1.x", "-1.4", "1.-4", "v", "1..4", " 1.4", "1.٤"] {
        check.expect(AppVersion(bad) == nil, "\(bad.debugDescription) is not a version")
    }
    if let a = AppVersion("1.9"), let b = AppVersion("1.10"), let c = AppVersion("2.0") {
        check.expect(a < b && b < c, "1.9 < 1.10 < 2.0")
    }

    let current = AppVersion(major: 1, minor: 3)
    func release(tag: String, draft: Bool = false, prerelease: Bool = false, assets: [(String, String)]) -> Data {
        let list = assets.map { #"{"name":"\#($0.0)","browser_download_url":"\#($0.1)"}"# }.joined(separator: ",")
        return Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(prerelease),"html_url":"https://github.com/stevenahhh/openfan/releases/tag/\#(tag)","assets":[\#(list)]}"#.utf8)
    }
    let base = "https://github.com/stevenahhh/openfan/releases/download/v1.4/"
    let good = [("OpenFan.zip", base + "OpenFan.zip"), ("OpenFan.zip.sig", base + "OpenFan.zip.sig")]
    let update = AvailableUpdate.parse(release(tag: "v1.4", assets: good), newerThan: current)
    check.expectEqual(update?.version.description, "1.4", "a newer release with both assets is an update")
    check.expectEqual(update?.archiveURL.lastPathComponent, "OpenFan.zip", "the archive URL is the zip")
    check.expect(AvailableUpdate.parse(release(tag: "v1.3", assets: good), newerThan: current) == nil, "the same version is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.2", assets: good), newerThan: current) == nil, "an older version is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4", draft: true, assets: good), newerThan: current) == nil, "a draft is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4", prerelease: true, assets: good), newerThan: current) == nil, "a prerelease is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4", assets: [good[0]]), newerThan: current) == nil, "a release without a signature is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4.1", assets: good), newerThan: current) == nil, "a tag that is not MAJOR.MINOR is no update")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4", assets: [("OpenFan.zip", "http://github.com/a.zip"), good[1]]), newerThan: current) == nil, "plain HTTP is refused")
    check.expect(AvailableUpdate.parse(release(tag: "v1.4", assets: [("OpenFan.zip", "https://example.com/OpenFan.zip"), good[1]]), newerThan: current) == nil, "a host other than GitHub is refused")
    check.expect(AvailableUpdate.parse(Data("not json".utf8), newerThan: current) == nil, "garbage is no update")

    let key = Curve25519.Signing.PrivateKey()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    let archive = Data("archive bytes".utf8)
    let signature = Data((try! key.signature(for: archive)).base64EncodedString().utf8 + [10])
    check.expect(UpdateSignature.isValid(archive: archive, signature: signature, publicKey: publicKey), "a matching signature is valid, trailing newline allowed")
    check.expect(!UpdateSignature.isValid(archive: Data("archive bytez".utf8), signature: signature, publicKey: publicKey), "a changed archive is refused")
    check.expect(!UpdateSignature.isValid(archive: archive, signature: signature), "a signature from another key is refused")
    check.expect(!UpdateSignature.isValid(archive: archive, signature: Data("%%%".utf8), publicKey: publicKey), "a signature that is not base64 is refused")
    check.expect(Data(base64Encoded: UpdateSignature.publicKey)?.count == 32, "the embedded public key is 32 bytes")

    let now = Date(timeIntervalSince1970: 1_000_000)
    check.expect(UpdateSchedule.isDue(lastCheck: nil, now: now), "never checked: due")
    check.expect(!UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-3600), now: now), "an hour ago: not due")
    check.expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now), "a day ago: due")
    check.expect(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(3600), now: now), "a check in the future (clock moved back): due")
}

// MARK: - Chip generation and its temperature keys

do {
    check.expectEqual(ChipGeneration(brand: "Apple M5 Pro").number, 5, "M5 Pro is generation 5")
    check.expectEqual(ChipGeneration(brand: "Apple M1").number, 1, "M1 is generation 1")
    check.expectEqual(ChipGeneration(brand: "Apple M4 Max").number, 4, "M4 Max is generation 4")
    check.expectEqual(ChipGeneration(brand: "Apple M3 Ultra").number, 3, "M3 Ultra is generation 3")
    check.expectEqual(ChipGeneration(brand: "Intel(R) Core(TM) i9").number, nil, "an Intel chip has no M generation")
    check.expectEqual(ChipGeneration(brand: "").number, nil, "an empty brand has no generation")
    check.expect(SensorCatalog.cpuKeys(for: ChipGeneration(number: 5)).contains("Tp0O"), "M5 CPU keys include Tp0O")
    check.expect(SensorCatalog.cpuKeys(for: ChipGeneration(number: 3)).contains("Tf04"), "M3 CPU keys include Tf04")
    check.expect(SensorCatalog.gpuKeys(for: ChipGeneration(number: 1)).contains("Tg05"), "M1 GPU keys include Tg05")
    let unknown = SensorCatalog.cpuKeys(for: ChipGeneration(number: 9))
    check.expect(unknown.contains("Tp00") && unknown.contains("Tp09") && unknown.contains("Te05"), "a newer chip gets every known CPU key")
    check.expectEqual(unknown.count, Set(unknown).count, "without duplicates")
    for generation in 1...5 {
        check.expect(!SensorCatalog.cpuKeys(for: ChipGeneration(number: generation)).isEmpty, "M\(generation) has CPU keys")
        check.expect(!SensorCatalog.gpuKeys(for: ChipGeneration(number: generation)).isEmpty, "M\(generation) has GPU keys")
    }
}

exit(check.summary())
