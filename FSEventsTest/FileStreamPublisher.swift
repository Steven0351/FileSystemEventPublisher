//
//  FileStreamPublisher.swift
//  FSEventsTest
//
//  Created by Steven Sherry on 6/15/20.
//  Copyright © 2020 Steven Sherry. All rights reserved.
//

import Foundation
import Combine

struct FileSystemEventPublisher: Publisher {
  typealias Output = Void
  typealias Failure = Never

  private let pathsToWatch: [String]
  private let latency: TimeInterval
  
  init(pathsToWatch: [String], latency: TimeInterval = 0) {
    self.pathsToWatch = pathsToWatch
    self.latency = latency
  }
  
  func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
    let subscription = FileSystemEventSubscription(sub: AnySubscriber(subscriber), pathsToWatch: pathsToWatch, latency: latency)
    subscriber.receive(subscription: subscription)
  }
}

final class FileSystemEventSubscription: Subscription {
  private var subscriber: AnySubscriber<Void, Never>?
  private var eventStreamRef: FSEventStreamRef? = nil
  private var eventStreamIsRunning = false
  private var demand: Subscribers.Demand = .none
  
  private enum PublishSource {
    case eventCallback, setup
  }
  
  init(sub: AnySubscriber<Void, Never>, pathsToWatch: [String], latency: TimeInterval) {
    self.subscriber = AnySubscriber(sub)
    
    let observer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
    let pointer = UnsafeMutablePointer<FSEventStreamContext>.allocate(capacity: 1)
    defer { pointer.deallocate() }

    let context = FSEventStreamContext(version: 0, info: observer, retain: nil, release: nil, copyDescription: nil)
    pointer.initialize(to: context)
    
    let callback: FSEventStreamCallback = { _, selfPointer, _, _, _, _ in
      Swift.print("Executing callback from FSEventStream")
      guard let pointer = selfPointer else { Swift.print("Null pointer, returning"); return }
      let this = Unmanaged<FileSystemEventSubscription>.fromOpaque(pointer).takeUnretainedValue()
      _ = this.publish(for: .eventCallback)
    }
    
    eventStreamRef = FSEventStreamCreate(
      kCFAllocatorDefault,
      callback,
      pointer,
      pathsToWatch as CFArray,
      UInt64(kFSEventStreamEventIdSinceNow),
      latency,
      UInt32(kFSEventStreamCreateFlagNone)
    )!
  }
  
  func request(_ demand: Subscribers.Demand) {
    Swift.print("requesting demand: \(demand)")
    if demand != .none {
      self.demand += demand
    }
    
    publish(for: .setup)
  }
  
  private func startEventStream() {
    FSEventStreamScheduleWithRunLoop(eventStreamRef!, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    FSEventStreamStart(eventStreamRef!)
  }
  
  private func publish(for source: PublishSource) {
    switch source {
    case .setup:
      if eventStreamIsRunning { return }
      startEventStream()
    case .eventCallback:
      if demand > .none {
        _ = subscriber?.receive(())
        demand -= .max(1)
      }
    }
  }
  
  func cancel() {
    print("Cancelling subscription for real")
    subscriber = nil
    FSEventStreamStop(eventStreamRef!)
    FSEventStreamInvalidate(eventStreamRef!)
    FSEventStreamRelease(eventStreamRef!)
    eventStreamRef = nil
  }
}
