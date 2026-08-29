//
//  SettingsView.swift
//  Nagi
//
//  设置与关于
//

import SwiftUI
import UIKit

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("应用") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .navigationTitle("设置")
        }
    }
}

private struct AboutView: View {
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
    }

    var body: some View {
        VStack(spacing: 20) {
            AppIconView()
                .frame(width: 112, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityHidden(true)

            Text("Nagi")
                .font(.title2.weight(.semibold))

            VStack(spacing: 4) {
                Text("版本 " + appVersion)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("构建 " + buildNumber)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityElement(children: .combine)
    }
}

private struct AppIconView: View {
    var body: some View {
        if let image = Self.image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
                .padding(24)
                .foregroundStyle(.secondary)
        }
    }

    private static var image: UIImage? {
        for name in configuredIconNames + ["Icon", "AppIcon"] {
            if let image = UIImage(named: name) {
                return image
            }

            let resourceName = (name as NSString).deletingPathExtension
            let resourceExtension = (name as NSString).pathExtension.isEmpty ? "png" : nil
            if let url = Bundle.main.url(forResource: resourceName, withExtension: resourceExtension),
               let image = UIImage(contentsOfFile: url.path) {
                return image
            }
        }

        return nil
    }

    private static var configuredIconNames: [String] {
        guard
            let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
            let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let iconFiles = primaryIcon["CFBundleIconFiles"] as? [String]
        else {
            return []
        }

        return Array(iconFiles.reversed())
    }
}

#Preview {
    SettingsView()
}
