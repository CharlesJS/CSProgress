//
//  NotificationStream.swift
//
//  Created by Charles Srstka on 10/28/22.
//

class NotificationStream<Params> {
    private var continuation: AsyncStream<Params>.Continuation?
    private let stream: AsyncStream<Params>
    private let priority: TaskPriority?
    private let closure: (Params) async -> Void

    init(priority: TaskPriority? = nil, closure: @escaping (Params) async -> Void) {
        var continuation: AsyncStream<Params>.Continuation? = nil
        let stream = AsyncStream(Params.self) { continuation = $0 }

        self.continuation = continuation
        self.stream = stream
        self.priority = priority
        self.closure = closure
    }

    deinit {
        self.stop()
    }

    func send(_ params: Params) {
        self.continuation?.yield(params)
    }

    func start() {
        Task.detached(priority: self.priority) {
            for await eachParams in self.stream {
                await self.closure(eachParams)
            }
        }
    }

    func stop() {
        self.continuation?.finish()
        self.continuation = nil
    }
}
