import Foundation
import Testing
@testable import Domain

@Suite("MonthlyResetDate")
struct MonthlyResetDateTests {

    @Test("returns first instant of next UTC month when reference is mid-month")
    func midMonth() {
        let ref = ISO8601DateFormatter().date(from: "2026-06-15T12:00:00Z")!
        let result = MonthlyResetDate.nextMonthlyResetDate(referenceDate: ref)
        #expect(result == ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
    }

    @Test("rolls into next year from December")
    func december() {
        let ref = ISO8601DateFormatter().date(from: "2026-12-31T23:59:59Z")!
        let result = MonthlyResetDate.nextMonthlyResetDate(referenceDate: ref)
        #expect(result == ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z"))
    }

    @Test("returns start of next month when reference is exactly the boundary")
    func exactlyBoundary() {
        let ref = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!
        let result = MonthlyResetDate.nextMonthlyResetDate(referenceDate: ref)
        #expect(result == ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
    }

    @Test("result is always in the future relative to reference")
    func alwaysFuture() {
        let ref = Date()
        let result = MonthlyResetDate.nextMonthlyResetDate(referenceDate: ref)
        #expect(result > ref)
    }
}
