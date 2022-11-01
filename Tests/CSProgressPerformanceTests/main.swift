//
//  main.swift
//
//
//  Created by Charles Srstka on 10/24/22.
//

#if canImport(Darwin)
await testNSProgresses()
await testNSProgressesWithAutoreleasePool()
await testNSProgressesWithObserver()
await testNSProgressesWithObserverAndAutoreleasePool()
#endif
await testCSProgresses()
await testCSProgressesWithObserver()
#if canImport(Darwin)
await testCSProgressesRootedWithObservingNSProgress()
#endif
await testCSProgressesUsedSynchronously()
