//
//  WrappingTests.swift
//
//
//  Created by Charles Srstka on 10/24/22.
//

import Foundation
import XCTest
import XCTAsyncAssertions
@testable import CSProgress
@testable import CSProgress_Foundation

final class WrappingTest: XCTestCase {
    func testMakeWrappingFoundationProgress() async throws {
        let ns = Foundation.Progress.discreteProgress(totalUnitCount: 10)
        ns.completedUnitCount = 2
        ns.localizedDescription = "foo"
        ns.localizedAdditionalDescription = "bar"

        let progress = await CSProgress(wrapping: ns)

        await XCTAssertEqualAsync(await progress.completedUnitCount, 2)
        await XCTAssertEqualAsync(await progress.totalUnitCount, 10)
        await XCTAssertEqualAsync(await progress.fractionCompleted, 0.2)
        await XCTAssertEqualAsync(await progress.localizedDescription, "foo")
        await XCTAssertEqualAsync(await progress.localizedAdditionalDescription, "bar")

        await progress.incrementCompletedUnitCount(by: 3)
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { ns.fractionCompleted }, 0.5, accuracy: 0.001)

        await progress.setTotalUnitCount(20)
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { ns.fractionCompleted }, 0.25, accuracy: 0.001)

        await progress.setLocalizedDescription("baz")
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { ns.localizedDescription }, "baz")

        await progress.setLocalizedAdditionalDescription("qux")
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { ns.localizedAdditionalDescription }, "qux")

        await progress.cancel()
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertTrueAsync(await MainActor.run { ns.isCancelled })
    }

    func testKVONotificationsOccurOnMainThread() async throws {
        actor Storage {
            private(set) var accessCount = 0
            func bumpAccessCount() { self.accessCount += 1 }
        }

        let ns = Foundation.Progress.discreteProgress(totalUnitCount: 100)
        let progress = await CSProgress(wrapping: ns)

        let storage = Storage()

        let fractionWatcher = ns.observe(\.fractionCompleted) { p, _ in
            Task { await storage.bumpAccessCount() }
            XCTAssertTrue(Thread.isMainThread)
        }

        let cancelWatcher = ns.observe(\.isCancelled) { _, _ in
            Task { await storage.bumpAccessCount() }
            XCTAssertTrue(Thread.isMainThread)
        }

        await progress.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 1)

        await progress.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 2)

        let descriptionWatcher = ns.observe(\.localizedDescription) { _, _ in
            Task { await storage.bumpAccessCount() }
            XCTAssertTrue(Thread.isMainThread)
        }

        await progress.setLocalizedDescription("foo")
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 3)

        let additionalDescriptionWatcher = ns.observe(\.localizedAdditionalDescription) { _, _ in
            Task { await storage.bumpAccessCount() }
            XCTAssertTrue(Thread.isMainThread)
        }

        await progress.setLocalizedAdditionalDescription("bar")
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 4)

        await progress.cancel()
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 5)

        // prevent ARC from reaping the watchers early
        _ = fractionWatcher.self
        _ = descriptionWatcher.self
        _ = additionalDescriptionWatcher.self
        _ = cancelWatcher.self
    }

    func testWrappingCancelledProgress() async throws {
        let ns = Foundation.Progress.discreteProgress(totalUnitCount: 10)
        ns.cancel()

        let progress = await CSProgress(wrapping: ns)

        await XCTAssertTrueAsync(await progress.isCancelled)
    }

    func testMakeWithFoundationProgressParent() async throws {
        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 10)

        let child1 = await CSProgress(totalUnitCount: 5, parent: parent, pendingUnitCount: 3)
        let child2 = await parent.pass(pendingUnitCount: 7).makeChild(totalUnitCount: 6)

        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.0, accuracy: 0.001)

        await child1.incrementCompletedUnitCount(by: 4)
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.24, accuracy: 0.001)

        await child2.incrementCompletedUnitCount(by: 6)
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 0.94, accuracy: 0.001)

        await child1.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000000)
        await XCTAssertEqualAsync(await MainActor.run { parent.fractionCompleted }, 1.0, accuracy: 0.001)
        await XCTAssertTrueAsync(await MainActor.run { parent.isFinished })
    }

    func testKVONotificationsForParentOccurOnMainThread() async throws {
        actor Storage {
            private(set) var accessCount = 0
            func bumpAccessCount() { self.accessCount += 1 }
        }

        let parent = Foundation.Progress.discreteProgress(totalUnitCount: 100)
        let child = await parent.pass(pendingUnitCount: 100).makeChild(totalUnitCount: 100)

        let storage = Storage()

        let watcher = parent.observe(\.fractionCompleted) { p, _ in
            Task { await storage.bumpAccessCount() }
            XCTAssertTrue(Thread.isMainThread)
        }

        await child.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 1)

        await child.incrementCompletedUnitCount(by: 1)
        try await Task.sleep(nanoseconds: 1000000)
        await MainActor.run {}
        await XCTAssertEqualAsync(await storage.accessCount, 2)

        _ = watcher.self // prevent ARC from reaping the watcher early
    }
}
