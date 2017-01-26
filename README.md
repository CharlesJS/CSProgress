# CSProgress

## Introduction

NSProgress (renamed to Progress in Swift 3) is a Foundation class introduced in Mac OS X 10.9 (“Mavericks”), intended to simplify the
reporting of progress in Mac and iOS applications. The concept it introduces is great, creating a tree of progress objects, all of which
represent a small part of the work to be done and can be confined to that particular section of the code, reducing the amount of 
spaghetti needed to represent progress in a complex system.

Unfortunately, the execution is kind of terrible.

### NSProgress’s Performance is Terrible

Unfortunately, the performance of NSProgress is simply *terrible.* This is not a major concern for many Cocoa classes, but the purpose
of NSProgress, tracking progress for operations that take a long time, naturally lends itself to being used in performance-critical code.
The slower NSProgress is, the more likely it is that it will affect running times for operations that are already long-running enough to
need progress reporting. In Apple’s [“Best Practices in Progress Reporting”](https://developer.apple.com/videos/play/wwdc2015/232/)
video from 2015, Apple recommends not updating NSProgress in a tight loop, because of the effects that will have on performance.

There are a number of things that contribute to the sluggishness of NSProgress:

#### Objective-C

This aspect can’t really be helped, since NSProgress was invented at a time when Objective-C was the only mainstream language used to
develop Apple’s high-level APIs. However, the fact that NSProgress is Objective-C-based means that every time it is updated, we will get
invocations of objc_msgSend. This can be worked around using IMP caching, though, so it’s not that big a deal, right? Well, unfortunately,
there’s more.

#### KVO

This is the big one. Every an NSProgress object is updated, it posts KVO notifications. KVO is [well known to have terrible performance]
(http://blog.metaobject.com/2014/03/the-siren-call-of-kvo-and-cocoa-bindings.html). And every time you update the change count on an
NSProgress, object, KVO notifications will be sent not only for that progress object, but also its parent, its grandparent, and so on
all the way back up to the root of the tree. Furthermore, these notifications are all sent on the current thread, so your worker will
need to wait for all the notifications to finish before it can continue getting on with what it was doing. This can significantly bog
things down.

#### NSLock

NSProgress is thread-safe, which is great! Unfortunately this is implemented using NSLock, a simple wrapper around pthread mutexes
[which adds a great deal of overhead](http://perpendiculo.us/2009/09/synchronized-nslock-pthread-osspinlock-showdown-done-right/).
Furthermore, there’s no atomic way to increment the change count. To do so, one has to get the current completedUnitCount, add something
to it, and then send that back to completedUnitCount’s setter, resulting in the lock being taken twice for one operation.

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

# To Be Continued when I get time to finish this document
