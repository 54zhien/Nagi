//
//  SettingsView.swift
//  Nagi
//
//  设置与关于
//

import SwiftUI
import UIKit

enum NagiAppearanceSettings {
    static let bookCardsUseLiquidGlassKey = "appearance.liquidGlass.bookCards"
    static let readerSettingsUseLiquidGlassKey = "appearance.liquidGlass.readerSettings"
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHeaderHidden = false
    @State private var headerTransitionProgress: CGFloat = 0

    var body: some View {
        NavigationStack {
            List {
                Section("通用") {
                    NavigationLink {
                        AppearanceView()
                    } label: {
                        Label("外观", systemImage: "circle.lefthalf.filled")
                    }
                }

                Section("应用") {
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于", systemImage: "info.circle")
                    }
                }
            }
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .ignoresSafeArea(.container, edges: .top)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(geometry.contentOffset.y + geometry.contentInsets.top, 0)
            } action: { _, scrollOffset in
                updateHeaderVisibility(for: scrollOffset)
            }
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear
                    .frame(height: NagiPageHeaderMetrics.contentHeight)
            }
            .overlay(alignment: .top) {
                NagiPageHeader(
                    title: "设置",
                    transitionProgress: headerTransitionProgress,
                    isHeaderHidden: isHeaderHidden
                )
            }
        }
        .overlay(alignment: .top) {
            NagiStatusBarBlurLayer()
        }
    }

    private func updateHeaderVisibility(for rawScrollOffset: CGFloat) {
        let scrollOffset = max(rawScrollOffset, 0)
        let shouldHide = isHeaderHidden
            ? scrollOffset > NagiPageHeaderMetrics.revealTolerance
            : scrollOffset > NagiPageHeaderMetrics.hideThreshold

        guard shouldHide != isHeaderHidden else { return }
        isHeaderHidden = shouldHide

        let targetProgress: CGFloat = shouldHide ? 1 : 0
        if reduceMotion {
            headerTransitionProgress = targetProgress
        } else {
            withAnimation(.easeInOut(duration: NagiPageHeaderMetrics.transitionDuration)) {
                headerTransitionProgress = targetProgress
            }
        }
    }
}

private struct AppearanceView: View {
    @AppStorage(NagiAppearanceSettings.bookCardsUseLiquidGlassKey)
    private var bookCardsUseLiquidGlass = true
    @AppStorage(NagiAppearanceSettings.readerSettingsUseLiquidGlassKey)
    private var readerSettingsUseLiquidGlass = true
    @State private var isLiquidGlassExpanded = false

    var body: some View {
        List {
            Section {
                DisclosureGroup(
                    isExpanded: $isLiquidGlassExpanded
                ) {
                    Toggle("书籍卡片", isOn: $bookCardsUseLiquidGlass)
                    Toggle("阅读设置项", isOn: $readerSettingsUseLiquidGlass)
                } label: {
                    Label("Liquid Glass 控件", systemImage: "rectangle.on.rectangle")
                }
            }
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
        .toolbar(.visible, for: .navigationBar)
        .accessibilityElement(children: .combine)
    }
}

private struct AppIconView: View {
    var body: some View {
        Group {
            if let image = Self.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(24)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private static var image: UIImage? {
        UIImage(named: "Icon")
    }
}

#Preview {
    SettingsView()
}
