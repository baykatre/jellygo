import UIKit
import MobileVLCKit

class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Pre-warm VLC shared library on a background thread so the first player open doesn't stutter
        DispatchQueue.global(qos: .utility).async {
            let _ = VLCMediaPlayer()
        }

        // Pre-warm UIKit popup infrastructure (Menu/ActionSheet) so the first Menu tap doesn't freeze
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.prewarmMenuInfrastructure()
        }

        return true
    }

    /// Forces UIKit to initialize its popup rendering pipeline in a completely invisible way.
    private static func prewarmMenuInfrastructure() {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }

        // Use a separate off-screen window so nothing appears on the main UI
        let offscreenWindow = UIWindow(windowScene: scene)
        offscreenWindow.frame = CGRect(x: -1000, y: -1000, width: 1, height: 1)
        offscreenWindow.isHidden = false
        offscreenWindow.alpha = 0

        let vc = UIViewController()
        offscreenWindow.rootViewController = vc
        offscreenWindow.makeKeyAndVisible()

        let dummy = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        dummy.addAction(UIAlertAction(title: " ", style: .cancel))
        if let popover = dummy.popoverPresentationController {
            popover.sourceView = vc.view
            popover.sourceRect = .zero
            popover.permittedArrowDirections = []
        }

        vc.present(dummy, animated: false) {
            dummy.dismiss(animated: false) {
                offscreenWindow.isHidden = true
                offscreenWindow.rootViewController = nil
                // Restore main window as key
                scene.windows.first?.makeKeyAndVisible()
            }
        }
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
