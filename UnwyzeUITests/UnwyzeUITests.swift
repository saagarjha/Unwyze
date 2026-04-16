//
//  UnwyzeUITests.swift
//  UnwyzeUITests
//
//  Created by Saagar Jha on 4/13/26.
//

import XCTest

final class UnwyzeUITests: XCTestCase {
	let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
		app.launchEnvironment["UI_TESTING"] = "1"
    }

    @MainActor
    func testScreenshots() throws {
		app.launch()
		
		let attachment = XCTAttachment(screenshot: app.screenshot())
		attachment.name = "0"
		attachment.lifetime = .keepAlways
		add(attachment)
    }
}
