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

    func testGranularity() async throws {
        actor Storage {
            private(set) var counts: [ProgressPortion.UnitCount] = []
            private(set) var finished = false

            func addCount(_ count: ProgressPortion.UnitCount) {
                self.counts.append(count)
            }

            func finish() {
                self.finished = true
            }

            var averageCountDifference: Double {
                var differences: [Double] = []

                for i in 0..<(self.counts.count - 1) {
                    differences.append(Double(self.counts[i + 1]) - Double(self.counts[i]))
                }

                return differences.reduce(0) { $0 + $1 } / Double(differences.count)
            }

            nonisolated func waitUntilFinished() async {
                while await !self.finished {
                    _ = try? await Task.sleep(nanoseconds: 1000)
                }
            }
        }

        let storage1 = Storage()
        let storage2 = Storage()
        let storage3 = Storage()

        let progress1 = await CSProgress.discreteProgress(totalUnitCount: 1000, granularity: 0.005)
        let progress2 = await CSProgress.discreteProgress(totalUnitCount: 1000, granularity: 0.01)
        let progress3 = await CSProgress.discreteProgress(totalUnitCount: 1000, granularity: 0.02)

        _ = await progress1.addFractionCompletedNotification { completed, total, _ in
            await storage1.addCount(completed)

            if completed == total {
                await storage1.finish()
            }
        }

        _ = await progress2.addFractionCompletedNotification { completed, total, _ in
            await storage2.addCount(completed)

            if completed == total {
                await storage2.finish()
            }
        }

        _ = await progress3.addFractionCompletedNotification { completed, total, _ in
            await storage3.addCount(completed)

            if completed == total {
                await storage3.finish()
            }
        }

        for _ in 0..<1000 {
            await progress1.incrementCompletedUnitCount(by: 1)
            await progress2.incrementCompletedUnitCount(by: 1)
            await progress3.incrementCompletedUnitCount(by: 1)
        }

        await storage1.waitUntilFinished()
        await XCTAssertEqualAsync(await storage1.averageCountDifference, 5.0, accuracy: 0.5)

        await storage2.waitUntilFinished()
        await XCTAssertEqualAsync(await storage2.averageCountDifference, 10.0, accuracy: 0.5)

        await storage3.waitUntilFinished()
        await XCTAssertEqualAsync(await storage3.averageCountDifference, 20.0, accuracy: 0.5)
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

    func testMarkComplete() async {
        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

        await progress.pass(pendingUnitCount: 2).markComplete()
        await XCTAssertEqualAsync(await progress.completedUnitCount, 2)
        await XCTAssertFalseAsync(await progress.isFinished)

        await progress.pass(pendingUnitCount: 5).markComplete()
        await XCTAssertEqualAsync(await progress.completedUnitCount, 7)
        await XCTAssertFalseAsync(await progress.isFinished)

        await progress.pass(pendingUnitCount: 3).markComplete()
        await XCTAssertEqualAsync(await progress.completedUnitCount, 10)
        await XCTAssertTrueAsync(await progress.isFinished)

        let ns = Foundation.Progress.discreteProgress(totalUnitCount: 10)

        await ns.pass(pendingUnitCount: 6).markComplete()
        XCTAssertEqual(ns.completedUnitCount, 6)

    }

    func testPortionOfDeadProgress() async {
        let portion: ProgressPortion = await {
            let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

            return progress.pass(pendingUnitCount: 10)
        }()

        XCTAssertNil(portion.progress)

        // Should never show as cancelled
        await XCTAssertFalseAsync(await portion.isCancelled)

        // Should still make children, but they should have no parent
        let child = await portion.makeChild(totalUnitCount: 10)

        // Should be a no-op, but not crash
        await portion.markComplete()

        await XCTAssertNilAsync(await child.parent)
    }

    func testCancellationNotifications() async throws {
        actor Storage {
            private(set) var updated: Date

            func update() { self.updated = Date() }
            init(date: Date) { self.updated = date }
        }

        let startDate = Date()
        let storage1 = Storage(date: startDate)
        let storage2 = Storage(date: startDate)
        let storage3 = Storage(date: startDate)

        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

        let notification1 = await progress.addCancellationNotification {
            await storage1.update()
        }

        _ = await progress.addCancellationNotification(priority: .low) {
            XCTAssertEqual(Task.currentPriority, .low)
            await storage2.update()
        }

        _ = await progress.addCancellationNotification(priority: .high) {
            XCTAssertEqual(Task.currentPriority, .high)
            await storage3.update()
        }

        await XCTAssertFalseAsync(await progress.isCancelled)

        await progress.incrementCompletedUnitCount(by: 5)

        await XCTAssertFalseAsync(await progress.isCancelled)
        _ = try? await Task.sleep(nanoseconds: 1000000)

        await XCTAssertEqualAsync(await storage1.updated, startDate)
        await XCTAssertEqualAsync(await storage2.updated, startDate)
        await XCTAssertEqualAsync(await storage3.updated, startDate)

        await progress.removeCancellationNotification(identifier: notification1)

        await progress.cancel()

        await XCTAssertTrueAsync(await progress.isCancelled)

        for _ in 0..<1000000 {
            let updated2 = await storage2.updated
            let updated3 = await storage3.updated

            if updated2 > startDate && updated3 > startDate { break }

            _ = try? await Task.sleep(nanoseconds: 1000)
        }

        await XCTAssertEqualAsync(await storage1.updated, startDate)
        await XCTAssertGreaterThanAsync(await storage2.updated, startDate)
        await XCTAssertGreaterThanAsync(await storage3.updated, startDate)
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
        actor Storage {
            private(set) var description = ""
            private(set) var additionalDescription = ""
            private(set) var updated: Date

            func update(description: String, additionalDescription: String) {
                self.description = description
                self.additionalDescription = additionalDescription
                self.updated = Date()
            }

            init(date: Date) {
                self.updated = date
            }
        }

        var lastChecked = Date()
        let storage1 = Storage(date: lastChecked)
        let storage2 = Storage(date: lastChecked)

        let waitForUpdates = { (storages: [Storage]) async -> Void in
            for _ in 0..<1000000 {
                var dates: [Date] = []
                for eachStorage in storages {
                    dates.append(await eachStorage.updated)
                }

                if let minDate = dates.min(), minDate > lastChecked {
                    lastChecked = dates.max() ?? minDate
                    break
                }

                _ = try? await Task.sleep(nanoseconds: 1000)
            }
        }

        let progress = await CSProgress.discreteProgress(totalUnitCount: 10)

        let notification1 = progress.addDescriptionNotification(priority: .high) { description, additionalDescription in
            XCTAssertEqual(Task.currentPriority, .high)
            await storage1.update(description: description, additionalDescription: additionalDescription)
        }

        _ = progress.addDescriptionNotification(priority: .low) { description, additionalDescription in
            XCTAssertEqual(Task.currentPriority, .low)
            await storage2.update(description: description, additionalDescription: additionalDescription)
        }

        await progress.setLocalizedDescription("foo")
        await XCTAssertEqualAsync(await progress.localizedDescription, "foo")
        await waitForUpdates([storage1, storage2])

        await XCTAssertEqualAsync(await storage1.description, "foo")
        await XCTAssertEqualAsync(await storage2.description, "foo")
        await XCTAssertEqualAsync(await storage1.additionalDescription, "")
        await XCTAssertEqualAsync(await storage2.additionalDescription, "")

        await progress.setLocalizedAdditionalDescription("bar")
        await XCTAssertEqualAsync(await progress.localizedAdditionalDescription, "bar")
        await waitForUpdates([storage1, storage2])

        await XCTAssertEqualAsync(await storage1.description, "foo")
        await XCTAssertEqualAsync(await storage2.description, "foo")
        await XCTAssertEqualAsync(await storage1.additionalDescription, "bar")
        await XCTAssertEqualAsync(await storage2.additionalDescription, "bar")

        await progress.removeDescriptionNotification(identifier: notification1)
        _ = try? await Task.sleep(nanoseconds: 1000000)

        await XCTAssertEqualAsync(await storage1.description, "foo")
        await XCTAssertEqualAsync(await storage2.description, "foo")
        await XCTAssertEqualAsync(await storage1.additionalDescription, "bar")
        await XCTAssertEqualAsync(await storage2.additionalDescription, "bar")

        await progress.setLocalizedDescription("baz")
        await XCTAssertEqualAsync(await progress.localizedDescription, "baz")

        await progress.setLocalizedAdditionalDescription("qux")
        await XCTAssertEqualAsync(await progress.localizedAdditionalDescription, "qux")
        _ = try? await Task.sleep(nanoseconds: 1000000)
        await waitForUpdates([storage2])

        await XCTAssertEqualAsync(await storage1.description, "foo")
        await XCTAssertEqualAsync(await storage2.description, "baz")
        await XCTAssertEqualAsync(await storage1.additionalDescription, "bar")
        await XCTAssertEqualAsync(await storage2.additionalDescription, "qux")
    }

    func testFractionCompleted() async throws {
        actor Storage {
            private(set) var unitCount: ProgressPortion.UnitCount = 0
            private(set) var totalCount: ProgressPortion.UnitCount = 0
            private(set) var fraction: Double = 0
            private(set) var updated: Date

            func update(unitCount: ProgressPortion.UnitCount, totalCount: ProgressPortion.UnitCount, fraction: Double) {
                self.unitCount = unitCount
                self.totalCount = totalCount
                self.fraction = fraction
                self.updated = Date()
            }

            init(date: Date) {
                self.updated = date
            }
        }

        var lastChecked = Date()
        let storage1 = Storage(date: lastChecked)
        let storage2 = Storage(date: lastChecked)

        let waitForUpdates = { (storages: [Storage]) async -> Void in
            for _ in 0..<1000000 {
                var dates: [Date] = []
                for eachStorage in storages {
                    dates.append(await eachStorage.updated)
                }

                if let minDate = dates.min(), minDate > lastChecked {
                    lastChecked = dates.max() ?? minDate
                    break
                }

                _ = try? await Task.sleep(nanoseconds: 1000)
            }
        }

        let progress = await CSProgress.discreteProgress(totalUnitCount: 100)

        await XCTAssertEqualAsync(await progress.fractionCompleted, 0)

        await progress.incrementCompletedUnitCount(by: 12)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.12)

        _ = try? await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await storage1.unitCount, 0)
        await XCTAssertEqualAsync(await storage2.unitCount, 0)
        await XCTAssertEqualAsync(await storage1.totalCount, 0)
        await XCTAssertEqualAsync(await storage2.totalCount, 0)
        await XCTAssertEqualAsync(await storage1.fraction, 0, accuracy: 0.001)
        await XCTAssertEqualAsync(await storage2.fraction, 0, accuracy: 0.001)

        let notification1 = await progress.addFractionCompletedNotification(priority: .high) {
            XCTAssertEqual(Task.currentPriority, .high)
            await storage1.update(unitCount: $0, totalCount: $1, fraction: $2)
        }

        _ = await progress.addFractionCompletedNotification(priority: .low) {
            XCTAssertEqual(Task.currentPriority, .low)
            await storage2.update(unitCount: $0, totalCount: $1, fraction: $2)
        }

        await progress.incrementCompletedUnitCount(by: 10)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.22)

        await waitForUpdates([storage1, storage2])
        await XCTAssertEqualAsync(await storage1.unitCount, 22)
        await XCTAssertEqualAsync(await storage2.unitCount, 22)
        await XCTAssertEqualAsync(await storage1.totalCount, 100)
        await XCTAssertEqualAsync(await storage2.totalCount, 100)
        await XCTAssertEqualAsync(await storage1.fraction, 0.22, accuracy: 0.001)
        await XCTAssertEqualAsync(await storage2.fraction, 0.22, accuracy: 0.001)

        await progress.setTotalUnitCount(50)
        await XCTAssertEqualAsync(await progress.totalUnitCount, 50)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.44, accuracy: 0.001)

        await waitForUpdates([storage1, storage2])
        await XCTAssertEqualAsync(await storage1.unitCount, 22)
        await XCTAssertEqualAsync(await storage2.unitCount, 22)
        await XCTAssertEqualAsync(await storage1.totalCount, 50)
        await XCTAssertEqualAsync(await storage2.totalCount, 50)
        await XCTAssertEqualAsync(await storage1.fraction, 0.44, accuracy: 0.001)
        await XCTAssertEqualAsync(await storage2.fraction, 0.44, accuracy: 0.001)

        await progress.removeFractionCompletedNotification(identifier: notification1)

        await progress.incrementCompletedUnitCount(by: 10)
        await XCTAssertEqualAsync(await progress.completedUnitCount, 32)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.64)
        _ = try? await Task.sleep(nanoseconds: 1000000)

        await waitForUpdates([storage2])
        await XCTAssertEqualAsync(await storage1.unitCount, 22)
        await XCTAssertEqualAsync(await storage2.unitCount, 32)
        await XCTAssertEqualAsync(await storage1.totalCount, 50)
        await XCTAssertEqualAsync(await storage2.totalCount, 50)
        await XCTAssertEqualAsync(await storage1.fraction, 0.44, accuracy: 0.001)
        await XCTAssertEqualAsync(await storage2.fraction, 0.64, accuracy: 0.001)
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
