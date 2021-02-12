//
//  AppDelegate.swift
//  FSEventsTest
//
//  Created by Steven Sherry on 6/13/20.
//  Copyright © 2020 Steven Sherry. All rights reserved.
//

import Cocoa
import SwiftUI
import Combine

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {

  var window: NSWindow!
  
  var bag = Set<AnyCancellable>()
  var timerCancellable: AnyCancellable!
  
  func applicationDidFinishLaunching(_ aNotification: Notification) {
    // Create the SwiftUI view that provides the window contents.
    let contentView = ContentView()

    // Create the window and set the content view. 
    window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 480, height: 300),
        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
        backing: .buffered, defer: false)
    window.center()
    window.setFrameAutosaveName("Main Window")
    window.contentView = NSHostingView(rootView: contentView)
    window.makeKeyAndOrderFront(nil)
    
//    FileSystemEventPublisher(pathsToWatch: ["/Users/stevensherry/Design"])
//      .sink(
//        receiveCompletion: { _ in
//          print("Received Completion for Design")
//        },
//        receiveValue: {
//          print("Event fired for Design")
//        }
//      )
//      .store(in: &bag)
//
//    FileSystemEventPublisher(pathsToWatch: ["/Users/stevensherry/ansible"])
//      .sink { print("Event fired for ansible!") }
//      .store(in: &bag)
//
//    timerCancellable = Timer.publish(every: 15, on: RunLoop.main, in: .default)
//      .autoconnect()
//      .sink { _ in
//        print("Timer executed")
//        print(self.bag)
//        self.bag.removeAll()
//      }
    
    ApplicationsPublisher(applicationFolderPaths: ["/Applications", "/Users/stevensherry/Applications"])
      .sink { applications in
          print("Got applications:\n \(applications)")
      }
      .store(in: &bag)
    
  }

  func applicationWillTerminate(_ aNotification: Notification) {
    // Insert code here to tear down your application
  }


}

struct ApplicationsPublisher: Publisher {
  typealias Output = [Application]
  typealias Failure = Never
  
  private let applicationFolderPaths: [String]
  init(applicationFolderPaths: [String]) {
    self.applicationFolderPaths = applicationFolderPaths
  }
  
  func receive<S>(subscriber: S) where S : Subscriber, Failure == S.Failure, Output == S.Input {
    let subscription = ApplicationsSubscription(subscriber: subscriber, applicationFolderPaths: applicationFolderPaths)
    subscriber.receive(subscription: subscription)
  }
}

func downCast<A, B>(to: A.Type) -> (B) -> A? {
  return { b in
    b as? A
  }
}

class ApplicationsSubscription<S: Subscriber>: Subscription where S.Input == ApplicationsPublisher.Output, S.Failure == ApplicationsPublisher.Failure {
  private var subscriber: S?
  private var demand: Subscribers.Demand = .none
  private var sink: AnyCancellable?
  private let fileSystemEventSink: AnyCancellable
  private let query: NSMetadataQuery
  private let applicationFolderPaths: [String]
  
  init(subscriber: S, applicationFolderPaths: [String]) {
    self.subscriber = subscriber
    self.applicationFolderPaths = applicationFolderPaths
    
    let query: NSMetadataQuery = {
      let query = NSMetadataQuery()
      query.searchScopes = [NSMetadataQueryLocalComputerScope]
      query.predicate = NSPredicate(format: "kMDItemContentType == 'com.apple.application-bundle'")
      return query
    }()
    self.query = query
    
    self.fileSystemEventSink = FileSystemEventPublisher(pathsToWatch: applicationFolderPaths)
      .throttle(for: .seconds(5 * 60), scheduler: DispatchQueue.main, latest: true)
      .sink {
        if query.isStarted {
          query.stop()
          query.start()
        }
      }
  }
  
  public func request(_ demand: Subscribers.Demand) {
    if demand != .none {
      self.demand += demand
    }
    
    if sink == nil {
      sink = NotificationCenter.default
        .publisher(for: Notification.Name.NSMetadataQueryDidFinishGathering)
        .map { [query] _ -> [Application] in
          return query.results
            .compactMap { $0 as? NSMetadataItem }
            .compactMap(Application.init(from:))
            .filter { [weak self] application in
              guard let self = self else { return false }
              return self.applicationFolderPaths.reduce(false) { acc, next in
                application.bundlePath.hasPrefix(next) || acc
              }
            }
            .sorted { $0.localizedName.lowercased() < $1.localizedName.lowercased() }
        }
        .eraseToAnyPublisher()
        .assertNoFailure()
        .sink(
          receiveCompletion: { [weak self] completion in
            Swift.print("Received completion")
            self?.subscriber?.receive(completion: completion)
          },
          receiveValue: { [weak self] applications in
            self?.send(applications)
          }
        )
      query.start()
    }
  }
  
  private func send(_ applications: [Application]) {
    print("Demand is: \(demand)")
    if demand > .none {
      _ = subscriber?.receive(applications)
      demand -= .max(1)
    }
  }
  
  public func cancel() {
    subscriber = nil
    sink?.cancel()
    fileSystemEventSink.cancel()
    query.stop()
  }
}

public struct Application: Equatable, Hashable {
  public let bundleIdentifier: String
  public let bundlePath: String
  public let localizedName: String
  public let parentApplication: String?
  
  public init(bundleIdentifier: String, bundlePath: String, localizedName: String, parentApplication: String?) {
    self.bundleIdentifier = bundleIdentifier
    self.bundlePath = bundlePath
    self.localizedName = localizedName
    self.parentApplication = parentApplication
  }
}

extension Application {
  public init?(from metadataItem: NSMetadataItem) {
    guard
      let bundleIdentifier = metadataItem.value(forAttribute: NSMetadataItemCFBundleIdentifierKey) as? String,
      let iconPath = (metadataItem.value(forAttribute: NSMetadataItemPathKey) as? String),
      let localizedName = (metadataItem.value(forAttribute: NSMetadataItemDisplayNameKey) as? String)?.trimmingCharacters(in: .whitespaces)
    else { return nil }
    
    self.bundleIdentifier = bundleIdentifier
    self.bundlePath = iconPath
    self.localizedName = localizedName
    self.parentApplication = iconPath
      .split(separator: "/")
      .dropLast()
      .first { $0.contains(".app") }
      .map(String.init)
  }
}
