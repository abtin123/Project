import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let batteryChannel = FlutterMethodChannel(
        name: "ir.abtin.abtin_maps/device_battery",
        binaryMessenger: controller.binaryMessenger
      )
      batteryChannel.setMethodCallHandler { call, result in
        guard call.method == "batteryLevel" else {
          result(FlutterMethodNotImplemented)
          return
        }
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        result(level < 0 ? -1 : Int(level * 100))
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
