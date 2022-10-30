//
//  OpaqueProgressType.swift
//  
//
//  Created by Charles Srstka on 10/23/22.
//

public protocol OpaqueProgressType: AnyObject, Equatable {
    var isCancelled: Bool { get }
    func cancel()

    var completedUnitCount: ProgressPortion.UnitCount { get set }

    func addChild(_ child: CSProgress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async

    func pass(pendingUnitCount: some BinaryInteger) -> ProgressPortion
}

public extension OpaqueProgressType {
    func pass(pendingUnitCount: some BinaryInteger) -> ProgressPortion {
        ProgressPortion(opaqueProgress: self, pendingUnitCount: pendingUnitCount)
    }
}
