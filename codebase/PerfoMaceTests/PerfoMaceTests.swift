//
//  PerfoMaceTests.swift
//  PerfoMaceTests
//
//  Created by Jyoti Dash on 28/01/26.
//

import XCTest

final class PerfoMaceTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is where the performance testing happens
        measure {
            // We are telling Xcode to time how long it takes
            // to count to 100,000
            var count = 0
            for i in 1...100_000 {
                count += i
            }
            print("Done counting to \(count)")
        }
    }

}
