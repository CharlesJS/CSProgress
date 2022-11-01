# CSProgress
(**Note:** `CSProgress` 2.0 contains source-breaking changes. If you are looking for the older, synchronous version of `CSProgress` using semaphores, please take a look at the 1.x releases in this repository.)

## Introduction

`NSProgress` (renamed to `Progress` in Swift 3) is a Foundation class introduced in Mac OS X 10.9 (“Mavericks”), intended to simplify progress reporting in Mac and iOS applications.
The concept it introduces is great, creating a tree of progress objects, all of which represent a small part of the work to be done and can be confined to that particular section of the code, reducing the amount of spaghetti needed to represent progress in a complex system.
Unfortunately, the performance leaves a lot to be desired, and because of its heavy usage of locks, it's not well-suited to the new world of Swift Concurrency.

For several years, `CSProgress` has been my answer to `Progress`’s shortcomings, and for version 2.0, it’s being rewritten around Swift’s new concurrency features, using actors for synchronization instead of locks or semaphores.

`CSProgress` supports the following features:

* Fully Swift-native
* Completely implemented using Swift Concurrency—no locks or semaphores are used.
* Does *not* require linking against Foundation
    * Although if you _do_ use Foundation, it also includes an optional `CSProgress+Foundation` library with some extensions that allow `CSProgress` to integrate into Foundation progress trees
* Focused on performance, so that it won’t slow down your worker tasks
* Fully blocks/closures-based interface for observing changes
* Multiple closure-based observers can be created for the same property for any given `CSProgress`
* Customizable granularity, allowing notifications to be sent when the `fractionCompleted` property changes by a certain amount, rather than every time `completedUnitCount` is updated
* Sends all notifications in a separate task, keeping your worker tasks free to do their work unencumbered
* For apps linking against the Foundation framework, it includes the ability to wrap Foundation `Progress` objects, allowing it to be integrated into Foundation progress trees. When a value changes on a `CSProgress` that is wrapping a Foundation `Progress`, the `Progress` will be updated as well. All updates to Foundation `Progress` objects occur on the main actor, allowing the wrapped `Progress` to be directly bound to UI elements without any worries of Main Thread Checker violations. This also has the effect of preventing `Progress`'s KVO notifications from slowing down work on your worker tasks.
* Supports incrementing the `completedUnitCount` as an atomic operation, rather than needing two operations to read the old value and then set the new one, preventing race conditions.
* Uses generics to support all integer types as arguments, rather than only `Int64`
* Adds a `ProgressPortion` wrapper struct which encapsulates a parent progress object and its pending unit count. This struct can be passed to child tasks in order to build progress trees explicitly while still enjoying the loose coupling of the implicit composition method.
* Much better performance than Foundation's `Progress`. `CSProgress` includes a performance test app, which increments each progress object in a tree consisting of a root node and four child nodes from 0 to 1,000,000 each. On my 2019 Core i9 MacBook Pro (I don’t yet have an Apple Silicon Mac to test on), this is its output:
```
$ swift run -c release CSProgressPerformanceTests
Building for production...
Build complete! (0.18s)
NSProgress: Completed in 7.1407119035720825 seconds
NSProgress with Autorelease Pool: Completed in 7.642346978187561 seconds
NSProgress with observer: Completed in 34.34052503108978 seconds
NSProgress with observer and autorelease pool: Completed in 34.64492905139923 seconds
CSProgress: Completed in 1.3364520072937012 seconds
CSProgress with observer: Completed in 1.4522058963775635 seconds
CSProgresses rooted with observing NSProgress: Completed in 1.1003750562667847 seconds
CSProgress with observer, used from synchronous code: Completed in 12.279047966003418 seconds
```
 
 As you can see, having an observer has a very small effect on performance compared to `Foundation.Progress`. As a result, when observers are involved, `CSProgress` performs about twice an order of magnitude better than `Foundation.Progress` on my machine.
 However, as we can see, `CSProgress` does not perform as well in synchronous contexts (although it's still faster than `Foundation.Progress`).
 If your application has not yet adopted Swift Concurrency, you may be better off sticking with the older version 1.1.1 of `CSProgress`.
 
To make it easy to build progress trees, `CSProgress` also includes a convenience struct for encapsulating a parent progress object and its pending unit count, allowing both to be passed as one argument:

```Swift
func foo(progressPortion: Progressportion) async {
  let progress = await progressPortion.makeChild(totalUnitCount: 10)
  
  ... do something ...
}

let rootProgress = await CSProgress(totalUnitCount: 10, parent: nil, pendingUnitCount: 0)

await foo(progressPortion: rootProgress.pass(pendingUnitCount: 5))
```

# What’s *not* supported in this version:
* `CSProgress` no longer attempts to be a drop-in replacement for `Foundation.Progress`. This would be impossible to do, because async methods have distinct differences in syntax from synchronous methods. Also, `Foundation.Progress`’s interface relies a lot on implicit tree composition using thread-local storage, which neither seems safe nor makes much sense in the new world of Swift Concurrency. So converting `Progress` (or `CSProgress` 1.x)-based code to `CSProgress` _will_ require some code changes, although personally I think the benefits are worth it.
* In this version, the bindings to `Foundation.Progress` are no longer two-way. Changes on the `CSProgress` side will propagate to the `Foundation.Progress` side, but not vice versa. This is mostly because in the last few years, I’ve found myself not having much use for the latter. I _could_ add this support back in a later version if there is demand for it, so please feel free to open an issue on GitHub Issues if you have a use case for this.
* As in version 1.x, a few other `Foundation.Progress` features are not supported:
  * Pause and resume
  * Publish and subscribe
  * Arbitrary user info dictionaries
* As with the two-way bindings, this is mostly because I never really have a use for these. If you do, please open an issue with your use case.

***
# Wait, I just came here to read the rant about `NSProgress` from 2017!

Oh! Well, okay, here you go:

### NSProgress’s Performance is Terrible

Unfortunately, the performance of NSProgress is simply *terrible.* 
While performance is not a major concern for many Cocoa classes, the purpose of NSProgress—tracking progress for operations that take a long time—naturally lends itself to being used in performance-critical code.
The slower NSProgress is, the more likely it is that it will affect running times for operations that are already long-running enough to need progress reporting. 
In Apple’s ["Best Practices in Progress Reporting"](https://developer.apple.com/videos/play/wwdc2015/232/) video from 2015, Apple recommends not updating NSProgress in a tight loop, because of the effects that will have on performance. 
Unfortunately, this best-practice effectively results in polluting the back-end with UI code, adversely affecting the separation of concerns. 

There are a number of things that contribute to the sluggishness of NSProgress:

#### Objective-C

This aspect can’t really be helped, since NSProgress was invented at a time when Objective-C was the only mainstream language used to develop Apple’s high-level APIs.
However, the fact that NSProgress is Objective-C-based means that every time it is updated, we will get invocations of objc_msgSend. This can be worked around using IMP caching, though, so it’s not that big a deal, right?
Well, unfortunately, there’s more.

#### KVO

This is the big one.
Every an NSProgress object is updated, it posts KVO notifications.
KVO is [well known to have terrible performance characteristics](http://blog.metaobject.com/2014/03/the-siren-call-of-kvo-and-cocoa-bindings.html). 
And every time you update the change count on an NSProgress object, KVO notifications will be sent not only for that progress object, but also its parent, its grandparent, and so on all the way back up to the root of the tree. 
Furthermore, these notifications are all sent on the current thread, so your worker will need to wait for all the notifications to finish before it can continue getting on with what it was doing. 
This can significantly bog things down.

#### NSLock

NSProgress is thread-safe, which is great! 
Unfortunately this is implemented using NSLock, a simple wrapper around pthread mutexes [which adds a great deal of overhead](http://perpendiculo.us/2009/09/synchronized-nslock-pthread-osspinlock-showdown-done-right/).
Furthermore, there’s no atomic way to increment the change count. 
To do so, one first has to get the current completedUnitCount, then add something to it, and then finally send that back to completedUnitCount’s setter, resulting in the lock being taken twice for one operation.
In addition to being inferior performance-wise, this also introduces a race condition, since something else running on another thread can conceivably change the completedUnitCount property in between the read and the write, causing the unit count to become incorrect.

#### It’s a Memory Hog

In the process of updating its change count and sending out its KVO notifications, NSProgress generates a lot of autoreleased objects.
In my performance testing, updating an NSProgress one million times causes the app to bloat to a memory size of 4.8 GB (!). 
This can, of course, be alleviated by wrapping the whole thing in an autorelease pool, but this tends to slow down performance even further.

All these performance caveats at least lead to a nice, silky-smooth interface, though, right? Well, no.

### NSProgress’s Interface is Terrible

_\[Note: Since this was written, the Swift 4 observation syntax was released, which alleviates many of the interface concerns that I had here. The other complaints still hold, though.\]_

All of NSProgress’s reporting is done via KVO. 
That’s slick, right? You can just bind your UI elements, like NSProgressIndicator, directly to its fractionCompleted property and set it up with no glue code. Right? 
Well, no, because most classes in the UI layer need to be accessed on the main thread only, and NSProgress sends all its KVO notifications on the current thread. Hrm.

No, to properly observe an NSProgress, you need to do something like this:

```swift
class MyWatcher: NSObject {
  dynamic var fractionCompleted: Double = 0.0

  private var progress: Progress
  private var kvoContext = 0
  
  init(progress: Progress) {
    self.progress = progress
    
    super.init()
    
    progress.addObserver(self, forKeyPath: "fractionCompleted", options: [], context: &self.kvoContext)
    progress.addObserver(self, forKeyPath: "cancelled", options: [], context: &self.kvoContext)
  }
  
  deinit {
    progress.removeObserver(self, forKeyPath: "fractionCompleted", context: &self.kvoContext)
    progress.removeObserver(self, forKeyPath: "cancelled", context: &self.kvoContext)
  }
  
  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    if context == &self.kvoContext {
      DispatchQueue.main.async {
        switch keyPath {
        case "fractionCompleted":
          if let progress = object as? Progress {
            self.fractionCompleted = progress.fractionCompleted
          }
        case "cancelled":
          // handle cancellation somehow
        default:
          fatalError("Unexpected key path \(keyPath)")
        }
      }
    } else {
      super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
    }
  }
}
```

Beautiful, no? 
I hope I didn’t make any typos in the observation strings (is the cancellation one supposed to be "cancelled" or "isCancelled"? I never remember).

So instead of the main benefit of KVO—being able to bind UI elements to the model without glue code—we have *more* and *much weirder*
glue code than we’d see in a typical blocks-based approach.

But wait! NSProgress does have *some* blocks-based notification APIs! 
For example, the cancellation handler:

```swift
var cancellationHandler: (() -> Void)?
```

Unfortunately, each NSProgress object is allowed to have one and only one of these. 
So if you wanted to set up a cancellation handler on a particular NSProgress object, you’d better be sure that no one else also wanted to be informed of cancellation on that object, or you’ll clobber it. 
There are workarounds to this, but it’s not a good UI.

#### Building Progress Trees

NSProgress supports two methods of building trees of progress objects. 
Unfortunately, they are both flawed:

##### Implicit Tree Composition

NSProgress trees are built implicitly by calling becomeCurrent(withPendingUnitCount:) on an NSProgress object. 
This causes said object to be stashed in thread-local storage as the "current" NSProgress. 
Subsequently, the next NSProgress object that is created with init(totalUnitCount:) will be added to the current NSProgress as a child. 
This has the advantage of providing loose coupling of progress objects, freeing subtasks from having to know whether they are part of a larger tree, or what portion of the overall task they represent. 
Unfortunately, implicit tree composition has a lot of problems, not the least of which is that it is impossible to know whether any given API supports implicit NSProgress composition without either empirical testing or looking at the source code. 
Implicit tree composition is also awkward to use with multithreaded code, relying as it does on thread-local variables.

##### Explicit Tree Composition

In OS X 10.11 (“El Capitan”), NSProgress introduced a new initializer that allowed trees to be built explicitly:

```Swift
init(totalUnitCount: Int64, parent: Progress, pendingUnitCount: Int64)
```

This method allows much greater clarity, but unfortunately it sacrifices the loose coupling provided by the implicit method, since it requires the caller of the initializer to know both the total unit count of the progress object to be created, and the pending unit count of its parent. 
So to translate a function written using implicit composition:

```Swift
func foo() {
  let progress = Progress(totalUnitCount: 10) // we don't know about the parent's pending unit count, or need to know it
  
  ... do something ...
}
```

One must include not one, but two parameters in order to provide the same functionality:

```Swift
func foo(progress parentProgress: Progress, pendingUnitCount: Int64) {
  let progress = Progress(totalUnitCount: 10, parent: parentProgress, pendingUnitCount: pendingUnitCount)
  
  ... do something ...
}
```

This adds considerable bloat to the function’s signature.
