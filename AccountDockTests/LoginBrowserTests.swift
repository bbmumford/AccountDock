import XCTest
@testable import AccountDock

final class LoginBrowserTests: XCTestCase {
    func testTheSignInPageGoesToTheBrowserWhoseWindowIsFrontmost() {
        let browsers: Set = ["/Applications/Safari.app", "/Applications/Google Chrome.app"]
        let owners = ["/Applications/agterm.app", "/Applications/Google Chrome.app", "/Applications/Safari.app"]
        XCTAssertEqual(LoginBrowser.frontmostBrowser(windowOwners: owners, browsers: browsers), "/Applications/Google Chrome.app")
        XCTAssertNil(LoginBrowser.frontmostBrowser(windowOwners: ["/Applications/agterm.app"], browsers: browsers),
                     "with no browser window open the default browser is used")
    }

    func testTheOpenerScriptQuotesTheAppPath() {
        XCTAssertEqual(LoginBrowser.openerScript(app: "/Applications/Google Chrome.app"),
                       "#!/bin/sh\nexec /usr/bin/open -a '/Applications/Google Chrome.app' \"$@\"\n")
        XCTAssertTrue(LoginBrowser.openerScript(app: "/Apps/It's.app").contains(#"'/Apps/It'\''s.app'"#))
        XCTAssertFalse(LoginBrowser.openerURL.path.contains(" "))
    }
}
