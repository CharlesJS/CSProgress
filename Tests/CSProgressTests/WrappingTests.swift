//
//  WrappingTests.swift
//  
//
//  Created by Charles Srstka on 10/24/22.
//

import Foundation
import XCTest
@testable import CSProgress
@testable import CSProgress_Foundation

final class WrappingTest: XCTestCase {
    func testKVONotificationsOccurOnMainThread() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        let child = await parent.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 100)

        let userInfoKey = ProgressUserInfoKey("com.charlessoft.CSProgress.WrappingTest.FractionUpdatedThread")

        let watcher = parent.observe(\.fractionCompleted) { p, _ in
            XCTAssertTrue(Thread.isMainThread)
            p.setUserInfoObject(Thread.current, forKey: userInfoKey)
        }

        await child.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000)

        let thread = await MainActor.run { parent.userInfo }[userInfoKey] as? Thread
        XCTAssertTrue(thread?.isMainThread ?? false)
        _ = watcher.self // prevent ARC from reaping the watcher early
    }
}
