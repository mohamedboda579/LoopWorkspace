import Foundation
import LinxCGMKit
import LoopKit
import LoopKitUI
import SwiftUI

class LinxUICoordinator: UINavigationController, CGMManagerOnboarding, CompletionNotifying, UINavigationControllerDelegate {
    var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    var completionDelegate: CompletionDelegate?
    var cgmManager: LinxCGMManager?
    var displayGlucosePreference: DisplayGlucosePreference
    var colorPalette: LoopUIColorPalette

    init(
        cgmManager: LinxCGMManager? = nil,
        colorPalette: LoopUIColorPalette,
        displayGlucosePreference: DisplayGlucosePreference,
        allowDebugFeatures _: Bool
    ) {
        self.cgmManager = cgmManager
        self.colorPalette = colorPalette
        self.displayGlucosePreference = displayGlucosePreference
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        navigationBar.prefersLargeTitles = true
        setViewControllers([initialView()], animated: false)
    }

    private func initialView() -> UIViewController {
        if cgmManager == nil {
            // Setup: create the manager and present the settings view.
            let manager = LinxCGMManager()
            cgmManager = manager
            // Notify Loop that it was created (and onboarded).
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: manager)
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: manager)
        }

        let viewModel = LinxSettingsViewModel(
            cgmManager: cgmManager!,
            displayGlucosePreference: displayGlucosePreference
        )
        let view = LinxSettingsView(
            viewModel: viewModel,
            didFinish: { [weak self] in
                guard let self = self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            },
            deleteCGM: { [weak self] in
                self?.cgmManager?.notifyDelegateOfDeletion {
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        self.completionDelegate?.completionNotifyingDidComplete(self)
                        self.dismiss(animated: true)
                    }
                }
            }
        )
        let hosting = DismissibleHostingController(content: view, colorPalette: colorPalette)
        hosting.title = "LinX CGM"
        return hosting
    }
}
