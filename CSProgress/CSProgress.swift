//
//  CSProgress.swift
//  CSSwiftExtensions
//
//  Copyright © 2016-2017 Charles Srstka. All rights reserved.
//
//  Redistribution and use in source and binary forms, with or without
//  modification, are permitted provided that the following conditions are met:
//
//  1. Redistributions of source code must retain the above copyright notice, this
//     list of conditions and the following disclaimer.
//  2. Redistributions in binary form must reproduce the above copyright notice,
//     this list of conditions and the following disclaimer in the documentation
//     and/or other materials provided with the distribution.
//  3. Exception to the above: Apple Computer, Inc. is granted permission to do
//     whatever they wish with this code.
//
//  THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
//  ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
//  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//  DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
//  ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
//  (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
//  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
//  (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
//  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//

import Foundation

// Since we are going for source compatibility with NSProgress and thus need to use standard init() methods, and since we can't have factory initializers,
// separate the backing out into a separate private structure. We have separate implementations for an all-native CSProgress and one that's wrapping an NSProgress.
// All calls to methods on the backing should be protected by the progress's semaphore.
private protocol CSProgressBacking {
    var totalUnitCount: CSProgress.UnitCount { get }
    var completedUnitCount: CSProgress.UnitCount { get }
    var fractionCompleted: Double { get }
    var localizedDescription: String { get }
    var localizedAdditionalDescription: String { get }
    var isIndeterminate: Bool { get }
    var isCancelled: Bool { get }
    
    func set(totalUnitCount: CSProgress.UnitCount?, completedUnitCount: CSProgress.UnitCountChangeType?, localizedDescription: String?, localizedAdditionalDescription: String?, cancel: Bool, setupHandler: @escaping () -> (), completionHandler: @escaping () -> ())
    
    var children: [CSProgress] { get }
    func addChild(_ child: CSProgress, pendingUnitCount: CSProgress.UnitCount)
    func removeChild(_ child: CSProgress)
}

// 'final' is apparently needed to conform to _ObjectiveCBridgeable. It also results in better performance.
public final class CSProgress {
    // We allow increments as an atomic operation, for better performance.
    fileprivate enum UnitCountChangeType {
        case set(CSProgress.UnitCount)
        case increment(CSProgress.UnitCount)
    }
    
    // By default, we'll update 100 times over the course of our progress. This should provide a decent user experience without compromising too much on performance.
    private static let defaultGranularity: Double = 0.01
    
    // Declare our own unit count type instead of hard-coding it to Int64, for future flexibility.
    public typealias UnitCount = Int64
    
    // Notification types. These will all be executed on the progress's queue.
    
    /// This closure will be executed on the progress's queue if the progress is cancelled.
    public typealias CancellationNotification = () -> ()
    
    /// This closure will be executed on the progress's queue whenever the change in fractionCompleted exceeds the granularity.
    public typealias FractionCompletedNotification = (_ completedUnitCount: UnitCount, _ totalUnitCount: UnitCount, _ fractionCompleted: Double) -> ()
    
    /// This closure will be executed on the progress's queue when the progress's description is changed.
    public typealias DescriptionNotification = (_ localizedDescription: String, _ localizedAdditionalDescription: String) -> ()
    
    /// Convenience struct for passing a CSProgress to a child function explicitly, encapsulating the parent progress and its pending unit count.
    /// Create one of these by calling .pass() on the parent progress.
    public struct ParentReference {
        let progress: CSProgress
        fileprivate let pendingUnitCount: CSProgress.UnitCount
        
        // This creates a child progress, attached to the parent progress with the pending unit count specified when this struct was created.
        func makeChild(totalUnitCount: CSProgress.UnitCount) -> CSProgress {
            return CSProgress(totalUnitCount: totalUnitCount, parent: self.progress, pendingUnitCount: self.pendingUnitCount)
        }
        
        // For the case where the child operation is atomic, just mark the pending units as complete rather than creating a child progress.
        // Can also be useful for error conditions where the operation should simply be skipped.
        func markComplete() {
            self.progress.completedUnitCount += self.pendingUnitCount
        }
    }
    
    // The backing for a native Swift CSProgress.
    private final class NativeBacking: CSProgressBacking {
        private(set) var totalUnitCount: CSProgress.UnitCount
        private(set) var completedUnitCount: CSProgress.UnitCount = 0
        
        func incrementCompletedUnitCount(by interval: UnitCount) {
            self.completedUnitCount += interval
        }
        
        var fractionCompleted: Double {
            if self.completedUnitCount >= self.totalUnitCount {
                return 1.0
            }
            
            if self.totalUnitCount == 0 {
                return 0.0
            }
            
            let myPortion = Double(self.completedUnitCount)
            let childrenPortion = self.children.reduce(0) { $0 + $1.backing.fractionCompleted * Double($1._portionOfParent) }
            
            return (myPortion + childrenPortion) / Double(self.totalUnitCount)
        }
        
        private(set) var localizedDescription: String = ""
        private(set) var localizedAdditionalDescription: String = ""
        
        var isIndeterminate: Bool { return self.totalUnitCount == 0 && self.completedUnitCount == 0 }
        private(set) var isCancelled = false
        
        private(set) var children: [CSProgress] = []
        
        init(totalUnitCount: UnitCount) {
            self.totalUnitCount = totalUnitCount
        }
        
        func set(totalUnitCount: CSProgress.UnitCount?, completedUnitCount changeType: CSProgress.UnitCountChangeType?, localizedDescription: String?, localizedAdditionalDescription: String?, cancel: Bool, setupHandler: @escaping () -> (), completionHandler: @escaping () -> ()) {
            setupHandler()
            
            if let totalUnitCount = totalUnitCount {
                self.totalUnitCount = totalUnitCount
            }
            
            if let changeType = changeType {
                switch changeType {
                case let .set(newValue):
                    self.completedUnitCount = newValue
                case let .increment(delta):
                    self.completedUnitCount += delta
                }
            }
            
            if let localizedDescription = localizedDescription {
                self.localizedDescription = localizedDescription
            }
            
            if let localizedAdditionalDescription = localizedAdditionalDescription {
                self.localizedAdditionalDescription = localizedAdditionalDescription
            }
            
            if cancel {
                self.isCancelled = true
            }
            
            completionHandler()
        }
        
        func addChild(_ child: CSProgress, pendingUnitCount: UnitCount) {
            if !self.children.contains(where: { $0 === child }) {
                self.children.append(child)
                child.portionOfParent = pendingUnitCount
            }
        }
        
        func removeChild(_ child: CSProgress) {
            self.children = self.children.filter { $0 !== child }
        }
    }
    
    /**
     Corresponds to NSProgress's -discreteProgressWithTotalUnitCount:.
     
     - parameter totalUnitCount: The total unit count for this progress.
     
     - parameter granularity: Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     
     - parameter queue: Specifies an operation queue on which the progress object's notifications will be performed.
     The queue's maxConcurrentOperationCount should be set to something low to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.
     
     */
    public class func discreteProgress<Count: Integer>(totalUnitCount: Count, granularity: Double = CSProgress.defaultGranularity, queue: OperationQueue = .main) -> CSProgress {
        return self.init(totalUnitCount: totalUnitCount, parent: nil, pendingUnitCount: 0, granularity: granularity, queue: queue)
    }
    
    /**
     Corresponds to NSProgress's -initWithTotalUnitCount:parent:pendingUnitCount:.
     
     - parameter totalUnitCount: The total unit count for this progress.
     
     - parameter parent: The progress's parent. Can be nil.
     
     - parameter pendingUnitCount: The portion of the parent's totalUnitCount that this progress object represents. Pass zero for a nil parent.
     
     - parameter granularity: Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     
     - parameter queue: Specifies an operation queue on which the progress object's notifications will be performed.
     The queue's maxConcurrentOperationCount should be set to something low to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.
     
     */
    public init<Total: Integer, Pending: Integer>(totalUnitCount: Total, parent: CSProgress?, pendingUnitCount: Pending, granularity: Double = CSProgress.defaultGranularity, queue: OperationQueue = .main) {
        self.backing = NativeBacking(totalUnitCount: UnitCount(totalUnitCount.toIntMax()))
        self.parent = parent
        self._portionOfParent = UnitCount(totalUnitCount.toIntMax())
        self.granularity = granularity
        self.queue = queue
        
        self.parent?.addChild(self, withPendingUnitCount: pendingUnitCount)
    }
    
    // The backing for this progress. All calls to methods and properties on the backing should be protected by our semaphore.
    fileprivate var backing: CSProgressBacking
    
    // The access semaphore, allowing us to be thread-safe. A semaphore was chosen, because it performs better here than an NSLock or a dispatch queue.
    private var accessSemaphore = DispatchSemaphore(value: 1)
    
    // The parent progress object.
    private weak var parent: CSProgress?
    
    /// The total number of units of work to be carried out.
    public var totalUnitCount: UnitCount {
        get {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            return self.backing.totalUnitCount
        }
        set {
            // For the NSProgress-backed type, the setters will be called on our queue, to prevent KVO notifications from being fired on our own thread (and to improve performance).
            // Therefore, pass closures to .set() to let it take and release the semaphore rather than doing it ourselves.
            
            let setupHandler = { self.accessSemaphore.wait() }
            
            self.backing.set(totalUnitCount: newValue, completedUnitCount: nil, localizedDescription: nil, localizedAdditionalDescription: nil, cancel: false, setupHandler: setupHandler) {
                defer { self.accessSemaphore.signal() }
                
                self.sendFractionCompletedNotifications()
            }
        }
    }
    
    /// The number of units of work for the current job that have already been completed.
    public var completedUnitCount: UnitCount {
        get {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            return self.backing.completedUnitCount
        }
        set {
            // For the NSProgress-backed type, the setters will be called on our queue, to prevent KVO notifications from being fired on our own thread (and to improve performance).
            // Therefore, pass closures to .set() to let it take and release the semaphore rather than doing it ourselves.
            
            let setupHandler = { self.accessSemaphore.wait() }
            
            self.backing.set(totalUnitCount: nil, completedUnitCount: .set(newValue), localizedDescription: nil, localizedAdditionalDescription: nil, cancel: false, setupHandler: setupHandler) {
                self.sendFractionCompletedNotifications()
                self.accessSemaphore.signal()
            }
        }
    }

    /// Perform increment as one atomic operation, eliminating an unnecessary semaphore wait and increasing performance.
    public func incrementCompletedUnitCount<Count: Integer>(by interval: Count) {
        let setupHandler = { self.accessSemaphore.wait() }
        
        self.backing.set(totalUnitCount: nil, completedUnitCount: .increment(UnitCount(interval.toIntMax())), localizedDescription: nil, localizedAdditionalDescription: nil, cancel: false, setupHandler: setupHandler) {
            self.sendFractionCompletedNotifications()
            self.accessSemaphore.signal()
        }
    }

    // The portion of the parent's unit count represented by the progress object.
    private var _portionOfParent: UnitCount
    private var portionOfParent: UnitCount {
        get {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            return self._portionOfParent
        }
        set {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            self._portionOfParent = newValue
        }
    }
    
    /// The fraction of the overall work completed by this progress object, including work done by any children it may have.
    public var fractionCompleted: Double {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        return self.backing.fractionCompleted
    }
    
    //// Indicates whether the tracked progress is indeterminate.
    public var isIndeterminate: Bool {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        return self.backing.isIndeterminate
    }
    
    /// Indicates whether the receiver is tracking work that has been cancelled.
    public var isCancelled: Bool {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        if let parent = self.parent, parent.backing.isCancelled { return true }
        
        return self.backing.isCancelled
    }
    
    /// Cancel progress tracking.
    public func cancel() {
        let setupHandler = { self.accessSemaphore.wait() }
        
        self.backing.set(totalUnitCount: nil, completedUnitCount: nil, localizedDescription: nil, localizedAdditionalDescription: nil, cancel: true, setupHandler: setupHandler) {
            self.sendCancellationNotifications()
            self.accessSemaphore.signal()
        }
    }
    
    /// A localized description of progress tracked by the receiver.
    public var localizedDescription: String {
        get {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            return self.backing.localizedDescription
        }
        set {
            let setupHandler = { self.accessSemaphore.wait() }
            
            self.backing.set(totalUnitCount: nil, completedUnitCount: nil, localizedDescription: newValue, localizedAdditionalDescription: nil, cancel: false, setupHandler: setupHandler) {
                self.sendDescriptionNotifications()
                self.accessSemaphore.signal()
            }
        }
    }
    
    /// A more specific localized description of progress tracked by the receiver.
    public var localizedAdditionalDescription: String {
        get {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            return self.backing.localizedAdditionalDescription
        }
        set {
            let setupHandler = { self.accessSemaphore.wait() }
            
            self.backing.set(totalUnitCount: nil, completedUnitCount: nil, localizedDescription: nil, localizedAdditionalDescription: newValue, cancel: false, setupHandler: setupHandler) {
                self.sendDescriptionNotifications()
                self.accessSemaphore.signal()
            }
        }
    }
    
    /**
     Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     */
    public let granularity: Double
    
    /// The operation queue on which notifications will be fired when the progress object's properties change.
    private let queue: OperationQueue
    
    /**
     Create a reference to a parent progress, encapsulating both it and its pending unit count.
     This allows the child function to attach a new progress without knowing details about the parent progress and its unit count.
     */
    public func pass<Count: Integer>(pendingUnitCount: Count) -> ParentReference {
        return ParentReference(progress: self, pendingUnitCount: UnitCount(pendingUnitCount.toIntMax()))
    }
    
    /**
     Add a progress object as a child of a progress tree. The inUnitCount indicates the expected work for the progress unit.
     
     - parameter child: The NSProgress instance to add to the progress tree.
     
     - parameter pendingUnitCount: The number of units of work to be carried out by the new child.
     */
    public func addChild<Count: Integer>(_ child: CSProgress, withPendingUnitCount pendingUnitCount: Count) {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        // Progress objects in the same family tree share a semaphore to keep their values synced and to prevent shenanigans
        // (particularly when calculating fractionCompleted values).
        self.backing.addChild(child, pendingUnitCount: UnitCount(pendingUnitCount.toIntMax()))
        child.accessSemaphore = self.accessSemaphore
    }
    
    // Remove a progress object from our progress tree.
    private func removeChild(_ child: CSProgress) {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        self.backing.removeChild(child)
        child.parent = nil
        child.accessSemaphore = DispatchSemaphore(value: 1)
    }
    
    private var cancellationNotifications: [UUID : CancellationNotification] = [:]
    private var fractionCompletedNotifications: [UUID : FractionCompletedNotification] = [:]
    private var descriptionNotifications: [UUID : DescriptionNotification] = [:]
    private var lastNotifiedFractionCompleted: Double = 0.0
    
    // The add...Notification() methods return an identifier which can be later sent to remove...Notification() to remove the notification.
    
    private func _addCancellationNotification(_ notification: @escaping CancellationNotification) -> Any {
        let uuid = UUID()
        
        self.cancellationNotifications[uuid] = notification
        
        return uuid
    }
    
    /**
     Add a notification which will be called if the progress object is cancelled.
     
     - parameter notification: A notification that will be called if the progress object is cancelled. This notification will be called on the progress object's queue.
     
     - returns: An opaque value that can be passed to removeCancellationNotification() to de-register the notification.
     */
    public func addCancellationNotification(_ notification: @escaping CancellationNotification) -> Any {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        return self._addCancellationNotification(notification)
    }
    
    private func _removeCancellationNotification(identifier: Any) {
        guard let uuid = identifier as? UUID else { return }
        
        self.cancellationNotifications[uuid] = nil
    }
    
    /**
     Remove a notification previously added via addCancellationNotification().
     
     - parameter identifier: The identifier previously returned by addCancellationNotification() for the notification you wish to remove.
     */
    public func removeCancellationNotification(identifier: Any) {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        self._removeCancellationNotification(identifier: identifier)
    }
    
    private func _addFractionCompletedNotification(_ notification: @escaping FractionCompletedNotification) -> Any {
        let uuid = UUID()
        
        self.fractionCompletedNotifications[uuid] = notification
        
        return uuid
    }
    
    /**
     Add a notification which will be called when the progress object's fractionCompleted property changes by an amount greater than the progress object's granularity.
     
     - parameter notification: A notification that will be called when the fractionCompleted property is significantly changed.
     This notification will be called on the progress object's queue.
     
     - returns: An opaque value that can be passed to removeFractionCompletedNotification() to de-register the notification.
     */
    @discardableResult public func addFractionCompletedNotification(_ notification: @escaping FractionCompletedNotification) -> Any {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        return _addFractionCompletedNotification(notification)
    }
    
    private func _removeFractionCompletedNotification(identifier: Any) {
        guard let uuid = identifier as? UUID else { return }
        
        self.fractionCompletedNotifications[uuid] = nil
    }
    
    /**
     Remove a notification previously added via addFractionCompletedNotification().
     
     - parameter identifier: The identifier previously returned by addFractionCompletedNotification() for the notification you wish to remove.
     */
    @discardableResult public func removeFractionCompletedNotification(identifier: Any) {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        self._removeFractionCompletedNotification(identifier: identifier)
    }
    
    private func _addDescriptionNotification(_ notification: @escaping DescriptionNotification) -> Any {
        let uuid = UUID()
        
        self.descriptionNotifications[uuid] = notification
        
        return uuid
    }
    
    /**
     Add a notification which will be called when the progress object's localizedDescription or localizedAdditionalDescription property changes.
     
     - parameter notification: A notification that will be called when the fractionComplocalizedDescription or localizedAdditionalDescriptionleted property is changed.
     This notification will be called on the progress object's queue.
     
     - returns: An opaque value that can be passed to removeDescriptionNotification() to de-register the notification.
     */
    @discardableResult public func addDescriptionNotification(_ notification: @escaping DescriptionNotification) -> Any {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        return _addDescriptionNotification(notification)
    }
    
    private func _removeDescriptionNotification(identifier: Any) {
        guard let uuid = identifier as? UUID else { return }
        
        self.descriptionNotifications[uuid] = nil
    }
    
    /**
     Remove a notification previously added via addDescriptionNotification().
     
     - parameter identifier: The identifier previously returned by addDescriptionNotification() for the notification you wish to remove.
     */
    public func removeDescriptionNotification(identifier: Any) {
        self.accessSemaphore.wait()
        defer { self.accessSemaphore.signal() }
        
        self._removeDescriptionNotification(identifier: identifier)
    }
    
    // Fire our cancellation notifications.
    // This method should be protected by our semaphore before calling it.
    private func sendCancellationNotifications() {
        let notifications = self.cancellationNotifications.values
        let children = self.backing.children
        
        self.queue.addOperation {
            for eachNotification in notifications {
                eachNotification()
            }
        }
        
        for eachChild in children {
            eachChild.sendCancellationNotifications()
        }
    }
    
    // Fire our fractionCompleted notifications.
    // This method should be protected by our semaphore before calling it.
    private func sendFractionCompletedNotifications() {
        let fractionCompleted = self.backing.fractionCompleted
        let lastNotifiedFractionCompleted = self.lastNotifiedFractionCompleted
        let completedUnitCount = self.backing.completedUnitCount
        let totalUnitCount = self.backing.totalUnitCount
        let notifications = self.fractionCompletedNotifications.values
        let parent = self.parent
        
        if completedUnitCount >= totalUnitCount || fabs(fractionCompleted - lastNotifiedFractionCompleted) >= self.granularity {
            if !notifications.isEmpty {
                self.queue.addOperation {
                    for eachNotification in notifications {
                        eachNotification(completedUnitCount, totalUnitCount, fractionCompleted)
                    }
                }
            }
            
            parent?.sendFractionCompletedNotifications()
            self.lastNotifiedFractionCompleted = fractionCompleted
        }
    }
    
    // Fire our description notifications.
    // This method should be protected by our semaphore before calling it.
    private func sendDescriptionNotifications() {
        let description = self.backing.localizedDescription
        let additionalDescription = self.backing.localizedAdditionalDescription
        let notifications = self.descriptionNotifications.values
        
        self.queue.addOperation {
            for eachNotification in notifications {
                eachNotification(description, additionalDescription)
            }
        }
    }

    // MARK: Objective-C Compatibility Crud
    // Note: Everything below this point exists for Objective-C interoperability. If Objective-C compatibility is not important, feel free to delete everything below.
    // Warning: The code gets notably uglier beyond this point. All hope abandon, ye who enter here!
    
    // The backing for a CSProgress wrapping an NSProgress.
    fileprivate final class NSProgressBacking: NSObject, CSProgressBacking {
        let progress: Foundation.Progress
        let queue: OperationQueue
        
        private var isUpdatingKey: pthread_key_t = 0
        
        init(progress: Foundation.Progress, queue: OperationQueue) {
            self.progress = progress
            self.queue = queue
            
            super.init()
            
            // Create a thread-local key to keep track of whether we are in the middle of an update.
            // This is to suppress KVO notifications caused by ourselves and prevent infinite loops.
            // We use a thread-local variable to avoid race conditions that could inadvertently cause
            // the suppression of KVO notifications sent from other threads.
            
            pthread_key_create(&self.isUpdatingKey) {
                let ptr = $0.bindMemory(to: Bool.self, capacity: 1)
                
                ptr.deinitialize(count: 1)
                ptr.deallocate(capacity: 1)
            }
            
            self.startWatching()
        }
        
        deinit {
            self.stopWatching()
        }
        
        // Returns whether we're in the middle of an update of one of our properties on this thread.
        // If this is true, we want to ignore any KVO notifications that come in, because they'll just be caused by us.
        private var isUpdating: Bool {
            get {
                return pthread_getspecific(self.isUpdatingKey)?.bindMemory(to: Bool.self, capacity: 1).pointee ?? false
            }
            set {
                if let ptr = pthread_getspecific(self.isUpdatingKey)?.bindMemory(to: Bool.self, capacity: 1) {
                    ptr.pointee = newValue
                } else {
                    let ptr = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
                    ptr.initialize(to: newValue)
                    
                    pthread_setspecific(self.isUpdatingKey, ptr)
                }
            }
        }
        
        // Pass through all these properties to the underlying progress object.
        var totalUnitCount: CSProgress.UnitCount { return self.progress.totalUnitCount }
        var completedUnitCount: CSProgress.UnitCount { return self.progress.completedUnitCount }
        var fractionCompleted: Double { return self.progress.fractionCompleted }
        var localizedDescription: String { return self.progress.localizedDescription }
        var localizedAdditionalDescription: String { return self.progress.localizedAdditionalDescription }
        var isIndeterminate: Bool { return self.progress.isIndeterminate }
        var isCancelled: Bool { return self.progress.isCancelled }
        
        func set(totalUnitCount: CSProgress.UnitCount?, completedUnitCount changeType: UnitCountChangeType?, localizedDescription: String?, localizedAdditionalDescription: String?, cancel: Bool, setupHandler: @escaping () -> (), completionHandler: @escaping () -> ()) {
            // Make our changes on the queue, to avoid jamming up the worker thread with KVO notifications.
            queue.addOperation {
                setupHandler()
                
                self.isUpdating = true
                
                if let totalUnitCount = totalUnitCount {
                    self.progress.totalUnitCount = Int64(totalUnitCount)
                }
                
                if let changeType = changeType {
                    switch changeType {
                    case let .set(newValue):
                        if newValue != self.progress.completedUnitCount {
                            self.progress.completedUnitCount = Int64(newValue)
                        }
                    case let .increment(delta):
                        self.progress.completedUnitCount += Int64(delta)
                    }
                }
                
                if let localizedDescription = localizedDescription {
                    self.progress.localizedDescription = localizedDescription
                }
                
                if let localizedAdditionalDescription = localizedAdditionalDescription {
                    self.progress.localizedAdditionalDescription = localizedAdditionalDescription
                }
                
                if cancel {
                    self.progress.cancel()
                }
                
                self.isUpdating = false
                
                completionHandler()
            }
        }
        
        var children: [CSProgress] { return [] }
        
        func addChild(_ child: CSProgress, pendingUnitCount: UnitCount) {
            if #available(macOS 10.11, *) {
                self.progress.addChild(child._bridgeToObjectiveC(), withPendingUnitCount: Int64(pendingUnitCount))
            } else {
                // Since we can't addChild on older OS versions, create a native wrapper for our child, implicitly add the child to the wrapper, and explicitly add the wrapper to us.
                // FIXME: this has not been tested yet.
                self.progress.becomeCurrent(withPendingUnitCount: Int64(pendingUnitCount))
                let wrapper = Foundation.Progress(totalUnitCount: 1)
                self.progress.resignCurrent()
                
                CSProgress._unconditionallyBridgeFromObjectiveC(wrapper).addChild(child, withPendingUnitCount: 1)
            }
        }
        
        func removeChild(_ child: CSProgress) {}
        
        var fractionCompletedUpdatedHandler: (() -> ())?
        var descriptionUpdatedHandler: (() -> ())?
        var cancellationHandler: (() -> ())?
        
        private let interestingKeyPaths = ["fractionCompleted", "cancelled", "localizedDescription", "localizedAdditionalDescription"]
        
        private var kvoContext = 0
        
        private func startWatching() {
            for eachKeyPath in self.interestingKeyPaths {
                self.progress.addObserver(self, forKeyPath: eachKeyPath, options: [], context: &self.kvoContext)
            }
        }
        
        private func stopWatching() {
            for eachKeyPath in self.interestingKeyPaths {
                self.progress.removeObserver(self, forKeyPath: eachKeyPath, context: &self.kvoContext)
            }
        }
        
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
            if context == &self.kvoContext {
                guard let keyPath = keyPath else { return }
                
                // If this change was caused by something we did ourselves, ignore the notification or we'll just keep going back and forth forever.
                if self.isUpdating { return }
                
                switch keyPath {
                case "fractionCompleted":
                    self.fractionCompletedUpdatedHandler.map { queue.addOperation($0) }
                case "cancelled":
                    self.cancellationHandler.map { queue.addOperation($0) }
                case "localizedDescription", "localizedAdditionalDescription":
                    self.descriptionUpdatedHandler.map { queue.addOperation($0) }
                default:
                    break
                }
            } else {
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        }
    }
    
    /**
     Create a CSProgress which wraps an NSProgress.
     All updates to the underlying progress object will be performed on the queue, to keep NSProgress's KVO notifications out of the worker thread as much as possible.
     However, due to the need to keep the underlying progress object in sync, an operation is enqueued on every update of completedUnitCount regardless of the granularity.
     Therefore, performance is poor when using the resulting object as you would a normal CSProgress object, because this will result in excessive queued operations,
     as well as many KVO notifications sent by NSOperation and NSOperationQueue.
     Progress objects created in this way should therefore only be used as parents or children for native CSProgress objects, in order to attach to an existing NSProgress tree.
     This is most useful when interacting with Objective-C code, or when using an NSProgress as the root of the tree in order to bind UI elements to it via KVO.
     
     - parameter wrappedNSProgress: The underlying NSProgress object.
     
     - parameter parent: The parent progress. Can be nil.
     
     - parameter pendingUnitCount: The portion of the parent's totalUnitCount that this progress object represents. Pass zero for a nil parent.
     
     - parameter granularity: Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     However, an operation to update the underlying NSProgress object will still be enqueued on every update.
     Default value is 0.01.
     
     - parameter queue: Specifies an operation queue on which the progress object's notifications will be performed.
     The underlying NSProgress object will also be updated on this queue.
     The queue's maxConcurrentOperationCount should be set to something low to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.
     */
    public init<Count: Integer>(wrappedNSProgress: Foundation.Progress, parent: CSProgress?, pendingUnitCount: Count, granularity: Double = CSProgress.defaultGranularity, queue: OperationQueue = .main) {
        let imp = NSProgressBacking(progress: wrappedNSProgress, queue: queue)
        
        self.backing = imp
        self.parent = parent
        self._portionOfParent = UnitCount(pendingUnitCount.toIntMax())
        self.granularity = granularity
        self.queue = queue
        
        // These handlers are called as a result of KVO notifications sent by the underlying progress object.
        
        imp.fractionCompletedUpdatedHandler = {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            self.sendFractionCompletedNotifications()
        }
        
        imp.descriptionUpdatedHandler = {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            self.sendDescriptionNotifications()
        }
        
        imp.cancellationHandler = {
            self.accessSemaphore.wait()
            defer { self.accessSemaphore.signal() }
            
            self.sendCancellationNotifications()
        }
        
        self.parent?.addChild(self, withPendingUnitCount: pendingUnitCount)
    }
}

extension CSProgress: _ObjectiveCBridgeable {
    // An NSProgress subclass that wraps a CSProgress.
    private final class BridgedNSProgress: Foundation.Progress {
        let progress: CSProgress
        
        private var fractionCompletedIdentifier: Any?
        private var descriptionIdentifier: Any?
        private var cancellationIdentifier: Any?
        
        init(progress: CSProgress) {
            self.progress = progress
            
            super.init(parent: nil, userInfo: nil)
            
            self.totalUnitCount = progress.totalUnitCount
            self.completedUnitCount = progress.completedUnitCount
            self.localizedDescription = progress.localizedDescription
            self.localizedAdditionalDescription = progress.localizedAdditionalDescription
            if progress.isCancelled { self.cancel() }

            // Register notifications on the underlying CSProgress, to update our properties.
            
            self.fractionCompletedIdentifier = progress.addFractionCompletedNotification { completed, total, _ in
                super.completedUnitCount = completed
                super.totalUnitCount = total
            }
            
            self.descriptionIdentifier = progress.addDescriptionNotification { desc, aDesc in
                super.localizedDescription = desc
                super.localizedAdditionalDescription = aDesc
            }
            
            self.cancellationIdentifier = progress.addCancellationNotification {
                super.cancel()
            }
        }
        
        deinit {
            self.fractionCompletedIdentifier.map { self.progress.removeFractionCompletedNotification(identifier: $0) }
            self.descriptionIdentifier.map { self.progress.removeDescriptionNotification(identifier: $0) }
            self.cancellationIdentifier.map { self.progress.removeCancellationNotification(identifier: $0) }
        }
        
        override var totalUnitCount: Int64 {
            didSet { self.progress.totalUnitCount = CSProgress.UnitCount(self.totalUnitCount) }
        }
        
        override var completedUnitCount: Int64 {
            didSet { self.progress.completedUnitCount = CSProgress.UnitCount(self.completedUnitCount) }
        }
        
        override var fractionCompleted: Double { return self.progress.fractionCompleted }
        
        override var localizedDescription: String! {
            didSet { self.progress.localizedDescription = self.localizedDescription }
        }
        
        override var localizedAdditionalDescription: String! {
            didSet { self.progress.localizedAdditionalDescription = self.localizedAdditionalDescription }
        }
    }
    
    public typealias _ObjectiveCType = Foundation.Progress
    
    public func _bridgeToObjectiveC() -> Foundation.Progress {
        // If we're wrapping an NSProgress, return that. Otherwise wrap ourselves in a BridgedNSProgress.
        
        if let imp = self.backing as? NSProgressBacking {
            return imp.progress
        } else {
            return BridgedNSProgress(progress: self)
        }
    }
    
    public static func _forceBridgeFromObjectiveC(_ ns: Foundation.Progress, result: inout CSProgress?) {
        result = self._unconditionallyBridgeFromObjectiveC(ns)
    }
    
    public static func _conditionallyBridgeFromObjectiveC(_ ns: Foundation.Progress, result: inout CSProgress?) -> Bool {
        result = self._unconditionallyBridgeFromObjectiveC(ns)
        return true
    }
    
    public static func _unconditionallyBridgeFromObjectiveC(_ ns: Foundation.Progress?) -> CSProgress {
        // If it's wrapping a CSProgress, return that. Otherwise, wrap that sucker
        
        if let bridged = ns as? BridgedNSProgress {
            return bridged.progress
        } else {
            return CSProgress(wrappedNSProgress: ns!, parent: nil, pendingUnitCount: 0)
        }
    }
}
