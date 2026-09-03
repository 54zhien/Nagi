
import Foundation

@MainActor
enum GlassBackendConfiguration {
    static let debugOverrideKey = "reader.glass.backend.debug"
#if DEBUG
    private static let debugLaunchArgument = "-reader-glass-backend"
#endif

    static var selectedBackend: GlassBackend {
#if DEBUG
        if let launchBackend {
            return launchBackend
        }
        guard let rawValue = UserDefaults.standard.string(forKey: debugOverrideKey),
              let backend = GlassBackend(rawValue: rawValue)
        else {
            return .native
        }
        return backend
#else
        return .native
#endif
    }

#if DEBUG
    private static var launchBackend: GlassBackend? {
        let arguments = ProcessInfo.processInfo.arguments
        if let argument = arguments.first(where: {
            $0.hasPrefix("\(debugLaunchArgument)=")
        }) {
            let rawValue = String(argument.dropFirst(debugLaunchArgument.count + 1))
            return GlassBackend(rawValue: rawValue)
        }

        guard let index = arguments.firstIndex(of: debugLaunchArgument),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return GlassBackend(rawValue: arguments[index + 1])
    }
#endif

    static var effectiveBackend: GlassBackend {
        NagiGlassStyleStore.usesNativeLiquidGlass ? selectedBackend : .backdrop
    }

    static var surfaceBackend: GlassBackend {
        effectiveBackend == .hybrid ? .backdrop : effectiveBackend
    }

    static var containerBackend: GlassBackend {
        effectiveBackend == .hybrid ? .native : effectiveBackend
    }

#if DEBUG
    static func setDebugBackend(_ backend: GlassBackend?) {
        if let backend {
            UserDefaults.standard.set(backend.rawValue, forKey: debugOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: debugOverrideKey)
        }
    }
#endif
}
