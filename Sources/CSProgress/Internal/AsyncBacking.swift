//
//  AsyncBacking.swift
//
//
//  Created by Charles Srstka on 6/18/22.
//

@ProgressIsolator
internal final class AsyncBacking {
    private(set) var totalUnitCount: ProgressPortion.UnitCount
    private(set) var completedUnitCount: ProgressPortion.UnitCount = 0

    var isCompleted: Bool { self.completedUnitCount == self.totalUnitCount }

    var fractionCompleted: Double {
        if self.completedUnitCount >= self.totalUnitCount && self.completedUnitCount > 0 && self.totalUnitCount >= 0 {
            return 1.0
        }

        if self.totalUnitCount <= 0 {
            return 0.0
        }

        let myPortion = Double(max(self.completedUnitCount, 0))
        let childrenPortion = self.children.reduce(0) { $0 + $1.backing.fractionCompleted * Double($1.portionOfParent) }

        return (myPortion + childrenPortion) / Double(self.totalUnitCount)
    }

    private(set) var localizedDescription: String = ""
    private(set) var localizedAdditionalDescription: String = ""

    var isIndeterminate: Bool {
        self.totalUnitCount < 0 ||
        self.completedUnitCount < 0 ||
        (self.totalUnitCount == 0 && self.completedUnitCount == 0)
    }

    private(set) var isCancelled = false

    private(set) var children: [CSProgress] = []

    nonisolated init(totalUnitCount: ProgressPortion.UnitCount) {
        self.totalUnitCount = totalUnitCount
    }

    func setTotalUnitCount(_ totalUnitCount: ProgressPortion.UnitCount) -> (fractionCompleted: Double, isCompleted: Bool) {
        self.totalUnitCount = totalUnitCount
        return (fractionCompleted: self.fractionCompleted, isCompleted: self.isCompleted)
    }

    func setCompletedUnitCount(
        _ completedUnitCount: ProgressPortion.UnitCount
    ) -> (fractionCompleted: Double, isCompleted: Bool) {
        self.completedUnitCount = completedUnitCount
        return (fractionCompleted: self.fractionCompleted, isCompleted: self.isCompleted)
    }

    func incrementCompletedUnitCount(by delta: ProgressPortion.UnitCount) -> (fractionCompleted: Double, isCompleted: Bool) {
        self.completedUnitCount += delta
        return (fractionCompleted: self.fractionCompleted, isCompleted: self.isCompleted)
    }

    func setLocalizedDescription(_ desc: String) {
        self.localizedDescription = desc
    }

    func setLocalizedAdditionalDescription(_ desc: String) {
        self.localizedAdditionalDescription = desc
    }

    func cancel() {
        self.isCancelled = true
    }

    func addChild(_ child: CSProgress, pendingUnitCount: ProgressPortion.UnitCount) {
        if !self.children.contains(where: { $0 === child }) {
            self.children.append(child)
            child.portionOfParent = pendingUnitCount
        }
    }

    func removeChild(_ child: CSProgress) {
        self.children = self.children.filter { $0 !== child }
    }

    let debugDescriptionSuffix = "(async)"
}
