//
//  CSProgressTest.swift
//
//  Tests for functionality unique to CSProgress, and functionality not covered by the Foundation progress tests
//  (functionality that follows similar behavior to Foundation.Progress is tested in ConvertedFoundationProgressTest.swift)
//
//  Created by Charles Srstka on 10/20/22.
//

import XCTest
import XCTAsyncAssertions
@testable import CSProgress

final class CSProgressTest: XCTestCase {
    private class MockProgressType: OpaqueProgressType, Equatable {
        static func == (lhs: MockProgressType, rhs: MockProgressType) -> Bool { false }
        private(set) var isCancelled: Bool = false
        func cancel() { self.isCancelled = true }
        var completedUnitCount: ProgressPortion.UnitCount {
            get { 0 }
            set {}
        }
        func addChild(_ child: CSProgress, withPendingUnitCount: some BinaryInteger) async {}
        func pass(pendingUnitCount: some BinaryInteger) -> ProgressPortion { fatalError("not implemented") }
        init() {}
    }

    // Unlike Foundation.Progress, we remove a progress object from the tree once it hits completion.
    // This helps performance, reducing the amount of time needed to calculate `fractionCompleted` for roots of large trees.
    // This also should reduce memory usage slightly, by causing progress objects for completed tasks to be deallocated.
    func testProgressCompletion() async {
        let parent = await CSProgress.discreteProgress(totalUnitCount: 1000)

        let child1 = await parent.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 10)
        let child2 = await parent.pass(pendingUnitCount: 500).makeChild(totalUnitCount: 10)
        let child3 = await parent.pass(pendingUnitCount: 400).makeChild(totalUnitCount: 100)

        await XCTAssertEqualAsync(await parent.backing.children.count, 3)

        // bump child1 to half complete, parent should still have 3 children
        await child1.incrementCompletedUnitCount(by: 5)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.05, accuracy: 0.01)
        await XCTAssertEqualAsync(await parent.backing.children.count, 3)

        // complete child1 and it should get removed from parent
        // childProgress1's completed unit count is 100% of its total of 10 (10)
        // childProgress1 is 10% of the overall unit count (100 / 1000)
        // the overall count done should be 100% of 10% of 1000, or 1.0 * 0.1 * 1000 = 100
        // the overall percentage done should be 100 / 1000 = 0.1
        await child1.incrementCompletedUnitCount(by: 5)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.1, accuracy: 0.01)
        await XCTAssertEqualAsync(await parent.backing.children.count, 2)

        // bump child2 to 20% complete, we should still have two children
        // parent fraction should now be 0.1 + (0.2 * 0.5) = 0.2
        await child2.incrementCompletedUnitCount(by: 2)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.2)
        await XCTAssertEqualAsync(await parent.backing.children.count, 2)

        // bump child3 to 75% complete, we should still have two children
        // parent fraction should now be 0.2 + (0.75 * 0.4) = 0.5
        await child3.setCompletedUnitCount(75)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.5)
        await XCTAssertEqualAsync(await parent.backing.children.count, 2)

        // finish child3, it should be detached and parent should only have one child
        // parent fraction should now be 0.5 + (0.25 * 0.4) = 0.6
        await child3.setCompletedUnitCount(100)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.6)
        await XCTAssertEqualAsync(await parent.backing.children.count, 1)

        // slightly bump child2; we should still have the one child.
        // parent fraction should now be 0.6 + (0.4 * 0.5) = 0.8
        await child2.incrementCompletedUnitCount(by: 4)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 0.8)
        await XCTAssertEqualAsync(await parent.backing.children.count, 1)

        // now finish child2 and parent should be childless at 100%.
        await child2.incrementCompletedUnitCount(by: 4)
        await XCTAssertEqualAsync(await parent.fractionCompleted, 1.0)
        await XCTAssertTrueAsync(await parent.isFinished)
        await XCTAssertEqualAsync(await parent.backing.children.count, 0)
    }

    func testIndeterminate() async {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)
        await XCTAssertFalseAsync(await progress.isIndeterminate)

        await progress.setTotalUnitCount(-1)
        await XCTAssertTrueAsync(await progress.isIndeterminate)

        await progress.setTotalUnitCount(10)
        await XCTAssertFalseAsync(await progress.isIndeterminate)

        await progress.setCompletedUnitCount(-1)
        await XCTAssertTrueAsync(await progress.isIndeterminate)

        await progress.setCompletedUnitCount(0)
        await XCTAssertFalseAsync(await progress.isIndeterminate)

        await progress.setTotalUnitCount(0)
        await XCTAssertTrueAsync(await progress.isIndeterminate)
    }

    func testCancellationNotifications() async throws {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

        var fired1 = false
        var fired2 = false

        let notification1 = await progress.addCancellationNotification {
            fired1 = true
        }

        _ = await progress.addCancellationNotification {
            fired2 = true
        }

        await XCTAssertFalseAsync(await progress.isCancelled)

        await progress.incrementCompletedUnitCount(by: 5)

        await XCTAssertFalseAsync(await progress.isCancelled)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertFalse(fired1)
        XCTAssertFalse(fired2)

        await progress.removeCancellationNotification(identifier: notification1)

        await progress.cancel()

        await XCTAssertTrueAsync(await progress.isCancelled)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertFalse(fired1)
        XCTAssertTrue(fired2)
    }

    func testChildrenCancellation() async throws {
        let parent = await CSProgress.discreteProgress(totalUnitCount: 10)
        let portion = parent.pass(pendingUnitCount: 5)
        let child1 = await portion.makeChild(totalUnitCount: 10)

        await child1.cancel()
        await XCTAssertTrueAsync(await child1.isCancelled)
        await XCTAssertFalseAsync(await portion.isCancelled)
        await XCTAssertFalseAsync(await parent.isCancelled)

        let child2 = await parent.pass(pendingUnitCount: 5).makeChild(totalUnitCount: 10)

        await portion.cancel()
        await XCTAssertTrueAsync(await parent.isCancelled)
        await XCTAssertTrueAsync(await portion.isCancelled)
        await XCTAssertTrueAsync(await child2.isCancelled)
    }

    func testProgressTypeCancellation() async {
        let mock = MockProgressType()
        XCTAssertFalse(mock.isCancelled)

        let opaque = ProgressPortion.ProgressType.opaque(mock)
        await opaque.cancel()
        await XCTAssertTrueAsync(await opaque.isCancelled)
        XCTAssertTrue(mock.isCancelled)
    }

    func testProgressTypeEquality() async {
        let progress1 = await CSProgress.discreteProgress(totalUnitCount: 10)
        let progress2 = await CSProgress.discreteProgress(totalUnitCount: 10)

        XCTAssertEqual(ProgressPortion.ProgressType.async(progress1), ProgressPortion.ProgressType.async(progress1))
        XCTAssertNotEqual(ProgressPortion.ProgressType.async(progress1), ProgressPortion.ProgressType.async(progress2))

        let mock1 = MockProgressType()
        let mock2 = MockProgressType()

        XCTAssertEqual(ProgressPortion.ProgressType.opaque(mock1), ProgressPortion.ProgressType.opaque(mock1))
        XCTAssertNotEqual(ProgressPortion.ProgressType.opaque(mock1), ProgressPortion.ProgressType.opaque(mock2))

        XCTAssertNotEqual(ProgressPortion.ProgressType.async(progress1), ProgressPortion.ProgressType.opaque(mock1))
        XCTAssertNotEqual(ProgressPortion.ProgressType.opaque(mock1), ProgressPortion.ProgressType.async(progress1))
    }

    func testDescriptions() async throws {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

        var noticedDescription = ""
        var noticedAdditionalDescription = ""

        let notification = progress.addDescriptionNotification { desc, additionalDesc in
            noticedDescription = desc
            noticedAdditionalDescription = additionalDesc
        }

        await progress.setLocalizedDescription("foo")
        await XCTAssertEqualAsync(await progress.localizedDescription, "foo")
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(noticedDescription, "foo")
        XCTAssertEqual(noticedAdditionalDescription, "")

        await progress.setLocalizedAdditionalDescription("bar")
        await XCTAssertEqualAsync(await progress.localizedAdditionalDescription, "bar")
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(noticedDescription, "foo")
        XCTAssertEqual(noticedAdditionalDescription, "bar")

        await progress.removeDescriptionNotification(identifier: notification)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(noticedDescription, "foo")
        XCTAssertEqual(noticedAdditionalDescription, "bar")

        await progress.setLocalizedDescription("baz")
        await XCTAssertEqualAsync(await progress.localizedDescription, "baz")

        await progress.setLocalizedAdditionalDescription("qux")
        await XCTAssertEqualAsync(await progress.localizedAdditionalDescription, "qux")
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(noticedDescription, "foo")
        XCTAssertEqual(noticedAdditionalDescription, "bar")
    }

    func testFractionCompleted() async throws {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 100)

        var notifiedUnitCount: ProgressPortion.UnitCount = 0
        var notifiedTotalCount: ProgressPortion.UnitCount = 0
        var notifiedFraction: Double = 0

        await XCTAssertEqualAsync(await progress.fractionCompleted, 0)

        await progress.incrementCompletedUnitCount(by: 12)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.12)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(notifiedUnitCount, 0)
        XCTAssertEqual(notifiedTotalCount, 0)
        XCTAssertEqual(notifiedFraction, 0, accuracy: 0.001)

        let notification = await progress.addFractionCompletedNotification { unitCount, totalCount, fraction in
            notifiedUnitCount = unitCount
            notifiedTotalCount = totalCount
            notifiedFraction = fraction
        }

        await progress.incrementCompletedUnitCount(by: 10)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.22)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(notifiedUnitCount, 22)
        XCTAssertEqual(notifiedTotalCount, 100)
        XCTAssertEqual(notifiedFraction, 0.22, accuracy: 0.001)

        await progress.setTotalUnitCount(50)
        await XCTAssertEqualAsync(await progress.totalUnitCount, 50)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.44, accuracy: 0.001)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(notifiedUnitCount, 22)
        XCTAssertEqual(notifiedTotalCount, 50)
        XCTAssertEqual(notifiedFraction, 0.44, accuracy: 0.001)

        await progress.removeFractionCompletedNotification(identifier: notification)

        await progress.incrementCompletedUnitCount(by: 10)
        await XCTAssertEqualAsync(await progress.completedUnitCount, 32)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.64)
        try await Task.sleep(nanoseconds: 1000)

        XCTAssertEqual(notifiedUnitCount, 22)
        XCTAssertEqual(notifiedTotalCount, 50)
        XCTAssertEqual(notifiedFraction, 0.44, accuracy: 0.001)
    }

    func testDebugDescription() async {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 100)
        let address = UInt(bitPattern: unsafeBitCast(progress, to: UnsafeRawPointer.self))
        let addressString = "0x\(String(address, radix: 16))"

        func expectedDesc(
            progress: String,
            parent: String,
            unit: Int,
            total: Int,
            fraction: Double,
            portionOfParent: Int? = nil
        ) -> String {
            var desc = "<CSProgress \(progress)> : "
            desc += "Parent: \(parent) / Fraction completed: \(fraction) / Completed: \(unit) of \(total) "

            if let portionOfParent {
                desc += "(\(portionOfParent) of parent) "
            }

            desc += "(async)"

            return desc
        }

        await XCTAssertEqualAsync(
            await progress.debugDescription,
            expectedDesc(progress: addressString, parent: "nil", unit: 0, total: 100, fraction: 0.0)
        )

        await progress.incrementCompletedUnitCount(by: 10)
        await progress.setTotalUnitCount(50)

        await XCTAssertEqualAsync(
            await progress.debugDescription,
            expectedDesc(progress: addressString, parent: "nil", unit: 10, total: 50, fraction: 0.2)
        )

        let child = await progress.pass(pendingUnitCount: 40).makeChild(totalUnitCount: 30)
        let childAddress = UInt(bitPattern: unsafeBitCast(child, to: UnsafeRawPointer.self))
        let childAddressString = "0x\(String(childAddress, radix: 16))"

        await child.incrementCompletedUnitCount(by: 15)

        let childDesc = expectedDesc(
            progress: childAddressString,
            parent: addressString,
            unit: 15,
            total: 30,
            fraction: 0.5,
            portionOfParent: 40
        )

        let parentDesc = expectedDesc(progress: addressString, parent: "nil", unit: 10, total: 50, fraction: 0.6)

        await XCTAssertEqualAsync(await child.debugDescription, childDesc)
        await XCTAssertEqualAsync(await progress.debugDescription, "\(parentDesc)\n\t\(childDesc)")
    }
}
