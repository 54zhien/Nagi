
import Foundation
import UIKit

@MainActor
final class ReaderPerformanceController {
    static let shared = ReaderPerformanceController()

    private let processInfo = ProcessInfo.processInfo
    private let notificationCenter = NotificationCenter.default
    private var observerTokens: [NSObjectProtocol] = []

    private(set) var thermalState: ProcessInfo.ThermalState
    private(set) var isLowPowerModeEnabled: Bool
    let supportsHighRefreshRate: Bool

    var shouldReduceNonessentialEffects: Bool {
        if isLowPowerModeEnabled {
            return true
        }

        switch thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return false
        }
    }

    private init() {
        thermalState = processInfo.thermalState
        isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        supportsHighRefreshRate = UIScreen.main.maximumFramesPerSecond >= 120

        observerTokens.append(
            notificationCenter.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: processInfo,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )
        observerTokens.append(
            notificationCenter.addObserver(
                forName: Notification.Name.NSProcessInfoPowerStateDidChange,
                object: processInfo,
                queue: .main
            ) { [weak self] _ in
                self?.refresh()
            }
        )
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
    }

    private func refresh() {
        thermalState = processInfo.thermalState
        isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
    }
}
