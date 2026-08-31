//
//  GlassBackendConfiguration.swift
//  Nagi
//
//  Selects a fixed Glass backend when a reader session creates its view tree.
//  The debug override is intentionally a configuration seam, not a live
//  mutation of an existing compositor graph.
//

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
    /// A launch argument makes Native/Backdrop/Hybrid comparison reproducible
    /// without adding a user-facing settings row.  Both `-reader-glass-backend
    /// backdrop` and `-reader-glass-backend=backdrop` are accepted.
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

    /// Hybrid keeps the shared container on Apple's compositor path while
    /// giving individual controls the public blur fallback.  This is an A/B
    /// candidate, not a claim that it wins before device profiling.
    static var surfaceBackend: GlassBackend {
        selectedBackend == .hybrid ? .backdrop : selectedBackend
    }

    static var containerBackend: GlassBackend {
        selectedBackend == .hybrid ? .native : selectedBackend
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
