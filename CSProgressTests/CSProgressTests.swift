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
    
    private static let granularity = 0.01
    private static let tolerance: Double = 0.0001
    
    private func testCSProgresses(masterProgress: ProgressPair, childProgresses: [ProgressPair], queue: OperationQueue) {
        let numOfEach = 10000
        
        let changes = ([masterProgress] + childProgresses).flatMap { eachProgressPair in
            return (0..<numOfEach).map { _ in
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
        
        let expectation = self.expectation(description: "All Done")
        
        DispatchQueue.global().async {
            var lastFraction = 0.0
            
            for eachChange in changes {
                let id = masterProgress.progress.addFractionCompletedNotification { _, _, fraction in
                    lastFraction = fraction
                    
                    if abs(fraction - masterProgress.progress.fractionCompleted) > CSProgressTests.tolerance {
                        print("fraction: \(fraction)")
                        
                        print("master      : \(masterProgress.progress.completedUnitCount) of \(masterProgress.progress.totalUnitCount) (\(masterProgress.progress.fractionCompleted))")
                        print("master (ns) : \(masterProgress.nsProgress.completedUnitCount) of \(masterProgress.nsProgress.totalUnitCount) (\(masterProgress.nsProgress.fractionCompleted))")
                        
                        for (index, eachChild) in childProgresses.enumerated() {
                            print("child \(index + 1)     : \(eachChild.progress.completedUnitCount) of \(eachChild.progress.totalUnitCount) (\(eachChild.progress.fractionCompleted))")
                            print("child (ns) \(index + 1): \(eachChild.nsProgress.completedUnitCount) of \(eachChild.nsProgress.totalUnitCount) (\(eachChild.nsProgress.fractionCompleted))")
                        }
                        
                        XCTFail("Fraction doesn't match")
                    }
                }
                
                eachChange()
                
                queue.waitUntilAllOperationsAreFinished()
                
                masterProgress.progress.removeFractionCompletedNotification(identifier: id)
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
    
    func testCSProgresses() {
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
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity, queue: queue)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity, queue: queue)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity, queue: queue)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity, queue: queue)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity, queue: queue)
        
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
        
        let masterProgress = CSProgress(wrappedNSProgress: Foundation.Progress.discreteProgress(totalUnitCount: masterCount), parent: nil, pendingUnitCount: 0, granularity: granularity, queue: queue)
        let subProgressA = CSProgress(wrappedNSProgress: Foundation.Progress.discreteProgress(totalUnitCount: subACount), parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity, queue: queue)
        let subProgressB = CSProgress(wrappedNSProgress: Foundation.Progress.discreteProgress(totalUnitCount: subBCount), parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity, queue: queue)
        let subProgressC = CSProgress(wrappedNSProgress: Foundation.Progress.discreteProgress(totalUnitCount: subCCount), parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity, queue: queue)
        let subProgressD = CSProgress(wrappedNSProgress: Foundation.Progress.discreteProgress(totalUnitCount: subDCount), parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity, queue: queue)
        
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
        let numOfEach = 10000
        let granularity = CSProgressTests.granularity
        
        let queue = OperationQueue()
        
        let masterCount = CSProgress.UnitCount(arc4random())
        let subACount = CSProgress.UnitCount(arc4random())
        let subBCount = CSProgress.UnitCount(arc4random())
        let subCCount = CSProgress.UnitCount(arc4random())
        let subDCount = CSProgress.UnitCount(arc4random())
        
        let subAPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subBPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subCPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        let subDPortion = CSProgress.UnitCount(arc4random_uniform(UInt32(masterCount / 4)))
        
        let masterProgress = CSProgress.discreteProgress(totalUnitCount: masterCount, granularity: granularity, queue: queue)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity, queue: queue)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity, queue: queue)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity, queue: queue)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity, queue: queue)
        
        let masterBridgedProgress = masterProgress._bridgeToObjectiveC()
        let subBridgedProgressA = subProgressA._bridgeToObjectiveC()
        let subBridgedProgressB = subProgressB._bridgeToObjectiveC()
        let subBridgedProgressC = subProgressC._bridgeToObjectiveC()
        let subBridgedProgressD = subProgressD._bridgeToObjectiveC()
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        let progressPairs: [(bridged: Foundation.Progress, nonBridged: Foundation.Progress, nonPendingUnitCount: CSProgress.UnitCount)] = [
            (bridged: masterBridgedProgress, nonBridged: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion),
            (bridged: subBridgedProgressA, nonBridged: subNSProgressA, nonPendingUnitCount: subACount),
            (bridged: subBridgedProgressB, nonBridged: subNSProgressB, nonPendingUnitCount: subBCount),
            (bridged: subBridgedProgressC, nonBridged: subNSProgressC, nonPendingUnitCount: subCCount),
            (bridged: subBridgedProgressD, nonBridged: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        let changes = progressPairs.flatMap { (bridged, nonBridged, nonPendingUnitCount) in
            return (0..<numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(nonPendingUnitCount))
                    
                    nonBridged.completedUnitCount = Int64(portion)
                    bridged.completedUnitCount = CSProgress.UnitCount(portion)
                }
            }
        }.shuffled()
        
        let expectation = self.expectation(description: "Finished")
        
        DispatchQueue.global().async {
            for eachChange in changes {
                eachChange()
                
                queue.waitUntilAllOperationsAreFinished()
                
                XCTAssert(abs(masterBridgedProgress.fractionCompleted - masterNSProgress.fractionCompleted) <= CSProgressTests.tolerance)
            }
            
            expectation.fulfill()
        }
        
        self.waitForExpectations(timeout: 3600.0) {
            if let error = $0 {
                print("Error: \(error)")
            }
        }
    }
    
    func testCSProgressesRootedByNSProgress() {
        let numOfEach = 10000
        
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
        let masterProgress = CSProgress(wrappedNSProgress: wrappedProgress, parent: nil, pendingUnitCount: 0, granularity: granularity, queue: queue)
        let subProgressA = CSProgress(totalUnitCount: subACount, parent: masterProgress, pendingUnitCount: subAPortion, granularity: granularity, queue: queue)
        let subProgressB = CSProgress(totalUnitCount: subBCount, parent: masterProgress, pendingUnitCount: subBPortion, granularity: granularity, queue: queue)
        let subProgressC = CSProgress(totalUnitCount: subCCount, parent: masterProgress, pendingUnitCount: subCPortion, granularity: granularity, queue: queue)
        let subProgressD = CSProgress(totalUnitCount: subDCount, parent: masterProgress, pendingUnitCount: subDPortion, granularity: granularity, queue: queue)
        
        let masterNSProgress = Foundation.Progress.discreteProgress(totalUnitCount: Int64(masterCount))
        let subNSProgressA = Foundation.Progress(totalUnitCount: Int64(subACount), parent: masterNSProgress, pendingUnitCount: Int64(subAPortion))
        let subNSProgressB = Foundation.Progress(totalUnitCount: Int64(subBCount), parent: masterNSProgress, pendingUnitCount: Int64(subBPortion))
        let subNSProgressC = Foundation.Progress(totalUnitCount: Int64(subCCount), parent: masterNSProgress, pendingUnitCount: Int64(subCPortion))
        let subNSProgressD = Foundation.Progress(totalUnitCount: Int64(subDCount), parent: masterNSProgress, pendingUnitCount: Int64(subDPortion))
        
        class KVOWatcher: NSObject {
            private var kvoContext = 0
            private let progress: Foundation.Progress
            private let masterNSProgress: Foundation.Progress
            
            init(progress: Foundation.Progress, masterNSProgress: Foundation.Progress) {
                self.progress = progress
                self.masterNSProgress = masterNSProgress
                
                super.init()
                
                progress.addObserver(self, forKeyPath: "fractionCompleted", options: [], context: &self.kvoContext)
            }
            
            deinit {
                progress.removeObserver(self, forKeyPath: "fractionCompleted", context: &self.kvoContext)
            }
            
            var count = 0
            
            override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
                if context == &self.kvoContext {
                    XCTAssert(abs(self.progress.fractionCompleted - self.masterNSProgress.fractionCompleted) <= CSProgressTests.granularity)
                } else {
                    super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
                }
            }
        }
        
        let kvoWatcher = KVOWatcher(progress: wrappedProgress, masterNSProgress: masterNSProgress)
        
        let progressPairs: [(progress: CSProgress, nsProgress: Foundation.Progress, nonPendingUnitCount: CSProgress.UnitCount)] = [
            (progress: masterProgress, nsProgress: masterNSProgress, nonPendingUnitCount: masterCount - subAPortion - subBPortion - subCPortion - subDPortion),
            (progress: subProgressA, nsProgress: subNSProgressA, nonPendingUnitCount: subACount),
            (progress: subProgressB, nsProgress: subNSProgressB, nonPendingUnitCount: subBCount),
            (progress: subProgressC, nsProgress: subNSProgressC, nonPendingUnitCount: subCCount),
            (progress: subProgressD, nsProgress: subNSProgressD, nonPendingUnitCount: subDCount)
        ]
        
        let changes = progressPairs.flatMap { (bridged, nonBridged, nonPendingUnitCount) in
            return (0..<numOfEach).map { _ in
                return {
                    let portion = arc4random_uniform(UInt32(nonPendingUnitCount))
                    
                    nonBridged.completedUnitCount = Int64(portion)
                    bridged.completedUnitCount = CSProgress.UnitCount(portion)
                }
            }
        }.shuffled()
        
        let expectation = self.expectation(description: "Finished")
        
        DispatchQueue.global().async {
            for eachChange in changes {
                eachChange()
                
                queue.waitUntilAllOperationsAreFinished()
                
                XCTAssert(abs(wrappedProgress.fractionCompleted - masterNSProgress.fractionCompleted) <= CSProgressTests.granularity)
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
}

extension Collection {
    func shuffled() -> [Self.Iterator.Element] {
        let indexes = (0..<Int(self.distance(from: self.startIndex, to: self.endIndex).toIntMax())).map { _ in arc4random() }
        return zip(self, indexes).sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
