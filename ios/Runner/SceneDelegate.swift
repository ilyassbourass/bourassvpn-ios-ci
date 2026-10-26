import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

    override func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
                            options connectionOptions: UIScene.ConnectionOptions) {
            super.scene(scene, willConnectTo: session, options: connectionOptions)
            // Headless-test hook: accept `-autoconnect <zone>` as a launch arg
            // (dvt launch / devicectl) and persist it before Flutter boots.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-autoconnect"), i + 1 < args.count {
                UserDefaults.standard.set(true, forKey: "autoconnect")
                UserDefaults.standard.set(args[i + 1], forKey: "autoconnect_zone")
            }
            // Register the BourassVPN platform channels as soon as the Flutter
            // view exists. The Dart side probes 'ping' at startup.
            if let vc = window?.rootViewController as? FlutterViewController {
                VpnBridge.register(with: vc.binaryMessenger)
            }
        }
}
