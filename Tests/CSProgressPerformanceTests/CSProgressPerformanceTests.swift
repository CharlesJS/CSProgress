//
//  CSProgressPerformanceTests.swift
//
//  Created by Charles Srstka on 1/22/17.
//  Copyright © 2017-2022 Charles Srstka. All rights reserved.
//

import Foundation
import CSProgress
import CSProgress_Foundation

private let granularity = 0.01
private let childCount = 4
private let unitCount = 1000000

private func timeIt(label: String, closure: () async -> ()) async {
    let startDate = Date()

    await closure()

    let endDate = Date()

    print("\(label): Completed in \(endDate.timeIntervalSince(startDate)) seconds")
}

func testNSProgresses() async {
    let mainProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(unitCount) * 5)
    let progresses = [mainProgress] + (0..<childCount).map { _ in
        Foundation.Progress(
            totalUnitCount: Int64(unitCount),
            parent: mainProgress,
            pendingUnitCount: Int64(childCount)
        )
    }

    await timeIt(label: "NSProgress") {
        for eachProgress in progresses {
            for _ in 0..<unitCount {
                eachProgress.completedUnitCount += 1
            }
        }
    }
}

func testNSProgressesWithAutoreleasePool() async {
    let mainProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(unitCount) * 5)
    let progresses = [mainProgress] + (0..<childCount).map { _ in
        Foundation.Progress(
            totalUnitCount: Int64(unitCount),
            parent: mainProgress,
            pendingUnitCount: Int64(childCount)
        )
    }

    await timeIt(label: "NSProgress with Autorelease Pool") {
        for eachProgress in progresses {
            for _ in 0..<unitCount {
                autoreleasepool {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
    }
}

func testNSProgressesWithObserver() async {
    let mainProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(unitCount) * 5)
    let progresses = [mainProgress] + (0..<childCount).map { _ in
        Foundation.Progress(totalUnitCount: Int64(unitCount), parent: mainProgress, pendingUnitCount: Int64(unitCount))
    }

    let watcher = mainProgress.observe(\.fractionCompleted) { _, _ in
        // handle it somehow
    }

    await timeIt(label: "NSProgress with observer") {
        for eachProgress in progresses {
            for _ in 0..<unitCount {
                eachProgress.completedUnitCount += 1
            }
        }
    }

    _ = watcher.self
}

func testNSProgressesWithObserverAndAutoreleasePool() async {
    let mainProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(unitCount) * 5)
    let progresses = [mainProgress] + (0..<childCount).map { _ in
        Foundation.Progress(totalUnitCount: Int64(unitCount), parent: mainProgress, pendingUnitCount: Int64(unitCount))
    }

    let watcher = mainProgress.observe(\.fractionCompleted) { _, _ in
        // handle it somehow
    }

    await timeIt(label: "NSProgress with observer and autorelease pool") {
        for eachProgress in progresses {
            for _ in 0..<unitCount {
                autoreleasepool {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
    }

    _ = watcher.self
}


private func makeCSProgresses() async -> [CSProgress] {
    let mainProgress = await CSProgress.discreteProgress(totalUnitCount: unitCount * 5, granularity: granularity)
    var progresses = [mainProgress]
    await mainProgress.setCompletedUnitCount(0)

    for _ in (0..<childCount) {
        progresses.append(
            await CSProgress(
                totalUnitCount: unitCount,
                parent: mainProgress,
                pendingUnitCount: unitCount,
                granularity: granularity
            )
        )
    }

    return progresses
}

func testCSProgresses() async {
    let progresses = await makeCSProgresses()

    await timeIt(label: "CSProgress") {
        for eachProgress in progresses {
            for _ in 0..<unitCount {
                await eachProgress.incrementCompletedUnitCount(by: 1)
            }
        }
    }
}

func testCSProgressesWithObserver() async {
    let progresses = await makeCSProgresses()
    let mainProgress = progresses[0]

    await timeIt(label: "CSProgress with observer") {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withUnsafeContinuation { continuation in
                    Task {
                        var notification: CSProgress.NotificationID? = nil

                        notification = await mainProgress.addFractionCompletedNotification { completed, _, _ in
                            if completed == unitCount * (childCount + 1) {
                                await mainProgress.removeFractionCompletedNotification(identifier: notification!)

                                continuation.resume()
                            }
                        }
                    }
                }
            }

            group.addTask {
                for eachProgress in progresses {
                    for _ in 0..<unitCount {
                        await eachProgress.incrementCompletedUnitCount(by: 1)
                    }
                }
            }
        }
    }
}

func testCSProgressesRootedWithObservingNSProgress() async {
    let mainProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(unitCount) * 5)

    var _progresses: [CSProgress] = []

    for _ in (0..<(childCount + 1)) {
        _progresses.append(
            await CSProgress(
                totalUnitCount: unitCount,
                parent: mainProgress,
                pendingUnitCount: unitCount,
                granularity: granularity
            )
        )
    }

    let progresses = _progresses

    await timeIt(label: "CSProgresses rooted with observing NSProgress") {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withUnsafeContinuation { continuation in
                    actor Storage {
                        private(set) var watcher: NSObjectProtocol? = nil
                        func setWatcher(_ watcher: NSObjectProtocol?) { self.watcher = watcher }
                    }

                    let storage = Storage()

                    Task {
                        // keep watcher in storage to keep it from being reaped early
                        await storage.setWatcher(mainProgress.observe(\.fractionCompleted) { progress, _ in
                            if progress.isFinished {
                                Task {
                                    await storage.setWatcher(nil)
                                }

                                continuation.resume()
                            }
                        })
                    }
                }
            }

            group.addTask {
                for eachProgress in progresses {
                    for _ in 0..<unitCount {
                        await eachProgress.incrementCompletedUnitCount(by: 1)
                    }
                }
            }
        }
    }
}

func testCSProgressesUsedSynchronously() async {
    let progresses = await makeCSProgresses()
    let mainProgress = progresses[0]

    await timeIt(label: "CSProgress with observer, used from synchronous code") {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withUnsafeContinuation { continuation in
                    Task {
                        var notification: CSProgress.NotificationID? = nil

                        notification = await mainProgress.addFractionCompletedNotification { completed, _, _ in
                            if completed == unitCount * (childCount + 1) {
                                await mainProgress.removeFractionCompletedNotification(identifier: notification!)

                                continuation.resume()
                            }
                        }
                    }
                }
            }

            group.addTask {
                {
                    for eachProgress in progresses {
                        for _ in 0..<unitCount {
                            Task {
                                await eachProgress.incrementCompletedUnitCount(by: 1)
                            }
                        }
                    }
                }()
            }
        }
    }
}

