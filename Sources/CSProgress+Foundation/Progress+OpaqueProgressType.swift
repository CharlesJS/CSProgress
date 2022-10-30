//
//  Progress+OpaqueProgressType.swift
//
//
//  Created by Charles Srstka on 10/23/22.
//

import Foundation
import CSProgress

extension Progress: OpaqueProgressType {
    /// Adds a `CSProgress` object as a child of this progress instance.
    ///
    /// All notifications resulting from changes in the child `CSProgress` will be sent on the main thread.
    ///
    /// - Parameters:
    ///   - child: A `CSProgress` instance to add as a child to the progress tree.
    ///   - pendingUnitCount: The number of units of work for the new suboperation to complete.
    public func addChild(_ child: CSProgress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async {
        await child.addToParent(self, withPendingUnitCount: pendingUnitCount)
    }
}
