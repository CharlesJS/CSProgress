//
//  CSProgressPerformanceTests.swift
//
//  Created by Charles Srstka on 1/22/17.
//  Copyright © 2017-2022 Charles Srstka. All rights reserved.
//

import Foundation
import CSProgress

private let granularity = 0.01
private let numOfEach = 1000000

@available(macOS 10.11, *)
func TimeCSProgresses() {
    TimeNSProgresses()
    TimeNSProgressesWithAutoreleasePool()
    TimeNSProgressesWithObserver()
    TimeNSProgressesWithObserverAndAutoreleasePool()
    TimePureCSProgresses()
    TimePureCSProgressesWithObserver()
    TimeCSProgressesRootedWithObservingNSProgress()
}

private func timeIt(label: String, closure: () -> ()) {
    let startDate = Date()
    
    closure()
    
    let endDate = Date()
    
    print("\(label): Completed in \(endDate.timeIntervalSince(startDate)) seconds")
}

private class KVOWatcher: NSObject {
    private var progress: Foundation.Progress
    private var kvoContext = 0
    
    init(progress: Foundation.Progress) {
        self.progress = progress
        
        super.init()
        
        progress.addObserver(self, forKeyPath: "fractionCompleted", options: [], context: &self.kvoContext)
    }
    
    deinit {
        self.progress.removeObserver(self, forKeyPath: "fractionCompleted", context: &self.kvoContext)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if context == &self.kvoContext {
            // handle it somehow
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
}

@available(macOS 10.11, *)
private func TimeNSProgresses() {
    autoreleasepool {
        let masterProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(numOfEach) * 5)
        let subProgressA = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressB = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressC = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressD = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        
        timeIt(label: "NSProgress") {
            for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
                for _ in 0..<numOfEach {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
    }
}

@available(macOS 10.11, *)
private func TimeNSProgressesWithAutoreleasePool() {
    let masterProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(numOfEach) * 5)
    let subProgressA = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressB = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressC = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressD = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    
    timeIt(label: "NSProgress with autorelease pool") {
        for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
            for _ in 0..<numOfEach {
                autoreleasepool {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
    }
}

@available(macOS 10.11, *)
private func TimeNSProgressesWithObserver() {
    autoreleasepool {
        let masterProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(numOfEach) * 5)
        let subProgressA = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressB = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressC = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        let subProgressD = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
        
        let watcher = KVOWatcher(progress: masterProgress)
        
        timeIt(label: "NSProgress with observer") {
            for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
                for _ in 0..<numOfEach {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
        
        _ = watcher.self
    }
}

@available(macOS 10.11, *)
private func TimeNSProgressesWithObserverAndAutoreleasePool() {
    let masterProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(numOfEach) * 5)
    let subProgressA = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressB = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressC = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    let subProgressD = Foundation.Progress(totalUnitCount: Int64(numOfEach), parent: masterProgress, pendingUnitCount: Int64(numOfEach))
    
    let watcher = KVOWatcher(progress: masterProgress)
    
    timeIt(label: "NSProgress with observer and autorelease pool") {
        for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
            for _ in 0..<numOfEach {
                autoreleasepool {
                    eachProgress.completedUnitCount += 1
                }
            }
        }
    }
    
    _ = watcher.self
}

private func TimePureCSProgresses() {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    
    let masterProgress = CSProgress.discreteProgress(totalUnitCount: numOfEach * 5, granularity: granularity)
    let subProgressA = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressB = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressC = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressD = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    
    timeIt(label: "CSProgress") {
        for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
            for _ in 0..<numOfEach {
                eachProgress.incrementCompletedUnitCount(by: 1)
            }
        }
    }
    
    queue.cancelAllOperations()
    queue.waitUntilAllOperationsAreFinished()
}

private func TimePureCSProgressesWithObserver() {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    
    let masterProgress = CSProgress.discreteProgress(totalUnitCount: numOfEach * 5, granularity: granularity)
    let subProgressA = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressB = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressC = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressD = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    
    masterProgress.addFractionCompletedNotification(onQueue: queue) { _, _, _ in
        // handle it somehow
    }
    
    timeIt(label: "CSProgress with observer") {
        for eachProgress in [masterProgress, subProgressA, subProgressB, subProgressC, subProgressD] {
            for _ in 0..<numOfEach {
                eachProgress.incrementCompletedUnitCount(by: 1)
            }
        }
    }
    
    queue.cancelAllOperations()
    queue.waitUntilAllOperationsAreFinished()
}

@available(macOS 10.11, *)
private func TimeCSProgressesRootedWithObservingNSProgress() {
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    
    let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(numOfEach) * 5)
    
    let watcher = KVOWatcher(progress: masterNSProgress)
    
    let masterProgress = CSProgress.bridge(from: masterNSProgress, granularity: granularity, queue: queue)
    let subProgressA = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressB = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressC = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressD = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    let subProgressE = CSProgress(totalUnitCount: numOfEach, parent: masterProgress, pendingUnitCount: numOfEach, granularity: granularity)
    
    timeIt(label: "CSProgresses rooted with observing NSProgress") {
        for eachProgress in [subProgressA, subProgressB, subProgressC, subProgressD, subProgressE] {
            for _ in 0..<numOfEach {
                eachProgress.incrementCompletedUnitCount(by: 1)
            }
        }
    }
    
    queue.cancelAllOperations()
    queue.waitUntilAllOperationsAreFinished()
    
    _ = watcher.self
}
