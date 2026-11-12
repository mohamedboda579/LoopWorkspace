import Foundation
import LinxCGMKit
import LoopKit
import LoopKitUI
import UIKit

extension LinxCGMManager: CGMManagerUI {
    public static var onboardingImage: UIImage? { nil }

    public static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        let vc = LinxUICoordinator(
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        )
        return .userInteractionRequired(vc)
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> CGMManagerViewController {
        LinxUICoordinator(
            cgmManager: self,
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        )
    }

    public var smallImage: UIImage? { nil }

    // MARK: - CGMStatusIndicator

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        if state.sensorSerial?.isEmpty ?? true {
            return LinxStatusHighlight(
                localizedMessage: "Elegir\nsensor",
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }
        // Signal-loss indicator when the last value is older than 15 minutes.
        if let last = state.latestReadingDate, last.timeIntervalSinceNow < -LinxCGMManager.readingStaleInterval {
            return LinxStatusHighlight(
                localizedMessage: "Sin\nseñal",
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }
        if state.latestReadingDate == nil {
            return LinxStatusHighlight(
                localizedMessage: "LinX\nbuscando",
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        }
        return nil
    }

    public var cgmStatusBadge: DeviceStatusBadge? { nil }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? { nil }
}

public struct LinxStatusHighlight: DeviceStatusHighlight, Equatable {
    public let localizedMessage: String
    public let imageName: String
    public let state: DeviceStatusHighlightState
}
