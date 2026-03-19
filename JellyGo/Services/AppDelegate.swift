import UIKit
import AVFoundation
import MobileVLCKit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configure audio session for background playback
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AVAudioSession setup failed: \(error)")
        }

        // Pre-warm the selected player engine on a background thread
        let enginePref = PlayerEngine(rawValue: UserDefaults.standard.string(forKey: "jellygo.playerEngine") ?? "") ?? .vlc
        DispatchQueue.global(qos: .utility).async {
            switch enginePref {
            case .vlc:
                let _ = VLCMediaPlayer()
            case .ksplayer:
                // KSPlayer initializes lazily; no pre-warm needed
                break
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.shared.backgroundCompletionHandler = completionHandler
    }
}
