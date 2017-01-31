//
//  CSProgressTests.swift
//  CSProgress
//
//  Created by Charles Srstka on 1/13/17.
//  Copyright © 2017 Charles Srstka. All rights reserved.
//

import XCTest
@testable import CSProgress

class CSProgressTests: XCTestCase {
    private struct ProgressPair {
        let progress: CSProgress
        let nsProgress: Foundation.Progress
        let nonPendingUnitCount: CSProgress.UnitCount
    }
    
    private struct NSProgressPair {
        let bridged: Foundation.Progress
        let nonBridged: Foundation.Progress
        let nonPendingUnitCount: Int64
    }
    
    private static let granularity = 0.01
    private static let tolerance: Double = 0.0001
    
    private let numOfEach = 10000
    
    private func testCSProgresses(progressPair: ProgressPair, changes: [() -> ()], queue maybeQueue: OperationQueue? = nil) {
        let queue = maybeQueue ?? OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let expectation = self.expectation(description: "All Done")
        
        DispatchQueue.global().async {
            var lastFraction = 0.0
            
            for eachChange in changes {
                let id = progressPair.progress.addFractionCompletedNotification(onQueue: queue) { _, _, fraction in
                    lastFraction = fraction
                    
                    XCTAssert(abs(fraction - progressPair.progress.fractionCompleted) <= CSProgressTests.tolerance)
                }
                
                eachChange()
                
                queue.waitUntilAllOperationsAreFinished()
                
                progressPair.progress.removeFractionCompletedNotification(identifier: id)
            }
            
            XCTAssert(abs(lastFraction - 1.0) <= CSProgressTests.tolerance)
            
            OperationQueue.main.addOperation { expectation.fulfill() }
        }
        
        self.waitForExpectations(timeout: 3600.0) {
            if let error = $0 {
                print("Error: \(error)")
            }
        }
    }
    
    private func testCSProgresses(masterProgress: ProgressPair, childProgresses: [ProgressPair], queue: OperationQueue? = nil) {
        let changes = ([masterProgress] + childProgresses).flatMap { eachProgressPair in
            return (0..<self.numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(eachProgressPair.nonPendingUnitCount))
                    
                    eachProgressPair.nsProgress.completedUnitCount = Int64(portion)
                    eachProgressPair.progress.completedUnitCount = CSProgress.UnitCount(portion)
                }
            }
        }.shuffled() + (childProgresses + [masterProgress]).map { eachProgressPair in
            return {
                eachProgressPair.nsProgress.completedUnitCount = eachProgressPair.nsProgress.totalUnitCount
                eachProgressPair.progress.completedUnitCount = eachProgressPair.progress.totalUnitCount
            }
        }
        
        self.testCSProgresses(progressPair: masterProgress, changes: changes, queue: queue)
    }
    
    private func testNSProgresses(masterProgress: NSProgressPair, childProgresses: [NSProgressPair], queue: OperationQueue? = nil) {
        let changes = ([masterProgress] + childProgresses).flatMap { eachProgressPair in
            return (0..<self.numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(eachProgressPair.nonPendingUnitCount))
                    
                    eachProgressPair.nonBridged.completedUnitCount = Int64(portion)
                    eachProgressPair.bridged.completedUnitCount = Int64(portion)
                }
            }
        }.shuffled()
        
        let expectation = self.expectation(description: "Finished")
        
        DispatchQueue.global().async {
            for eachChange in changes {
                eachChange()
                
                queue?.waitUntilAllOperationsAreFinished()
                
                XCTAssert(abs(masterProgress.bridged.fractionCompleted - masterProgress.nonBridged.fractionCompleted) <= CSProgressTests.tolerance)
            }
            
            expectation.fulfill()
        }
        
        self.waitForExpectations(timeout: 3600.0) {
            if let error = $0 {
                print("Error: \(error)")
            }
        }
    }
    
    private func testCSProgressWithNSProgressChildren(masterProgress: ProgressPair, childProgresses: [NSProgressPair], queue: OperationQueue? = nil) {
        let changes = (0..<self.numOfEach).map { _ in
            return {
                let portion = arc4random_uniform(UInt32(masterProgress.nonPendingUnitCount))
                
                masterProgress.nsProgress.completedUnitCount = Int64(portion)
                masterProgress.progress.completedUnitCount = CSProgress.UnitCount(portion)
            }
        }
        
        let lastChange = {
            masterProgress.nsProgress.completedUnitCount = masterProgress.nsProgress.totalUnitCount
            masterProgress.progress.completedUnitCount = masterProgress.progress.totalUnitCount
        }
        
        let childChanges = childProgresses.flatMap { eachProgressPair in
            return (0..<self.numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(eachProgressPair.nonPendingUnitCount))
                    
                    eachProgressPair.nonBridged.completedUnitCount = Int64(portion)
                    eachProgressPair.bridged.completedUnitCount = Int64(portion)
                }
            }
        }
        
        let childLastChanges = childProgresses.map { eachProgressPair in
            return {
                eachProgressPair.nonBridged.completedUnitCount = eachProgressPair.nonBridged.totalUnitCount
                eachProgressPair.bridged.completedUnitCount = eachProgressPair.bridged.totalUnitCount
            }
        }
        
        self.testCSProgresses(progressPair: masterProgress, changes: (changes + childChanges).shuffled() + childLastChanges + [lastChange], queue: queue)
    }
    
    private func testNSProgressWithCSProgressChildren(masterProgress: NSProgressPair, childProgresses: [ProgressPair], queue: OperationQueue) {
        class KVOWatcher: NSObject {
            private var kvoContext = 0
            private let progressPair: NSProgressPair
            
            init(progressPair: NSProgressPair) {
                self.progressPair = progressPair
                
                super.init()
                
                progressPair.bridged.addObserver(self, forKeyPath: "fractionCompleted", options: [], context: &self.kvoContext)
            }
            
            deinit {
                progressPair.bridged.removeObserver(self, forKeyPath: "fractionCompleted", context: &self.kvoContext)
            }
            
            var count = 0
            
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
                if context == &self.kvoContext {
                    XCTAssert(abs(self.progressPair.bridged.fractionCompleted - self.progressPair.nonBridged.fractionCompleted) <= CSProgressTests.granularity)
                } else {
                    super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                }
            }
        }
        
        let kvoWatcher = KVOWatcher(progressPair: masterProgress)
        
        let changes = childProgresses.flatMap { eachProgressPair in
            return (0..<self.numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(eachProgressPair.nonPendingUnitCount))
                    
                    eachProgressPair.nsProgress.completedUnitCount = Int64(portion)
                    eachProgressPair.progress.completedUnitCount = CSProgress.UnitCount(portion)
                }
            }
        }.shuffled()
        
        let expectation = self.expectation(description: "Finished")
        
        DispatchQueue.global().async {
            for eachChange in changes {
                eachChange()
                
                queue.waitUntilAllOperationsAreFinished()
                
                XCTAssert(abs(masterProgress.bridged.fractionCompleted - masterProgress.nonBridged.fractionCompleted) <= CSProgressTests.granularity)
            }
            
            expectation.fulfill()
        }
        
        self.waitForExpectations(timeout: 3600.0) {
            if let error = $0 {
                print("Error: \(error)")
            }
        }
        
        _ = kvoWatcher.self
    }
    
    func testCSProgress() {
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity)
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let masterProgressPair = ProgressPair(progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        let childProgressPairs = [
            ProgressPair(progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            ProgressPair(progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            ProgressPair(progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            ProgressPair(progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testCSProgresses(masterProgress: masterProgressPair, childProgresses: childProgressPairs)
    }
    
    func testCSProgressesBackedByNSProgresses() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = Int64(arc4random())
        let subACount = Int64(arc4random())
        let subBCount = Int64(arc4random())
        let subCCount = Int64(arc4random())
        let subDCount = Int64(arc4random())
        
        let subAPortion = Int64(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = Int64(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = Int64(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = Int64(arc4random_uniform(UInt32(masterCount / 4)))
     
        let masterProgress = CSProgress.bridge(from: Foundation.Progress.discreteProgress(totalUnitCount: masterCount), granularity: granularity, queue: queue)
        
        let subProgressA = CSProgress.bridge(from: Foundation.Progress.discreteProgress(totalUnitCount: subACount), granularity: granularity, queue: queue)
        masterProgress.addChild(subProgressA, withPendingUnitCount: subAPortion)
        
        let subProgressB = CSProgress.bridge(from: Foundation.Progress.discreteProgress(totalUnitCount: subBCount), granularity: granularity, queue: queue)
        masterProgress.addChild(subProgressB, withPendingUnitCount: subBPortion)
        
        let subProgressC = CSProgress.bridge(from: Foundation.Progress.discreteProgress(totalUnitCount: subCCount), granularity: granularity, queue: queue)
        masterProgress.addChild(subProgressC, withPendingUnitCount: subCPortion)
        
        let subProgressD = CSProgress.bridge(from: Foundation.Progress .discreteProgress(totalUnitCount: subDCount), granularity: granularity, queue: queue)
        masterProgress.addChild(subProgressD, withPendingUnitCount: subDPortion)
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: masterCount)
        let subNSProgressA = Foundation.Progress(totalUnitCount: subACount, parent: masterNSProgress, pendingUnitCount: subAPortion)
        let subNSProgressB = Foundation.Progress(totalUnitCount: subBCount, parent: masterNSProgress, pendingUnitCount: subBPortion)
        let subNSProgressC = Foundation.Progress(totalUnitCount: subCCount, parent: masterNSProgress, pendingUnitCount: subCPortion)
        let subNSProgressD = Foundation.Progress(totalUnitCount: subDCount, parent: masterNSProgress, pendingUnitCount: subDPortion)
        
        let masterProgressPair = ProgressPair(progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        let childProgressPairs = [
            ProgressPair(progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            ProgressPair(progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            ProgressPair(progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            ProgressPair(progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testCSProgresses(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
    
    func testNSProgressesBackedByCSProgresses() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity)
        
        let masterBridgedProgress = masterProgress.bridgeToNSProgress(queue: queue)
        let subBridgedProgressA = subProgressA.bridgeToNSProgress(queue: queue)
        let subBridgedProgressB = subProgressB.bridgeToNSProgress(queue: queue)
        let subBridgedProgressC = subProgressC.bridgeToNSProgress(queue: queue)
        let subBridgedProgressD = subProgressD.bridgeToNSProgress(queue: queue)
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        
        let masterProgressPair = NSProgressPair(bridged: masterBridgedProgress, nonBridged: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        
        let childProgressPairs = [
            NSProgressPair(bridged: subBridgedProgressA, nonBridged: subNSProgressA, nonPendingUnitCount: subACount),
            NSProgressPair(bridged: subBridgedProgressB, nonBridged: subNSProgressB, nonPendingUnitCount: subBCount),
            NSProgressPair(bridged: subBridgedProgressC, nonBridged: subNSProgressC, nonPendingUnitCount: subCCount),
            NSProgressPair(bridged: subBridgedProgressD, nonBridged: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testNSProgresses(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
    
    func testCSProgressesRootedByNSProgress() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let wrappedProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let masterProgress = CSProgress.bridge(from: wrappedProgress, granularity: granularity, queue: queue)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity)
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let masterProgressPair = NSProgressPair(bridged: wrappedProgress, nonBridged: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        
        let childProgressPairs = [
            ProgressPair(progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: CSProgress.UnitCount(masterProgressPair.nonPendingUnitCount)),
            ProgressPair(progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            ProgressPair(progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            ProgressPair(progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            ProgressPair(progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testNSProgressWithCSProgressChildren(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
    
    func testImplicitCSProgress() {
        let queue = OperationQueue()
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity)
        
        masterProgress.becomeCurrent(withPendingUnitCount: subAPortion, queue: queue)
        let subProgressA = CSProgress(totalUnitCount: subACount, granularity: granularity)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subBPortion, queue: queue)
        let subProgressB = CSProgress(totalUnitCount: subBCount, granularity: granularity)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subCPortion, queue: queue)
        let subProgressC = CSProgress(totalUnitCount: subCCount, granularity: granularity)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subDPortion, queue: queue)
        let subProgressD = CSProgress(totalUnitCount: subDCount, granularity: granularity)
        masterProgress.resignCurrent()
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let masterProgressPair = ProgressPair(progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        let childProgressPairs = [
            ProgressPair(progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            ProgressPair(progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            ProgressPair(progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            ProgressPair(progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testCSProgresses(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
    
    func testImplicitNSProgressesRootedByCSProgress() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity)
        
        masterProgress.becomeCurrent(withPendingUnitCount: subAPortion, queue: queue)
        let subProgressA = Foundation.Progress(totalUnitCount: subACount)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subBPortion, queue: queue)
        let subProgressB = Foundation.Progress(totalUnitCount: subBCount)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subCPortion, queue: queue)
        let subProgressC = Foundation.Progress(totalUnitCount: subCCount)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subDPortion, queue: queue)
        let subProgressD = Foundation.Progress(totalUnitCount: subDCount)
        masterProgress.resignCurrent()
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let masterProgressPair = ProgressPair(progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        let childProgressPairs = [
            NSProgressPair(bridged: subProgressA, nonBridged: subNSProgressA, nonPendingUnitCount: subACount),
            NSProgressPair(bridged: subProgressB, nonBridged: subNSProgressB, nonPendingUnitCount: subBCount),
            NSProgressPair(bridged: subProgressC, nonBridged: subNSProgressC, nonPendingUnitCount: subCCount),
            NSProgressPair(bridged: subProgressD, nonBridged: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testCSProgressWithNSProgressChildren(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
    
    func testImplicitCSProgressesRootedByNSProgress() {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        
        let granularity = CSProgressTests.granularity
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = Foundation.Progress.discreteProgress(totalUnitCount: masterCount)
        
        masterProgress.becomeCurrent(withPendingUnitCount: subAPortion)
        let subProgressA = CSProgress(totalUnitCount: subACount, granularity: granularity, queue: queue)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subBPortion)
        let subProgressB = CSProgress(totalUnitCount: subBCount, granularity: granularity, queue: queue)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subCPortion)
        let subProgressC = CSProgress(totalUnitCount: subCCount, granularity: granularity, queue: queue)
        masterProgress.resignCurrent()
        
        masterProgress.becomeCurrent(withPendingUnitCount: subDPortion)
        let subProgressD = CSProgress(totalUnitCount: subDCount, granularity: granularity, queue: queue)
        masterProgress.resignCurrent()
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let masterProgressPair = NSProgressPair(bridged: masterProgress, nonBridged: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion)
        let childProgressPairs = [
            ProgressPair(progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            ProgressPair(progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            ProgressPair(progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            ProgressPair(progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        self.testNSProgressWithCSProgressChildren(masterProgress: masterProgressPair, childProgresses: childProgressPairs, queue: queue)
    }
}

extension Collection {
    func shuffled() -> [Self.Iterator.Element] {
        let indexes = (0..<Int(self.distance(from: self.startIndex, to: self.endIndex).toIntMax())).map { _ in arc4random() }
        return zip(self, indexes).sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
