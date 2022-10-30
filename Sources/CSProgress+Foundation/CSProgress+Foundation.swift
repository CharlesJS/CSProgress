//
//  CSProgress+Foundation.swift
//  
//
//  Created by Charles Srstka on 10/23/22.
//

import Foundation
import CSProgress

extension CSProgress {
    public convenience init(
        totalUnitCount: some BinaryInteger,
        parent: Foundation.Progress,
        pendingUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async {
        await self.init(
            totalUnitCount: totalUnitCount,
            parent: nil,
            pendingUnitCount: pendingUnitCount,
            granularity: granularity
        )

        await self.addToParent(parent, pendingUnitCount: pendingUnitCount)
    }

    internal func addToParent(_ parent: Foundation.Progress, pendingUnitCount: some BinaryInteger) async {
        let ns = await self.makeWrapperProgress(
            parent: parent,
            pendingUnitCount: pendingUnitCount,
            fraction: await self.fractionCompleted
        )

        ns.cancellationHandler = { [weak self] in
            guard let self else { return }

            Task.detached {
                await self.cancel()
            }
        }

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
            guard let self else { return }

            await self.updateFractionCompleted(ns: ns, fraction: frac, isIndeterminate: self.isIndeterminate)

            if completed >= total {
                await removeNotifications()
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
        fraction: Double
    ) -> Foundation.Progress {
        let progress = Foundation.Progress(totalUnitCount: 100, parent: parent, pendingUnitCount: Int64(pendingUnitCount))

        progress.completedUnitCount = Int64((fraction * 100.0).rounded())

        return progress
    }

    @MainActor private func updateFractionCompleted(ns: Foundation.Progress?, fraction: Double, isIndeterminate: Bool) {
        guard let ns else { return }

        if isIndeterminate {
            ns.completedUnitCount = -1
        } else {
            ns.completedUnitCount = Int64((fraction * 100.0).rounded())
        }
    }

    @MainActor private func updateDescription(
        ns: Foundation.Progress?,
        description: String,
        additionalDescription: String
    ) {
        guard let ns else { return }

        ns.localizedDescription = description
        ns.localizedAdditionalDescription = additionalDescription
    }

    @MainActor private func updateCancellation(ns: Foundation.Progress?) {
        ns?.cancel()
    }
}
