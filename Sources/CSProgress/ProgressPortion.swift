//
//  ProgressPortion.swift
//
//  Created by Charles Srstka on 6/20/22.
//

/// Convenience struct for passing an `CSProgress` to a child function, encapsulating the parent progress and its pending unit count.
///
/// Create one of these by calling `pass()` on the parent progress.
public struct ProgressPortion {
    /// A numeric value representing an amount of work handled by a progress object.
    public typealias UnitCount = Int64

    internal enum ProgressType: Equatable {
        case async(CSProgress)
        case opaque(any OpaqueProgressType)

        static func == (lhs: ProgressPortion.ProgressType, rhs: ProgressPortion.ProgressType) -> Bool {
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

        func cancel() async {
            switch self {
            case .async(let progress):
                await progress.cancel()
            case .opaque(let progress):
                progress.cancel()
            }
        }

        var isCancelled: Bool {
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

    /// The default value for `granularity` when creating a new child progress object.
    ///
    /// By default, we update 100 times over the course of our progress.
    /// This should provide a decent user experience without compromising too much on performance.
    public static let defaultGranularity: Double = 0.01

    private let progressWrapper: ProgressWrapper

    internal var progress: ProgressType? { self.progressWrapper.progress }

    /// The amount of work units in the parent progress represented by this `ProgressPortion`.
    public let pendingUnitCount: UnitCount

    /// Create a new progress portion.
    ///
    /// - Parameters:
    ///   - progress: The parent progress.
    ///   - pendingUnitCount: The amount of work units in the parent progress represented by this portion.
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

    /// Marks the amount of work represented by this progress portion as complete.
    ///
    /// This can also be useful for error conditions where the operation should simply be skipped.
    /// Do not call `markComplete` after a child progress has already been made from this `ProgressPortion`.
    /// Doing so results in undefined behavior.
    public func markComplete() async {
        switch self.progress {
        case .none: break
        case .async(let progress):
            await progress.incrementCompletedUnitCount(by: self.pendingUnitCount)
        case .opaque(let progress):
            progress.completedUnitCount += UnitCount(self.pendingUnitCount)
        }
    }

    /// Convenience method to quickly cancel a progress.
    public func cancel() async { await self.progress?.cancel() }

    /// Convenience property to quickly check whether the parent progress has been cancelled.
    public var isCancelled: Bool {
        get async { await self.progress?.isCancelled ?? false }
    }
}
