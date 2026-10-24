import HubLink
import XCTest

/// The Hub, the Mac and the iPhone tag admins and suspended people beside their name in Users.
final class LinkUserTagTests: XCTestCase {
    func testAdminsAndSuspendedPeopleAreTaggedAdminFirst() {
        XCTAssertEqual(LinkUserTag.tags(isAdmin: false, isSuspended: false), [])
        XCTAssertEqual(LinkUserTag.tags(isAdmin: true, isSuspended: false).map(\.title), ["Admin"])
        XCTAssertEqual(LinkUserTag.tags(isAdmin: false, isSuspended: true).map(\.title), ["Suspended"])
        XCTAssertEqual(LinkUserTag.tags(isAdmin: true, isSuspended: true), [.admin, .suspended])
    }

    func testALinkUserIsTaggedFromItsFlags() {
        let admin = LinkUser(id: UUID(), name: "Ada", plan: UUID(), canPairDevices: true, isAdmin: true, devices: [])
        let suspended = LinkUser(id: UUID(), name: "Bo", plan: UUID(), canPairDevices: false, isAdmin: false, devices: [],
                                 isSuspended: true)
        XCTAssertEqual(admin.tags, [.admin])
        XCTAssertEqual(suspended.tags, [.suspended])
    }
}
