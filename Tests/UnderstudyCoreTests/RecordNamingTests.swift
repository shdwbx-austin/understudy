import Foundation
import Testing
@testable import UnderstudyCore

@Suite("Record naming")
struct RecordNamingTests {
    /// Sun 15 Nov 2026, 20:15:30 in a fixed calendar.
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    var date: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 20, minute: 15, second: 30))! }

    @Test func defaultIsDeckArtistDateTime() {
        let n = RecordNaming(artist: "RKS")
        #expect(n.name(deck: "ME 1", number: 1, at: date, calendar: calendar) == "ME_1_RKS_2026-11-15_2015")
        // The stray leading space that made "_ME_1_0010" no longer leaks into the name.
        #expect(n.name(deck: " ME 1", number: 1, at: date, calendar: calendar) == "ME_1_RKS_2026-11-15_2015")
    }

    @Test func emptyTokensDropTheirSeparator() {
        let n = RecordNaming()   // no artist
        #expect(n.name(deck: "AUX 1", number: 3, at: date, calendar: calendar) == "AUX_1_2026-11-15_2015")
        #expect(RecordNaming(template: "{show}_{deck}").name(deck: "ME 2", number: 2, show: "", at: date, calendar: calendar) == "ME_2")
    }

    @Test func customTemplates() {
        let n = RecordNaming(template: "{artist}-{day}-{deck}-{seconds}", artist: "Rainbow Kitten Surprise")
        #expect(n.name(deck: "ME 1", number: 1, at: date, calendar: calendar) == "Rainbow_Kitten_Surprise-Sun-ME_1-201530")
        #expect(RecordNaming(template: "CAM{n}_{show}_{year}{month}{dom}").name(deck: "x", number: 4, show: "Main set", at: date, calendar: calendar)
                == "CAM4_Main_set_20261115")
        #expect(RecordNaming(template: "{DECK}").name(deck: "ME 1", number: 1, at: date, calendar: calendar) == "ME_1")   // case-insensitive
        #expect(RecordNaming(template: "").name(deck: "ME 1", number: 1, at: date, calendar: calendar) == "ME_1_2026-11-15_2015")
    }

    @Test func unsafeCharactersAndLength() {
        #expect(RecordNaming.sanitized("ME 1/PGM: Wide!") == "ME_1_PGM_Wide")
        #expect(RecordNaming.sanitized("Café ✨ __ -- x") == "Caf-x")   // runs of separators collapse
        #expect(RecordNaming.sanitized("///") == "understudy")
        #expect(RecordNaming.sanitized(String(repeating: "a", count: 100)).count == RecordNaming.maxLength)
        #expect(HyperDeckCommand.recordPrefix("ME 1/PGM") == "configuration: record prefix: ME_1_PGM")
    }

    @Test func oldSettingsGetTheDefault() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.recordNaming == RecordNaming())
    }
}
