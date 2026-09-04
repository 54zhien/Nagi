import SwiftUI
import UIKit

enum NagiAppearanceSettings {
    static let liquidGlassEnabledKey = "appearance.liquidGlass.enabled"
    static let bookCardsUseLiquidGlassKey = "appearance.liquidGlass.bookCards"
    static let readerSettingsUseLiquidGlassKey = "appearance.liquidGlass.readerSettings"
    static let showTabBarLabelsKey = "appearance.tabBar.showLabels"
}

enum NagiGlassStyleStore {
    static var liquidGlassEnabled: Bool {
        UserDefaults.standard.object(
            forKey: NagiAppearanceSettings.liquidGlassEnabledKey
        ) as? Bool ?? true
    }

    static var usesNativeLiquidGlass: Bool {
        liquidGlassEnabled
    }
}

struct NagiWindowCornerInsets {
    let bottomLeading: CGSize
    let bottomTrailing: CGSize
}

func nagiWindowCornerInsets(for geometry: GeometryProxy) -> NagiWindowCornerInsets {
    NagiWindowCornerInsets(
        bottomLeading: geometry.containerCornerInsets.bottomLeading,
        bottomTrailing: geometry.containerCornerInsets.bottomTrailing
    )
}

private struct NagiGlassModifier<GlassShape: Shape>: ViewModifier {
    let shape: GlassShape
    let isInteractive: Bool
    let tint: Color?
    let isEnabled: Bool

    @Environment(\.accessibilityReduceTransparency)
    private var reduceTransparency
    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    func body(content: Content) -> some View {
        if !isEnabled {
            content
        } else if !liquidGlassEnabled || reduceTransparency {
            content
                .background(
                    shape.fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay {
                    shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            content.glassEffect(nativeGlass, in: shape)
        }
    }

    private var nativeGlass: Glass {
        var effect = Glass.regular
        if let tint {
            effect = effect.tint(tint)
        }
        if isInteractive {
            effect = effect.interactive()
        }
        return effect
    }
}

private struct NagiSafeAreaBarModifier<BarContent: View>: ViewModifier {
    let edge: VerticalEdge
    let alignment: HorizontalAlignment
    let spacing: CGFloat?
    let barContent: () -> BarContent

    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if liquidGlassEnabled {
            content.safeAreaBar(
                edge: edge,
                alignment: alignment,
                spacing: spacing,
                content: barContent
            )
        } else {
            content.safeAreaInset(
                edge: edge,
                alignment: alignment,
                spacing: spacing,
                content: barContent
            )
        }
    }
}

private struct NagiScrollEdgeEffectModifier: ViewModifier {
    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if liquidGlassEnabled {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

extension View {
    func nagiGlass<GlassShape: Shape>(
        in shape: GlassShape,
        interactive: Bool = false,
        tint: Color? = nil,
        enabled: Bool = true
    ) -> some View {
        modifier(
            NagiGlassModifier(
                shape: shape,
                isInteractive: interactive,
                tint: tint,
                isEnabled: enabled
            )
        )
    }

    func nagiSafeAreaBar<BarContent: View>(
        edge: VerticalEdge,
        alignment: HorizontalAlignment = .center,
        spacing: CGFloat? = nil,
        @ViewBuilder content: @escaping () -> BarContent
    ) -> some View {
        modifier(
            NagiSafeAreaBarModifier(
                edge: edge,
                alignment: alignment,
                spacing: spacing,
                barContent: content
            )
        )
    }

    func nagiScrollEdgeEffectStyle() -> some View {
        modifier(NagiScrollEdgeEffectModifier())
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func nagiSharedBackgroundVisibilityHidden() -> some ToolbarContent {
        if NagiGlassStyleStore.usesNativeLiquidGlass {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
