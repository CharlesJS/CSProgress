# CSProgress

## Introduction

NSProgress (renamed to Progress in Swift 3) is a Foundation class introduced in Mac OS X 10.9 (“Mavericks”), intended to simplify progress reporting in Mac and iOS applications. The concept it introduces is great, creating a tree of progress objects, all of which
represent a small part of the work to be done and can be confined to that particular section of the code, reducing the amount of 
spaghetti needed to represent progress in a complex system.

Unfortunately, the execution is terrible.

### NSProgress’s Performance is Terrible

Unfortunately, the performance of NSProgress is simply *terrible.* While performance is not a major concern for many Cocoa classes, the purpose
of NSProgress—tracking progress for operations that take a long time—naturally lends itself to being used in performance-critical code.
The slower NSProgress is, the more likely it is that it will affect running times for operations that are already long-running enough to
need progress reporting. In Apple’s ["Best Practices in Progress Reporting"](https://developer.apple.com/videos/play/wwdc2015/232/)
video from 2015, Apple recommends not updating NSProgress in a tight loop, because of the effects that will have on performance. Unfortunately, this best-practice effectively results in polluting the back-end with UI code, adversely affecting the separation of concerns. 

There are a number of things that contribute to the sluggishness of NSProgress:

#### Objective-C

This aspect can’t really be helped, since NSProgress was invented at a time when Objective-C was the only mainstream language used to
develop Apple’s high-level APIs. However, the fact that NSProgress is Objective-C-based means that every time it is updated, we will get
invocations of objc_msgSend. This can be worked around using IMP caching, though, so it’s not that big a deal, right? Well, unfortunately,
there’s more.

#### KVO

This is the big one. Every an NSProgress object is updated, it posts KVO notifications. KVO is [well known to have terrible performance characteristics]
(http://blog.metaobject.com/2014/03/the-siren-call-of-kvo-and-cocoa-bindings.html). And every time you update the change count on an
NSProgress object, KVO notifications will be sent not only for that progress object, but also its parent, its grandparent, and so on
all the way back up to the root of the tree. Furthermore, these notifications are all sent on the current thread, so your worker will
need to wait for all the notifications to finish before it can continue getting on with what it was doing. This can significantly bog
things down.

#### NSLock

NSProgress is thread-safe, which is great! Unfortunately this is implemented using NSLock, a simple wrapper around pthread mutexes
[which adds a great deal of overhead](http://perpendiculo.us/2009/09/synchronized-nslock-pthread-osspinlock-showdown-done-right/).
Furthermore, there’s no atomic way to increment the change count. To do so, one first has to get the current completedUnitCount, then add something to it, and then finally send that back to completedUnitCount’s setter, resulting in the lock being taken twice for one operation. In addition to being inferior performance-wise, this also introduces a race condition, since something else running on another thread can conceivably change the completedUnitCount property in between the read and the write, causing the unit count to become incorrect.

#### It’s a Memory Hog

In the process of updating its change count and sending out its KVO notifications, NSProgress generates a lot of autoreleased objects.
In my performance testing, updating an NSProgress one million times causes the app to bloat to a memory size of 4.8 GB (!). This can,
of course, be alleviated by wrapping the whole thing in an autorelease pool, but this tends to slow down performance even further.

All these performance caveats at least lead to a nice, silky-smooth interface, though, right? Well, no.

### NSProgress’s Interface is Terrible

All of NSProgress’s reporting is done via KVO. That’s slick, right? You can just bind your UI elements, like NSProgressIndicator,
directly to its fractionCompleted property and set it up with no glue code. Right? Well, no, because most classes in the UI layer
need to be accessed on the main thread only, and NSProgress sends all its KVO notifications on the current thread. Hrm.

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

Beautiful, no? I hope I didn’t make any typos in the observation strings (is the cancellation one supposed to be "cancelled" or
"isCancelled"? I never remember).

So instead of the main benefit of KVO—being able to bind UI elements to the model without glue code—we have *more* and *much weirder*
glue code than we’d see in a typical blocks-based approach.

But wait! NSProgress does have *some* blocks based notification APIs! For example, the cancellation handler:

```swift
var cancellationHandler: (() -> Void)?
```

Unfortunately, each NSProgress object is allowed to have one and only one of these. So if you wanted to set up a cancellation handler
on a particular NSProgress object, you’d better be sure that no one else also wanted to be informed of cancellation on that object,
or you’ll clobber it. There are workarounds to this, but it’s not a good UI.

#### Building Progress Trees

NSProgress supports two methods of building trees of progress objects. Unfortunately, they are both flawed:

##### Implicit Tree Composition

NSProgress trees are built implicitly by calling becomeCurrent(withPendingUnitCount:) on an NSProgress object. This causes said object to be stashed in thread-local storage as the "current" NSProgress. Subsequently, the next NSProgress object that is created with init(totalUnitCount:) will be added to the current NSProgress as a child. This has the advantage of providing loose coupling of progress objects, freeing subtasks from having to know whether they are part of a larger tree, or what portion of the overall task they represent. Unfortunately, implicit tree composition has a lot of problems, not the least of which is that it is impossible to know whether any given API supports implicit NSProgress composition without either empirical testing or looking at the source code. Implicit tree composition is also awkward to use with multithreaded code, relying as it does on thread-local variables.

##### Explicit Tree Composition

In OS X 10.11 (“El Capitan”), NSProgress introduced a new initializer that allowed trees to be built explicitly:

```Swift
init(totalUnitCount: Int64, parent: Progress, pendingUnitCount: Int64)
```

This method allows much greater clarity, but unfortunately it sacrifices the loose coupling provided by the implicit method, since it requires the caller of the initializer to know both the total unit count of the progress object to be created, and the pending unit count of its parent. So to translate a function written using implicit composition:

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

## My solution: CSProgress

CSProgress is a Swift-native class intended to be a drop-in replacement for NSProgress. It does not yet support all of NSProgress’s features, but serves as a test case demonstrating the improvements that can be made to NSProgress.

CSProgress supports the following features:

* Fully Swift-native
* Fully blocks/closures-based interface for observing changes
* Multiple closure-based observers can be created for the same property for any given CSProgress
* Customizable granularity, allowing notifications to be sent when the fractionCompleted property changes by a certain amount, rather than every time completedUnitCount is updated
* Sends all its notifications on a customizable operation queue, rather than on the current thread (defaults to the main queue)
* Bridgeable to and from NSProgress, allowing it to be inserted into trees of NSProgress objects. Bridged NSProgress objects are updated on a customizable queue as well, meaning that KVO notifications on a bridged NSProgress object can be directly observed by UI elements if the only progress objects being updated are CSProgress. This also has the effect of keeping NSProgress’s KVO notifications from slowing down the worker thread.
* Uses dispatch semaphores rather than NSLocks, as they provided the best performance out of the options that I tried.
* Supports incrementing the completedUnitCount as an atomic operation, rather than having to take the semaphore twice, once to read the old value, and again to write the new one.
* Supports explicit composition, even on versions of OS X/macOS earlier than 10.11 (not yet tested)
* Uses generics to support all integer types as arguments, rather than only Int64
* Adds a wrapper struct encapsulating a parent progress object and its pending unit count, which can be passed to child tasks in order to build progress trees explicitly while still enjoying the loose coupling of the implicit composition method
* Much better performance than NSProgress. On my 2013 Retina MacBook Pro, incrementing each progress object in a tree consisting of a root node and four child nodes from 0 to 1,000,000 each takes:
 * NSProgress with no observers and no autorelease pool: 18.77 seconds (although it bloated the app’s memory size to over 4.5 GB)
 * NSProgress with an autorelease pool: 26.64 seconds
 * NSProgress with a KVO observer and no autorelease pool: 54.72 seconds (also consuming a lot of memory)
 * NSProgress with a KVO observer and an autorelease pool: 60.93 seconds
 * CSProgress with no observers: 0.91 seconds
 * CSProgress with an observer: 0.90 seconds
 
 As you can see, having an observer has no noticeable effect on performance (in this test, the version with an observer actually took slightly less time). As a result, CSProgress performs about twice an order of magnitude better than NSProgress when it is not being observed, and several times that when observers are involved.
 
CSProgress also includes a convenience struct for encapsulating a parent progress object and its pending unit count, allowing both to be passed as one argument:

```Swift
func foo(parentProgress: Progress.ParentReference) {
  let progress = parentProgress.makeChild(totalUnitCount: 10)
  
  ... do something ...
}

let rootProgress = CSProgress(totalUnitCount: 10, parent: nil, pendingUnitCount: 0)

foo(parentProgress: rootProgress.pass(pendingUnitCount: 5)
```

# To Do:
 
 * Add support for NSProgress features not yet handled
  * Pause and resume
  * Publish and subscribe
  * Arbitrary user info dictionaries
