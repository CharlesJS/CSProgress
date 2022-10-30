//
//  CSProgress.swift
//
//  Created by Charles Srstka on 1/10/2016.
//  Copyright © 2016-2022 Charles Srstka. All rights reserved.
//

public final class CSProgress {
    // Notification types.

    /// This closure will be executed if the progress is cancelled.
    public typealias CancellationNotification = () async -> ()

    /// This closure will be executed whenever the change in fractionCompleted exceeds the granularity.
    public typealias FractionCompletedNotification = (
        _ completedUnitCount: ProgressPortion.UnitCount,
        _ totalUnitCount: ProgressPortion.UnitCount,
        _ fractionCompleted: Double
    ) async -> ()

    /// This closure will be executed when the progress's description is changed.
    public typealias DescriptionNotification = (
        _ localizedDescription: String,
        _ localizedAdditionalDescription: String
    ) async -> ()

    /**
     Corresponds to NSProgress's -discreteProgressWithTotalUnitCount:.

     - parameter totalUnitCount: The total unit count for this progress.

     - parameter granularity: Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     */
    public static func discreteProgress(
        totalUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async -> CSProgress {
        await self.init(totalUnitCount: totalUnitCount, parent: nil, pendingUnitCount: 0, granularity: granularity)
    }

    /**
     Corresponds to NSProgress's -initWithTotalUnitCount:parent:pendingUnitCount:.

     - parameter totalUnitCount: The total unit count for this progress.

     - parameter parent: The progress's parent. Can be nil.

     - parameter pendingUnitCount: The portion of the parent's totalUnitCount that this progress object represents. Pass zero for a nil parent.

     - parameter granularity: Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     */
    public convenience init(
        totalUnitCount: some BinaryInteger,
        parent: CSProgress?,
        pendingUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async {
        await self.init(
            backing: AsyncBacking(totalUnitCount: ProgressPortion.UnitCount(totalUnitCount)),
            parent: parent,
            pendingUnitCount: pendingUnitCount,
            granularity: granularity
        )
    }

    internal init(
        backing: AsyncBacking,
        parent: CSProgress?,
        pendingUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async {
        self.backing = backing
        self.parent = parent
        self.portionOfParent = ProgressPortion.UnitCount(pendingUnitCount)
        self.granularity = granularity

        await self.parent?.addChild(self, withPendingUnitCount: pendingUnitCount)
    }

    // The backing for this progress.
    // All calls to methods and properties on the backing should be protected by the isolator actor.
    internal let backing: AsyncBacking

    // The parent progress object.
    @ProgressIsolator
    private weak var parent: CSProgress?

    @ProgressIsolator
    private func setParent(_ parent: CSProgress?) {
        self.parent = parent
    }

    public var isFinished: Bool {
        get async { await self.backing.isCompleted }
    }

    /// The total number of units of work to be carried out.
    public var totalUnitCount: ProgressPortion.UnitCount {
        get async { await self.backing.totalUnitCount }
    }

    public func setTotalUnitCount(_ count: some BinaryInteger) async {
        @ProgressIsolator func set(_ count: some BinaryInteger) {
            let result = self.backing.setTotalUnitCount(ProgressPortion.UnitCount(count))

            self.sendFractionCompletedNotifications(
                fractionCompleted: result.fractionCompleted,
                isCompleted: result.isCompleted
            )
        }

        await set(count)
    }

    /// The number of units of work for the current job that have already been completed.
    public var completedUnitCount: ProgressPortion.UnitCount {
        get async { await self.backing.completedUnitCount }
    }

    public func setCompletedUnitCount(_ count: some BinaryInteger) async {
        @ProgressIsolator func set(_ count: some BinaryInteger) {
            let result = self.backing.setCompletedUnitCount(ProgressPortion.UnitCount(count))

            self.sendFractionCompletedNotifications(
                fractionCompleted: result.fractionCompleted,
                isCompleted: result.isCompleted
            )
        }

        await set(count)
    }

    /// Perform increment as one atomic operation, eliminating an unnecessary `await` and increasing performance.
    public func incrementCompletedUnitCount(by delta: some BinaryInteger) async {
        @ProgressIsolator func increment(_ delta: some BinaryInteger) {
            let result = self.backing.incrementCompletedUnitCount(by: ProgressPortion.UnitCount(delta))

            self.sendFractionCompletedNotifications(
                fractionCompleted: result.fractionCompleted,
                isCompleted: result.isCompleted
            )
        }

        await increment(delta)
    }

    // The portion of the parent's unit count represented by the progress object.
    @ProgressIsolator
    internal var portionOfParent: ProgressPortion.UnitCount

    /// The fraction of the overall work completed by this progress object, including work done by any children it may have.
    public var fractionCompleted: Double {
        get async {
            await self.backing.fractionCompleted
        }
    }

    //// Indicates whether the tracked progress is indeterminate.
    public var isIndeterminate: Bool {
        get async {
            await self.backing.isIndeterminate
        }
    }

    /// Indicates whether the receiver is tracking work that has been cancelled.
    public var isCancelled: Bool {
        get async {
            await self._isCancelled
        }
    }

    @ProgressIsolator
    private var _isCancelled: Bool {
        if let parent = self.parent, parent._isCancelled { return true }

        return self.backing.isCancelled
    }

    /// Cancel progress tracking.
    public func cancel() async {
        await Task { @ProgressIsolator in
            self.backing.cancel()
            self.sendCancellationNotifications()
        }.value
    }

    /// A localized description of progress tracked by the receiver.
    public var localizedDescription: String {
        get async { await self.backing.localizedDescription }
    }

    public func setLocalizedDescription(_ desc: String) async {
        await Task { @ProgressIsolator in
            self.backing.setLocalizedDescription(desc)
            self.sendDescriptionNotifications()
        }.value
    }

    /// A more specific localized description of progress tracked by the receiver.
    public var localizedAdditionalDescription: String {
        get async { await self.backing.localizedAdditionalDescription }
    }

    public func setLocalizedAdditionalDescription(_ desc: String) async {
        await Task { @ProgressIsolator in
            self.backing.setLocalizedAdditionalDescription(desc)
            self.sendDescriptionNotifications()
        }.value
    }

    /**
     Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
     This eliminates notifications that are too small to be noticeable, increasing performance.
     Default value is 0.01.
     */
    public let granularity: Double

    /**
     Create a reference to a parent progress, encapsulating both it and its pending unit count.
     This allows the child function to attach a new progress without knowing details about the parent progress and its unit count.
     */
    public func pass(pendingUnitCount: some BinaryInteger) -> ProgressPortion {
        ProgressPortion(progress: self, pendingUnitCount: ProgressPortion.UnitCount(pendingUnitCount))
    }

    /**
     Add a progress object as a child of a progress tree. The inUnitCount indicates the expected work for the progress unit.

     - parameter child: The CSProgress instance to add to the progress tree.

     - parameter pendingUnitCount: The number of units of work to be carried out by the new child.
     */
    public func addChild(_ child: CSProgress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async {
        await self.backing.addChild(child, pendingUnitCount: ProgressPortion.UnitCount(pendingUnitCount))
        await child.setParent(self)
    }

    public class NotificationID: Hashable {
        static public func ==(lhs: NotificationID, rhs: NotificationID) -> Bool { lhs === rhs }
        public func hash(into hasher: inout Hasher) { ObjectIdentifier(self).hash(into: &hasher) }
    }

    @ProgressIsolator private var cancellationNotifications: [NotificationID : CancellationNotification] = [:]
    @ProgressIsolator private var fractionCompletedNotifications: [NotificationID : FractionCompletedNotification] = [:]
    @ProgressIsolator private var descriptionNotifications: [NotificationID : DescriptionNotification] = [:]
    @ProgressIsolator private var lastNotifiedFractionCompleted: Double = 0.0

    @ProgressIsolator
    private func _addCancellationNotification(
        identifier: NotificationID,
        notification: @escaping CancellationNotification
    ) {
        self.cancellationNotifications[identifier] = notification

        if self._isCancelled {
            self.sendCancellationNotifications()
        }
    }

    @ProgressIsolator
    private func _removeCancellationNotification(identifier: NotificationID) {
        self.cancellationNotifications[identifier] = nil
    }

    @ProgressIsolator
    private func _addFractionCompletedNotification(
        identifier: NotificationID,
        notification: @escaping FractionCompletedNotification
    ) {
        self.fractionCompletedNotifications[identifier] = notification
    }

    @ProgressIsolator
    private func _removeFractionCompletedNotification(identifier: NotificationID) {
        self.fractionCompletedNotifications[identifier] = nil
    }

    @ProgressIsolator
    private func _addDescriptionNotification(
        identifier: NotificationID,
        notification: @escaping DescriptionNotification
    ) {
        self.descriptionNotifications[identifier] = notification
    }

    @ProgressIsolator
    private func _removeDescriptionNotification(identifier: NotificationID) {
        self.descriptionNotifications[identifier] = nil
    }


    /**
     Add a notification which will be called if the progress object is cancelled.

     - parameter queue: Specifies an operation queue on which the notification will be fired.
     The queue should either be a serial queue, or should have its maxConcurrentOperationCount set to something low
     to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.

     - parameter notification: A notification that will be called if the progress object is cancelled.

     - returns: An opaque value that can be passed to removeCancellationNotification() to de-register the notification.
     */
    @discardableResult
    public func addCancellationNotification(notification: @escaping CancellationNotification) async -> NotificationID {
        let id = NotificationID()

        await self._addCancellationNotification(identifier: id, notification: notification)

        return id
    }

    /**
     Remove a notification previously added via addCancellationNotification().

     - parameter identifier: The identifier previously returned by addCancellationNotification() for the notification you wish to remove.
     */
    public func removeCancellationNotification(identifier: NotificationID) async {
        await self._removeCancellationNotification(identifier: identifier)
    }

    /**
     Add a notification which will be called when the progress object's fractionCompleted property changes by an amount greater than the progress object's granularity.

     - parameter queue: Specifies an operation queue on which the notification will be fired.
     The queue should either be a serial queue, or should have its maxConcurrentOperationCount set to something low
     to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.

     - parameter notification: A notification that will be called when the fractionCompleted property is significantly changed.
     This notification will be called on the progress object's queue.

     - returns: An opaque value that can be passed to removeFractionCompletedNotification() to de-register the notification.
     */
    @discardableResult public func addFractionCompletedNotification(
        notification: @escaping FractionCompletedNotification
    ) async -> NotificationID {
        let id = NotificationID()

        await self._addFractionCompletedNotification(identifier: id, notification: notification)

        return id
    }

    /**
     Remove a notification previously added via addFractionCompletedNotification().

     - parameter identifier: The identifier previously returned by addFractionCompletedNotification() for the notification you wish to remove.
     */
    public func removeFractionCompletedNotification(identifier: NotificationID) async {
        await self._removeFractionCompletedNotification(identifier: identifier)
    }

    /**
     Add a notification which will be called when the progress object's localizedDescription or localizedAdditionalDescription property changes.

     - parameter queue: Specifies an operation queue on which the notification will be fired.
     The queue should either be a serial queue, or should have its maxConcurrentOperationCount set to something low
     to prevent excessive threads from being created.
     This parameter defaults to the main operation queue.

     - parameter notification: A notification that will be called when the fractionComplocalizedDescription or localizedAdditionalDescriptionleted property is changed.
     This notification will be called on the progress object's queue.

     - returns: An opaque value that can be passed to removeDescriptionNotification() to de-register the notification.
     */
    @discardableResult public func addDescriptionNotification(
        notification: @escaping DescriptionNotification
    ) -> NotificationID {
        let id = NotificationID()

        Task {
            await self._addDescriptionNotification(identifier: id, notification: notification)
        }

        return id
    }

    /**
     Remove a notification previously added via addDescriptionNotification().

     - parameter identifier: The identifier previously returned by addDescriptionNotification() for the notification you wish to remove.
     */
    public func removeDescriptionNotification(identifier: NotificationID) async {
        await self._removeDescriptionNotification(identifier: identifier)
    }

    // Fire our cancellation notifications.
    @ProgressIsolator
    private func sendCancellationNotifications() {
        let notifications = self.cancellationNotifications
        let children = self.backing.children

        Task {
            for (eachKey, eachNotification) in notifications {
                await eachNotification()
                self._removeCancellationNotification(identifier: eachKey)
            }
        }

        for eachChild in children {
            eachChild.sendCancellationNotifications()
        }
    }

    // Fire our fractionCompleted notifications.
    @ProgressIsolator
    private func sendFractionCompletedNotifications(fractionCompleted: Double, isCompleted: Bool) {
        let notifications = self.fractionCompletedNotifications.values
        let parent = self.parent

        if isCompleted, let parent = self.parent {
            parent.backing.removeChild(self)
            self.parent = nil

            let parentResult = parent.backing.incrementCompletedUnitCount(by: self.portionOfParent)

            self.sendFractionCompletedNotifications(fractionCompleted: fractionCompleted, isCompleted: isCompleted)

            parent.sendFractionCompletedNotifications(
                fractionCompleted: parentResult.fractionCompleted,
                isCompleted: parentResult.isCompleted
            )
        } else if abs(fractionCompleted - self.lastNotifiedFractionCompleted) >= self.granularity || isCompleted {
            let completedUnitCount = self.backing.completedUnitCount
            let totalUnitCount = self.backing.totalUnitCount

            for eachNotification in notifications {
                Task {
                    await eachNotification(completedUnitCount, totalUnitCount, fractionCompleted)
                }
            }

            self.lastNotifiedFractionCompleted = fractionCompleted

            if let parent {
                parent.sendFractionCompletedNotifications(
                    fractionCompleted: parent.backing.fractionCompleted,
                    isCompleted: parent.backing.isCompleted
                )
            }
        }
    }

    // Fire our description notifications.
    @ProgressIsolator
    private func sendDescriptionNotifications() {
        let description = self.backing.localizedDescription
        let additionalDescription = self.backing.localizedAdditionalDescription
        let notifications = self.descriptionNotifications.values

        for eachNotification in notifications {
            Task {
                await eachNotification(description, additionalDescription)
            }
        }
    }

    public var debugDescription: String {
        get async { await self._debugDescription }
    }

    @ProgressIsolator
    private var _debugDescription: String {
        let address = UInt(bitPattern: unsafeBitCast(self, to: UnsafeRawPointer.self))
        let parentAddress = self.parent.map { UInt(bitPattern: unsafeBitCast($0, to: UnsafeRawPointer.self)) }

        var desc = "<\(String(describing: type(of: self))) 0x\(String(address, radix: 16))>"

        desc += " : Parent: " + (parentAddress.map { "0x\(String($0, radix: 16))" } ?? "nil")
        desc += " / Fraction completed: \(self.backing.fractionCompleted)"
        desc += " / Completed: \(self.backing.completedUnitCount) of \(self.backing.totalUnitCount)"

        if self.parent != nil {
            desc += " (\(self.portionOfParent) of parent)"
        }

        desc += " \(self.backing.debugDescriptionSuffix)"

        for eachChild in self.backing.children {
            for eachLine in eachChild._debugDescription.split(separator: "\n") {
                desc += "\n\t\(eachLine)"
            }
        }

        return desc
    }
}
