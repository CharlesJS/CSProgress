// This source file is adapted from code which is part of the Swift.org open source project.
//
// Copyright (c) 2014 - 2016 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
// Selectively converted by Charles Srstka for use in testing CSProgress / Foundation.Progress wrapping.
//

import XCTest
import Foundation
@testable import CSProgress
@testable import CSProgress_Foundation
import XCTAsyncAssertions

final class ConvertedFoundationProgressWrappingTest: XCTestCase {
    static var allTests: [(String, (ConvertedFoundationProgressWrappingTest) -> () async throws -> Void)] {
        return [
            ("test_totalCompletedChangeAffectsFractionCompleted", test_totalCompletedChangeAffectsFractionCompleted),
            ("test_indeterminateChildrenAffectFractionCompleted", test_indeterminateChildrenAffectFractionCompleted),
            ("test_indeterminateChildrenAffectFractionCompleted2", test_indeterminateChildrenAffectFractionCompleted2),
            ("test_childCompletionFinishesGroups", test_childCompletionFinishesGroups),
            ("test_childrenAffectFractionCompleted_explicit", test_childrenAffectFractionCompleted_explicit),
            ("test_childrenAffectFractionCompleted_explicit_partial", test_childrenAffectFractionCompleted_explicit_partial),
            ("test_childrenAffectFractionCompleted_explicit_child_already_complete", test_childrenAffectFractionCompleted_explicit_child_already_complete),
            ("test_grandchildrenAffectFractionCompleted", test_grandchildrenAffectFractionCompleted),
            ("test_grandchildrenAffectFractionCompleted_explicit", test_grandchildrenAffectFractionCompleted_explicit),
            ("test_mixedExplicitAndImplicitChildren", test_mixedExplicitAndImplicitChildren),
            ("test_handlers", test_handlers),
            ("test_alreadyCancelled", test_alreadyCancelled),
        ]
    }

    func test_totalCompletedChangeAffectsFractionCompleted() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        // Test self
        parent.completedUnitCount = 50
        XCTAssertEqual(0.5, parent.fractionCompleted, accuracy: 0.01)

        parent.completedUnitCount = 0
        // Test child
        let child1 = await parent.pass(pendingUnitCount: 10).makeChild(totalUnitCount: 100)
        await child1.incrementCompletedUnitCount(by: 50)
        try await Task.sleep(nanoseconds: 1000)

        // half of 10% is done in parent
        await XCTAssertEqualAsync(0.05, await MainActor.run { parent.fractionCompleted }, accuracy: 0.01)
        await XCTAssertEqualAsync(0.5, await child1.fractionCompleted, accuracy: 0.01)

        // Up the total amount of work
        parent.totalUnitCount = 200

        XCTAssertEqual(0.5 * (10.0 / 200.0) /* 0.025 */, parent.fractionCompleted, accuracy: 0.01)
        await XCTAssertEqualAsync(0.5, await child1.fractionCompleted, accuracy: 0.01)

        // Change the total in the child, doubling total amount of work
        await child1.setTotalUnitCount(200)
        await XCTAssertEqualAsync (50.0 / 200.0, await child1.fractionCompleted, accuracy: 0.01)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(
            (50.0 / 200.0) * (10.0 / 200),
            await MainActor.run { parent.fractionCompleted },
            accuracy: 0.01
        )

        // Change the total in the child, the other direction, halving the amount of work
        await child1.setTotalUnitCount(100)
        await XCTAssertEqualAsync(50.0 / 100.0, await child1.fractionCompleted, accuracy: 0.01)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(
            (50.0 / 100.0) * (10.0 / 200),
            await MainActor.run { parent.fractionCompleted },
            accuracy: 0.01
        )
    }

    func test_indeterminateChildrenAffectFractionCompleted() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 1000)

        let child1 = await parent.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 10)

        await child1.setCompletedUnitCount(5)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.05, accuracy: 0.01)

        // Child1 becomes indeterminate
        await child1.setCompletedUnitCount(-1)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0, accuracy: 0.01)

        // Become determinate
        // childProgress1's completed unit count is 90% of its total of 10 (10)
        // childProgress1 is 10% of the overall unit count (100 / 1000)
        // the overall count done should be 90% of 10% of 1000, or 0.9 * 0.1 * 1000 = 90
        // the overall percentage done should be 90 / 1000 = 0.09
        // Unlike original test, don't complete the child progress all the way, because that will
        // cause it to complete and subsequently become detached from its parent.
        await child1.setCompletedUnitCount(9)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.09, accuracy: 0.01)

        // Become indeterminate again
        await child1.setCompletedUnitCount(-1)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0, accuracy: 0.01)
    }

    func test_indeterminateChildrenAffectFractionCompleted2() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        let child1 = await parent.pass(pendingUnitCount: 50).makeChild(totalUnitCount: 2)
        let child2 = await parent.pass(pendingUnitCount: 50).makeChild(totalUnitCount: 2)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0, accuracy: 0.01)

        await child1.setCompletedUnitCount(1)
        await child2.setCompletedUnitCount(1)

        // half done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.5, accuracy: 0.01)

        // Move a child to indeterminate
        await child1.setCompletedUnitCount(-1)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.25, accuracy: 0.01)

        // Move it back to determinate
        await child1.setCompletedUnitCount(1)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.5, accuracy: 0.01)
    }

    func test_childCompletionFinishesGroups() async throws {
        let root = Foundation.Progress.discreteProgress(totalUnitCount: 2)
        let child1 = await CSProgress.discreteProgress(totalUnitCount: 1)
        let child2 = await CSProgress.discreteProgress(totalUnitCount: 1)

        await root.addChild(child1, withPendingUnitCount: 1)
        await root.addChild(child2, withPendingUnitCount: 1)

        await child1.incrementCompletedUnitCount(by: 1)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { root.fractionCompleted }, 0.5, accuracy: 0.01)
        await child2.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { root.fractionCompleted }, 1.0, accuracy: 0.01)
        await XCTAssertEqualAsync(await MainActor.run { root.completedUnitCount }, 2)
    }

    func test_childrenAffectFractionCompleted_explicit() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        XCTAssertEqual(parent.fractionCompleted, 0.0)

        let child1 = await CSProgress.discreteProgress(totalUnitCount: 100)
        await parent.addChild(child1, withPendingUnitCount: 10)

        await child1.setCompletedUnitCount(50)

        // let's say some of this work is done inside the become/resign pair
        // half of 10% is done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.05, await MainActor.run { parent.fractionCompleted })

        // ... and the rest is done outside the become/resign pair
        await child1.setCompletedUnitCount(100)

        // Now the rest is done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.10, await MainActor.run { parent.fractionCompleted })

        // Add another child
        let child2 = await CSProgress.discreteProgress(totalUnitCount: 100)
        await parent.addChild(child2, withPendingUnitCount: 90)
        await child2.setCompletedUnitCount(50)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.10 + 0.9 / 2.0, await MainActor.run { parent.fractionCompleted })
    }

    func test_childrenAffectFractionCompleted_explicit_partial() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 2)

        XCTAssertEqual(parent.fractionCompleted, 0.0)

        // Add a child, then update after adding
        let child1 = await CSProgress.discreteProgress(totalUnitCount: 100)
        await parent.addChild(child1, withPendingUnitCount: 1)
        await child1.setCompletedUnitCount(50)

        // Half of 50% is done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.25, await MainActor.run { parent.fractionCompleted })

        // Add a new child, but it is already in process
        let child2 = await CSProgress.discreteProgress(totalUnitCount: 100)
        await child2.setCompletedUnitCount(50)
        await parent.addChild(child2, withPendingUnitCount: 1)

        // half of 50% is done + half of 50% is done == 50% of overall work is done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.50, await MainActor.run { parent.fractionCompleted })
    }

    func test_childrenAffectFractionCompleted_explicit_child_already_complete() async throws {
        // Adding children who are already partially completed should cause the parent fraction completed to be updated
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 2)

        XCTAssertEqual(parent.fractionCompleted, 0.0)

        // Add a child, then update after adding
        let child1 = await CSProgress.discreteProgress(totalUnitCount: 100)
        await child1.setCompletedUnitCount(100)
        await parent.addChild(child1, withPendingUnitCount: 1)

        // all of 50% is done
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.5, await MainActor.run { parent.fractionCompleted })
    }

    func test_grandchildrenAffectFractionCompleted_explicit() async throws {
        // The parent's progress is entirely represented by the 1 grandchild
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        XCTAssertEqual(parent.fractionCompleted, 0.0)

        let child = await CSProgress.discreteProgress(totalUnitCount: 100)
        await parent.addChild(child, withPendingUnitCount: 100)

        let grandchild = await CSProgress.discreteProgress(totalUnitCount: 100)
        await child.addChild(grandchild, withPendingUnitCount: 100)

        // Now we have parentProgress <- childProgress <- grandchildProgress
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0)

        await grandchild.setCompletedUnitCount(50)

        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.50, await MainActor.run { parent.fractionCompleted })
    }

    func test_grandchildrenAffectFractionCompleted() async throws {
        // The parent's progress is entirely represented by the 1 grandchild
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)

        XCTAssertEqual(parent.fractionCompleted, 0.0)

        let child = await parent.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 100)
        let grandchild = await child.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 100)

        // Now we have parentProgress <- childProgress <- grandchildProgress
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0)

        await grandchild.setCompletedUnitCount(50)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(0.50, await MainActor.run { parent.fractionCompleted })
    }

    func test_mixedExplicitAndImplicitChildren() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 3)

        let child1 = await CSProgress.discreteProgress(totalUnitCount: 10)
        let child2 = await CSProgress.discreteProgress(totalUnitCount: 10)
        await parent.addChild(child1, withPendingUnitCount: 1)
        await parent.addChild(child2, withPendingUnitCount: 1)

        // child1 is half done. This means the parent is half of 1/3 done.
        await child1.setCompletedUnitCount(5)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, (1.0 / 3.0) / 2.0, accuracy: 0.01)

        // child2 is half done. This means the parent is (half of 1/3 done) + (half of 1/3 done).
        await child2.setCompletedUnitCount(5)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, ((1.0 / 3.0) / 2.0) * 2.0, accuracy: 0.01)

        // add an implict child
        let child3 = await parent.pass(pendingUnitCount: 1).makeChild(totalUnitCount: 10)

        // Total completed of parent should not change
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, ((1.0 / 3.0) / 2.0) * 2.0, accuracy: 0.01)

        // child3 is half done. This means the parent is (half of 1/3 done) * 3.
        await child3.setCompletedUnitCount(5)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, ((1.0 / 3.0) / 2.0) * 3.0, accuracy: 0.01)

        // Finish child3
        await child3.setCompletedUnitCount(10)
        await XCTAssertTrueAsync(await child3.isFinished)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, (((1.0 / 3.0) / 2.0) * 2.0) + (1.0 / 3.0), accuracy: 0.01)

        // Finish child2
        await child2.setCompletedUnitCount(10);
        await XCTAssertTrueAsync(await child2.isFinished)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, ((1.0 / 3.0) / 2.0) + ((1.0 / 3.0) * 2.0), accuracy: 0.01)

        // Finish child1
        await child1.setCompletedUnitCount(10);
        await XCTAssertTrueAsync(await child1.isFinished)
        try await Task.sleep(nanoseconds: 1000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 1.0, accuracy: 0.01)
        await XCTAssertTrueAsync(await MainActor.run { parent.isFinished })
        await XCTAssertEqualAsync(
            await MainActor.run { parent.completedUnitCount },
            await MainActor.run { parent.totalUnitCount }
        )

    }

    func test_handlers() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 0)
        let child = await CSProgress.discreteProgress(totalUnitCount: 0)

        await parent.addChild(child, withPendingUnitCount: 1)

        var parentTriggered = false
        var childTriggered = false

        parent.cancellationHandler = { parentTriggered = true }
        await child.addCancellationNotification { childTriggered = true }

        parent.cancel()

        try await Task.sleep(nanoseconds: 3000000000)

        XCTAssertTrue(parentTriggered)
        XCTAssertTrue(childTriggered)
    }

    func test_alreadyCancelled() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 0)
        let child = await CSProgress.discreteProgress(totalUnitCount: 0)
        await parent.addChild(child, withPendingUnitCount: 1)

        parent.cancel()

        var parentTriggered = false
        var childTriggered = false

        parent.cancellationHandler = { parentTriggered = true }
        await child.addCancellationNotification { childTriggered = true }

        try await Task.sleep(nanoseconds: 3000000000)

        XCTAssertTrue(parentTriggered)
        XCTAssertTrue(childTriggered)
    }
}
