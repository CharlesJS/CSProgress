//
//  Progress+OpaqueProgressType.swift
//  
//
//  Created by Charles Srstka on 10/23/22.
//

import Foundation
import CSProgress

extension Progress: OpaqueProgressType {
    public func addChild(_ child: CSProgress, withPendingUnitCount pendingUnitCount: some BinaryInteger) async {
        await child.addToParent(self, pendingUnitCount: pendingUnitCount)
    }
}
