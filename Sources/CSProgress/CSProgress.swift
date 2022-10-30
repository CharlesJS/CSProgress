//
//  CSProgress.swift
//
//  Created by Charles Srstka on 1/10/2016.
//  Copyright © 2016-2022 Charles Srstka. All rights reserved.
//

/// An object that conveys ongoing progress to the user for a specified task.
///
/// Similar to Foundation's `Progress` class, but much more performant.
/// `CSProgress` is designed with concurrency in mind, and is implemented around actors and `async`/`await` rather than locks or semaphores.
public final class CSProgress {
    // Notification types.

    /// A closure that will be executed if the progress is cancelled.
    public typealias CancellationNotification = () async -> ()

    /// A closure that will be executed whenever the change in `fractionCompleted` exceeds the progress's `granularity`.
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

    /// Creates and returns a progress instance with the specified unit count that isn't part of any existing progress tree.
    ///
    /// - Parameters:
    ///   - totalUnitCount: The total unit count for this progress.
    ///   - granularity: Specifies the amount of change that should occur to the progress's `fractionCompleted` property before its
    ///     notifications are fired.
    ///     A notification will be sent whenever the difference between the current value of `fractionCompleted` and the value at the last time a notification
    ///     was sent exceeds the granularity.
    ///     This eliminates notifications that are too small to be noticeable, increasing performance.
    ///     Default value is 0.01.
    /// - Returns: A new progress instance.
    public static func discreteProgress(
        totalUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async -> CSProgress {
        await self.init(totalUnitCount: totalUnitCount, parent: nil, pendingUnitCount: 0, granularity: granularity)
    }

    /// Creates a progress instance for the specified progress object with a unit count that's a portion of the containing object's total unit count.
    ///
    /// - Parameters:
    ///   - totalUnitCount: The total unit count for this progress.
    ///   - parent: The progress's parent. Can be nil.
    ///   - pendingUnitCount: The portion of the parent's `totalUnitCount` that this progress object represents. Pass zero for a `nil` parent.
    ///   - granularity: Specifies the amount of change that should occur to the progress's `fractionCompleted` property before its
    ///     notifications are fired.
    ///     A notification will be sent whenever the difference between the current value of `fractionCompleted` and the value at the last time a notification
    ///     was sent exceeds the granularity.
    ///     This eliminates notifications that are too small to be noticeable, increasing performance.
    ///     Default value is 0.01.
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
    internal weak var parent: CSProgress?

    @ProgressIsolator
    private func setParent(_ parent: CSProgress?) {
        self.parent = parent
    }

    /// A Boolean value that indicates whether the progress object is complete.
    public var isFinished: Bool {
        get async { await self.backing.isCompleted }
    }

    /// The total number of units of work to be carried out.
    public var totalUnitCount: ProgressPortion.UnitCount {
        get async { await self.backing.totalUnitCount }
    }

    /// Sets the total number of units of work to be carried out.
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

    /// Sets the number of units of work for the current job that have already been completed.
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

    /// Increment the completed unit count as one atomic operation, eliminating an unnecessary `await` and increasing performance.
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

    /// Set the localized description of progress tracked by the receiver.
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

    /// Set the more specific localized description of progress tracked by the receiver.
    public func setLocalizedAdditionalDescription(_ desc: String) async {
        await Task { @ProgressIsolator in
            self.backing.setLocalizedAdditionalDescription(desc)
            self.sendDescriptionNotifications()
        }.value
    }

    /// Specifies the amount of change that should occur to the progress's fractionCompleted property before its notifications are fired.
    ///
    /// This eliminates notifications that are too small to be noticeable, increasing performance.
    /// Default value is 0.01.
    public let granularity: Double

    /// Create a reference to a parent progress, encapsulating both it and its pending unit count.
    ///
    /// This allows the child function to attach a new progress without knowing details about the parent progress and its unit count.
    ///
    /// - Parameter pendingUnitCount: The portion of the parent's `totalUnitCount` that this progress object represents. Pass zero for a `nil` parent.
    /// - Returns: A reference to the portion of the progress represented by `pendingUnitCount`, which can be passed to a child function.
    public func pass(pendingUnitCount: some BinaryInteger) -> ProgressPortion {
        ProgressPortion(progress: self, pendingUnitCount: ProgressPortion.UnitCount(pendingUnitCount))
    }

    /// Add a progress object as a child of a progress tree.
    ///
    /// - Parameters:
    ///   - child: The CSProgress instance to add to the progress tree.
    ///   - pendingUnitCount: The number of units of work to be carried out by the new child.
    public func addChild(_ child: CSProgress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async {
        await self.backing.addChild(child, pendingUnitCount: ProgressPortion.UnitCount(pendingUnitCount))
        await child.setParent(self)
    }

    /// An identifier for a notification.
    ///
    /// You can pass this object to `CSProgress`'s `remove*Notification()` methods to disable the notification.
    public class NotificationID: Hashable {
        /// Returns a Boolean value indicating whether two notification IDs are equal.
        static public func == (lhs: NotificationID, rhs: NotificationID) -> Bool { lhs === rhs }
        /// Hashes the essential components of this value by feeding them into the given hasher.
        public func hash(into hasher: inout Hasher) { ObjectIdentifier(self).hash(into: &hasher) }
    }

    /// Add a notification which will be called if the progress object is cancelled.
    ///
    /// - Parameters:
    ///   - priority: An optional value that specifies the task priority at which notifications will be fired.
    ///   - notification: A notification that will be called if the progress object is cancelled.
    ///
    /// - Returns: An identifier that can be passed to `removeCancellationNotification()` to disable the notification.
    @discardableResult
    public func addCancellationNotification(
        priority: TaskPriority? = nil,
        notification: @escaping CancellationNotification
    ) async -> NotificationID {
        let id = NotificationID()

        await self._addCancellationNotification(identifier: id, priority: priority, notification: notification)

        return id
    }

    /// Remove a notification previously added via `addCancellationNotification()`.
    ///
    /// - Parameter identifier: The identifier previously returned by `addCancellationNotification()` for the notification you wish to remove.
    public func removeCancellationNotification(identifier: NotificationID) async {
        await self._removeCancellationNotification(identifier: identifier)
    }

    /// Add a notification which will be called when the progress object's `fractionCompleted` property changes by an amount greater than the
    /// progress object's `granularity`.
    ///
    /// - Parameters:
    ///   - priority: An optional value that specifies the task priority at which notifications will be fired.
    ///   - notification: A notification that will be called when the `fractionCompleted` property is significantly changed.
    ///
    /// - Returns: An identifier that can be passed to `removeFractionCompletedNotification()` to disable the notification.
    @discardableResult public func addFractionCompletedNotification(
        priority: TaskPriority? = nil,
        notification: @escaping FractionCompletedNotification
    ) async -> NotificationID {
        let id = NotificationID()

        await self._addFractionCompletedNotification(identifier: id, priority: priority, notification: notification)

        return id
    }

    /// Remove a notification previously added via `addFractionCompletedNotification()`.
    ///
    /// - Parameter identifier: The identifier previously returned by `addFractionCompletedNotification()` for the notification you wish to remove.
    public func removeFractionCompletedNotification(identifier: NotificationID) async {
        await self._removeFractionCompletedNotification(identifier: identifier)
    }

    /// Add a notification which will be called when the progress object's `localizedDescription` or `localizedAdditionalDescription` property changes.
    ///
    /// - Parameters:
    ///   - priority: An optional value that specifies the task priority at which notifications will be fired.
    ///   - notification: A notification that will be called when the `localizedDescription` or `localizedAdditionalDescriptionleted`
    ///    property is changed.
    ///
    /// - Returns: An identifier that can be passed to `removeDescriptionNotification()` to disable the notification.
    @discardableResult public func addDescriptionNotification(
        priority: TaskPriority? = nil,
        notification: @escaping DescriptionNotification
    ) -> NotificationID {
        let id = NotificationID()

        Task {
            await self._addDescriptionNotification(identifier: id, priority: priority, notification: notification)
        }

        return id
    }

    /// Remove a notification previously added via `addDescriptionNotification()`.
    ///
    /// - Parameter identifier: The identifier previously returned by `addDescriptionNotification()` for the notification you wish to remove.
    public func removeDescriptionNotification(identifier: NotificationID) async {
        await self._removeDescriptionNotification(identifier: identifier)
    }

    private enum NotificationType {
        case cancellation
        case fractionCompleted
        case description
    }

    private var cancellationNotifications: [NotificationID: NotificationStream<Void>] = [:]
    private var descriptionNotifications: [NotificationID: NotificationStream<(String, String)>] = [:]
    private var fractionCompletedNotifications:
        [NotificationID: NotificationStream<(ProgressPortion.UnitCount, ProgressPortion.UnitCount, Double)>] = [:]

    @ProgressIsolator private var lastNotifiedFractionCompleted: Double = 0.0

    @ProgressIsolator
    private func _addCancellationNotification(
        identifier: NotificationID,
        priority: TaskPriority?,
        notification: @escaping CancellationNotification
    ) {
        let stream = NotificationStream<Void>(priority: priority) { [weak self] in
            await notification()
            await self?.removeCancellationNotification(identifier: identifier)
        }

        stream.start()

        self.cancellationNotifications[identifier] = stream

        if self._isCancelled {
            self.sendCancellationNotifications()
        }
    }

    @ProgressIsolator
    private func _removeCancellationNotification(identifier: NotificationID) {
        self.cancellationNotifications[identifier]?.stop()
        self.cancellationNotifications[identifier] = nil
    }

    @ProgressIsolator
    private func _addFractionCompletedNotification(
        identifier: NotificationID,
        priority: TaskPriority?,
        notification: @escaping FractionCompletedNotification
    ) {
        let stream = NotificationStream<(ProgressPortion.UnitCount, ProgressPortion.UnitCount, Double)>(priority: priority) {
            await notification($0.0, $0.1, $0.2)
        }

        stream.start()

        self.fractionCompletedNotifications[identifier] = stream
    }

    @ProgressIsolator
    private func _removeFractionCompletedNotification(identifier: NotificationID) {
        self.fractionCompletedNotifications[identifier]?.stop()
        self.fractionCompletedNotifications[identifier] = nil
    }

    @ProgressIsolator
    private func _addDescriptionNotification(
        identifier: NotificationID,
        priority: TaskPriority?,
        notification: @escaping DescriptionNotification
    ) {
        let stream = NotificationStream<(String, String)>(priority: priority) {
            await notification($0.0, $0.1)
        }

        stream.start()

        self.descriptionNotifications[identifier] = stream
    }

    @ProgressIsolator
    private func _removeDescriptionNotification(identifier: NotificationID) {
        self.descriptionNotifications[identifier]?.stop()
        self.descriptionNotifications[identifier] = nil
    }

    // Fire our cancellation notifications.
    @ProgressIsolator
    private func sendCancellationNotifications() {
        let children = self.backing.children

        for eachStream in self.cancellationNotifications.values {
            eachStream.send(())
        }

        for eachChild in children {
            eachChild.sendCancellationNotifications()
        }
    }

    // Fire our fractionCompleted notifications.
    @ProgressIsolator
    private func sendFractionCompletedNotifications(fractionCompleted: Double, isCompleted: Bool) {
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

            for eachStream in self.fractionCompletedNotifications.values {
                eachStream.send((completedUnitCount, totalUnitCount, fractionCompleted))
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

        for eachStream in self.descriptionNotifications.values {
            eachStream.send((description, additionalDescription))
        }
    }

    /// A textual description of the progress, suitable for debugging.
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
