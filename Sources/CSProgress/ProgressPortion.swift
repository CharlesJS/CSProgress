//
//  ProgressPortion.swift
//
//  Created by Charles Srstka on 6/20/22.
//

/// Convenience struct for passing an `CSProgress` to a child function, encapsulating the parent progress and its pending unit count.
/// Create one of these by calling .pass() on the parent progress.
public struct ProgressPortion {
    // Declare our own unit count type instead of hard-coding it to Int64, for future flexibility.
    public typealias UnitCount = Int64

    internal enum ProgressType: Equatable {
        case async(CSProgress)
        case opaque(any OpaqueProgressType)

        public static func == (lhs: ProgressPortion.ProgressType, rhs: ProgressPortion.ProgressType) -> Bool {
            switch lhs {
            case .async(let progress1):
                switch rhs {
                case .async(let progress2):
                    return progress1 === progress2
                default:
                    return false
                }
            case .opaque(let progress1):
                switch rhs {
                case .opaque(let progress2):
                    return progress1 === progress2
                default:
                    return false
                }
            }
        }

        public func cancel() async {
            switch self {
            case .async(let progress):
                await progress.cancel()
            case .opaque(let progress):
                progress.cancel()
            }
        }

        public var isCancelled: Bool {
            get async {
                switch self {
                case .async(let progress):
                    return await progress.isCancelled
                case .opaque(let progress):
                    return progress.isCancelled
                }
            }
        }
    }

    private enum ProgressWrapper {
        struct AsyncWrapper {
            weak var progress: CSProgress?
        }

        struct OpaqueWrapper {
            weak var progress: (any OpaqueProgressType)?
        }

        case async(AsyncWrapper)
        case opaque(OpaqueWrapper)

        var progress: ProgressType? {
            switch self {
            case .async(let wrapper):
                return wrapper.progress.map { .async($0) }
            case .opaque(let wrapper):
                return wrapper.progress.map { .opaque($0) }
            }
        }
    }

    // By default, we'll update 100 times over the course of our progress. This should provide a decent user experience
    // without compromising too much on performance.
    public static let defaultGranularity: Double = 0.01

    private let progressWrapper: ProgressWrapper

    internal var progress: ProgressType? { self.progressWrapper.progress }
    public let pendingUnitCount: UnitCount

    public init(progress: CSProgress, pendingUnitCount: some BinaryInteger) {
        self.progressWrapper = .async(.init(progress: progress))
        self.pendingUnitCount = UnitCount(pendingUnitCount)
    }

    internal init(opaqueProgress: any OpaqueProgressType, pendingUnitCount: some BinaryInteger) {
        self.progressWrapper = .opaque(.init(progress: opaqueProgress))
        self.pendingUnitCount = UnitCount(pendingUnitCount)
    }

    /// Creates a child `CSProgress` object.
    ///
    /// - Parameters:
    ///   - totalUnitCount: The total unit count for the newly created `CSProgress`.
    ///   - granularity: Specifies the amount of change that should occur to the child progress's `fractionCompleted` property before its
    ///     notifications are fired.
    ///     A notification will be sent whenever the difference between the current value of `fractionCompleted` and the value at the last time a notification
    ///     was sent exceeds the granularity.
    ///     This eliminates notifications that are too small to be noticeable, increasing performance.
    ///     Default value is 0.01.
    ///
    /// - Returns: A new child progress, which will be attached to the parent progress with the pending unit count that was specified when this struct was created.
    public func makeChild(
        totalUnitCount: some BinaryInteger,
        granularity: Double = ProgressPortion.defaultGranularity
    ) async -> CSProgress {
        switch self.progress {
        case .none:
            return await CSProgress(
                totalUnitCount: totalUnitCount,
                parent: nil,
                pendingUnitCount: 0,
                granularity: granularity
            )
        case .async(let progress):
            let pendingUnitCount = self.pendingUnitCount

            return await CSProgress(
                totalUnitCount: totalUnitCount,
                parent: progress,
                pendingUnitCount: pendingUnitCount,
                granularity: granularity
            )
        case .opaque(let progress):
            let child = await CSProgress(
                totalUnitCount: totalUnitCount,
                parent: nil,
                pendingUnitCount: 0,
                granularity: granularity
            )

            await progress.addChild(child, withPendingUnitCount: pendingUnitCount)

            return child
        }
    }

    /// For the case where the child operation is atomic, just mark the pending units as complete rather than
    /// going to the trouble of creating a child progress.
    /// Can also be useful for error conditions where the operation should simply be skipped.
    /// Calling `markComplete` after a child progress has already been made from this `ProgressPortion` results in undefined behavior.
    public func markComplete() async {
        switch self.progress {
        case .none: break
        case .async(let progress):
            await progress.incrementCompletedUnitCount(by: self.pendingUnitCount)
        case .opaque(let progress):
            progress.completedUnitCount += UnitCount(self.pendingUnitCount)
        }
    }

    /// Convenience methods to quickly cancel a progress, and check whether the progress is cancelled
    public func cancel() async { await self.progress?.cancel() }
    public var isCancelled: Bool {
        get async { await self.progress?.isCancelled ?? false }
    }
}
