import CoreLocation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var locationBridge: LocationBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let messenger = self.registrar(forPlugin: "AbtinLocationBridge")?.messenger() {
      locationBridge = LocationBridge(messenger: messenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

/// iOS location source (CoreLocation already fuses GPS + Wi-Fi + cell).
final class LocationBridge: NSObject, CLLocationManagerDelegate, FlutterStreamHandler {
  private let manager = CLLocationManager()
  private var sink: FlutterEventSink?
  private var running = false

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
    manager.distanceFilter = kCLDistanceFilterNone
    manager.activityType = .automotiveNavigation
    manager.pausesLocationUpdatesAutomatically = false
    FlutterMethodChannel(name: "ir.abtin.maps/location", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    FlutterEventChannel(name: "ir.abtin.maps/location_events", binaryMessenger: messenger)
      .setStreamHandler(self)
  }

  private var status: CLAuthorizationStatus {
    if #available(iOS 14.0, *) { return manager.authorizationStatus }
    return CLLocationManager.authorizationStatus()
  }

  private var authorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "permission":
      var precise = authorized
      if #available(iOS 14.0, *), authorized { precise = manager.accuracyAuthorization == .fullAccuracy }
      result(["fine": precise, "coarse": authorized])
    case "serviceEnabled":
      result(CLLocationManager.locationServicesEnabled())
    case "start":
      start()
      result(running)
    case "setNavigation":
      result(nil)
    case "stop":
      stop()
      result(nil)
    case "lastKnown":
      if let l = manager.location { result(map(l, cached: true)) } else { result(nil) }
    case "openSettings":
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start() {
    guard authorized else { return }
    if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
       modes.contains("location") {
      manager.allowsBackgroundLocationUpdates = true
    }
    manager.startUpdatingLocation()
    running = true
    if let l = manager.location { sink?(map(l, cached: true)) }
  }

  private func stop() {
    manager.stopUpdatingLocation()
    running = false
  }

  private func map(_ l: CLLocation, cached: Bool) -> [String: Any] {
    let age = max(0, Date().timeIntervalSince(l.timestamp))
    var m: [String: Any] = [
      "type": "fix",
      "lat": l.coordinate.latitude,
      "lng": l.coordinate.longitude,
      "acc": l.horizontalAccuracy,
      "time": Int(l.timestamp.timeIntervalSince1970 * 1000),
      "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - age) * 1000),
      "source": "fused",
      "cached": cached,
      "mock": false,
    ]
    if l.speed >= 0 { m["speed"] = l.speed }
    if l.course >= 0 { m["bearing"] = l.course }
    if #available(iOS 10.0, *), l.speedAccuracy >= 0 { m["speedAcc"] = l.speedAccuracy }
    if #available(iOS 13.4, *), l.courseAccuracy >= 0 { m["bearingAcc"] = l.courseAccuracy }
    if l.verticalAccuracy >= 0 { m["alt"] = l.altitude }
    return m
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    for l in locations where l.horizontalAccuracy >= 0 { sink?(map(l, cached: false)) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
