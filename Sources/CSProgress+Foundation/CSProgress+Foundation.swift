//
//  CSProgress+Foundation.swift
//
//
//  Created by Charles Srstka on 10/23/22.
//

import Foundation
import CSProgress

extension CSProgress {
    /// Creates a progress instance for the specified `Foundation.Progress` object with a unit count that's a portion of the containing object's total unit count.
    ///
    /// This is useful for integrating `CSProgress` into existing `Foundation.Progress` trees without requiring the entire tree to be refactored.
    /// All notifications for the parent `Foundation.Progress` object are sent on the main thread.
    ///
    /// - Parameters:
    ///   - totalUnitCount: The total number of units of work to assign to the progress instance.
    ///   - parent: The containing `Foundation.Progress` object for the created `CSProgress` object.
    ///   - pendingUnitCount: The unit count for the progress object.
    ///   - granularity: Determines the frequency with which `fractionCompleted` notifications are sent.
    ///     A notification will be sent whenever the difference between the current value of `fractionCompleted`
    ///     and the value at the last time a notification was sent exceeds the granularity.
    public convenience init(
        totalUnitCount: some BinaryInteger,
        parent: Foundation.Progress,
        pendingUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async {
        await self.init(totalUnitCount: totalUnitCount, parent: nil, pendingUnitCount: 0, granularity: granularity)
        await self.addToParent(parent, withPendingUnitCount: pendingUnitCount)
    }

    /// Creates a progress instance wrapping a `Foundation.Progress` object.
    ///
    /// All changes to this object will result in corresponding changes being made to the `Foundation.Progress` object.
    /// All changes, as well as any subsequent KVO notifications that the `Foundation.Progress` object sends, will occur on the main thread.
    /// This binding is not two-way; the `Foundation.Progress` object that this wraps should be considered as owned by the wrapping `CSProgress` object.
    /// After this binding is created, any manual changes to the `Foundation.Progress` object will be overwritten by the `CSProgress` object.
    ///
    /// - Parameters:
    ///   - ns: The `Foundation.Progress` object to be wrapped.
    ///   - granularity: Determines the frequency with which `fractionCompleted` notifications are sent.
    ///     A notification will be sent whenever the difference between the current value of `fractionCompleted`
    ///     and the value at the last time a notification was sent exceeds the granularity.
    public convenience init(
        wrapping ns: Foundation.Progress,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async {
        await self.init(totalUnitCount: 0, parent: nil, pendingUnitCount: 0, granularity: granularity)

        await self.setUpWrapper(ns)
    }

    internal func addToParent(_ ns: Foundation.Progress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async {
        let ns = await self.makeWrapperProgress(
            parent: ns,
            pendingUnitCount: pendingUnitCount,
            totalUnitCount: self.totalUnitCount,
            completedUnitCount: self.completedUnitCount
        )

        await self.setUpWrapper(ns)
    }

    private func setUpWrapper(_ ns: Foundation.Progress) async {
        await self.setWrappedProperties(ns: ns)
        await self.setUpWrapperNotifications(ns: ns)

        ns.cancellationHandler = { [weak self] in
            if let self {
                Task.detached {
                    await self.cancel()
                }
            }
        }
    }

    private func setWrappedProperties(ns: Foundation.Progress) async {
        let (total, completed, desc, additionalDesc, isCancelled) = await MainActor.run {
            (
                ns.totalUnitCount,
                ns.completedUnitCount,
                ns.localizedDescription,
                ns.localizedAdditionalDescription,
                ns.isCancelled
            )
        }

        await self.setTotalUnitCount(total)
        await self.setCompletedUnitCount(completed)

        if let desc {
            await self.setLocalizedDescription(desc)
        }

        if let additionalDesc {
            await self.setLocalizedAdditionalDescription(additionalDesc)
        }

        if isCancelled {
            await self.cancel()
        }
    }

    private func setUpWrapperNotifications(ns: Foundation.Progress) async {
        var fractionNotification: CSProgress.NotificationID? = nil
        var descriptionNotification: CSProgress.NotificationID? = nil
        var cancelNotification: CSProgress.NotificationID? = nil

        let removeNotifications = { [weak self] () async -> Void in
            if let notification = fractionNotification {
                await self?.removeFractionCompletedNotification(identifier: notification)
                fractionNotification = nil
            }

            if let notification = descriptionNotification {
                await self?.removeDescriptionNotification(identifier: notification)
                descriptionNotification = nil
            }

            if let notification = cancelNotification {
                await self?.removeCancellationNotification(identifier: notification)
                cancelNotification = nil
            }
        }

        fractionNotification = await self.addFractionCompletedNotification { [weak self, weak ns] completed, total, frac in
            if let self {
                await self.updateUnitCounts(ns: ns, fraction: frac)

                if completed >= total {
                    await removeNotifications()
                }
            }
        }

        descriptionNotification = self.addDescriptionNotification { [weak self, weak ns] desc, additionalDesc in
            await self?.updateDescription(ns: ns, description: desc, additionalDescription: additionalDesc)
        }

        cancelNotification = await self.addCancellationNotification { [weak self, weak ns] in
            await self?.updateCancellation(ns: ns)
            await removeNotifications()
        }
    }

    @MainActor private func makeWrapperProgress(
        parent: Foundation.Progress,
        pendingUnitCount: some BinaryInteger,
        totalUnitCount: some BinaryInteger,
        completedUnitCount: some BinaryInteger
    ) -> Foundation.Progress {
        let progress = Foundation.Progress(
            totalUnitCount: Int64(totalUnitCount),
            parent: parent,
            pendingUnitCount: Int64(pendingUnitCount)
        )

        progress.completedUnitCount = Int64(completedUnitCount)

        return progress
    }

    @MainActor private func updateUnitCounts(ns: Foundation.Progress?, fraction: Double) {
        if let ns {
            ns.totalUnitCount = 1000
            ns.completedUnitCount = Int64((fraction * 1000.0).rounded())
        }
    }

    @MainActor private func updateDescription(
        ns: Foundation.Progress?,
        description: String,
        additionalDescription: String
    ) {
#if canImport(Darwin)
        // These properties are not yet implemented in swift-corelibs-foundation as of this writing
        if let ns {
            ns.localizedDescription = description
            ns.localizedAdditionalDescription = additionalDescription
        }
#endif
    }

    @MainActor private func updateCancellation(ns: Foundation.Progress?) {
        if let ns, !ns.isCancelled {
            ns.cancel()
        }
    }
}
