
import SwiftUI
import UIKit

enum NagiGlassStyle: String, CaseIterable, Identifiable {
    case liquid
    case translucent

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liquid:
            return "Liquid Glass"
        case .translucent:
            return "半透明兼容"
        }
    }
}

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
        guard liquidGlassEnabled else { return false }
        if #available(iOS 26.0, *) {
            return true
        }
        return false
    }

    static var effectiveStyle: NagiGlassStyle {
        usesNativeLiquidGlass ? .liquid : .translucent
    }
}

struct NagiWindowCornerInsets {
    let bottomLeading: CGSize
    let bottomTrailing: CGSize
}

func nagiWindowCornerInsets(for geometry: GeometryProxy) -> NagiWindowCornerInsets {
    if #available(iOS 26.0, *) {
        return NagiWindowCornerInsets(
            bottomLeading: geometry.containerCornerInsets.bottomLeading,
            bottomTrailing: geometry.containerCornerInsets.bottomTrailing
        )
    }

    let bottom = geometry.safeAreaInsets.bottom
    return NagiWindowCornerInsets(
        bottomLeading: CGSize(
            width: geometry.safeAreaInsets.leading,
            height: bottom
        ),
        bottomTrailing: CGSize(
            width: geometry.safeAreaInsets.trailing,
            height: bottom
        )
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
        } else if reduceTransparency {
            fallback(content, opaque: true)
        } else if #available(iOS 26.0, *), liquidGlassEnabled {
            content.glassEffect(nativeGlass, in: shape)
        } else {
            fallback(content, opaque: false)
        }
    }

    @available(iOS 26.0, *)
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

    @ViewBuilder
    private func fallback(_ content: Content, opaque: Bool) -> some View {
        if opaque {
            content
                .background(
                    shape.fill(Color(uiColor: .secondarySystemBackground))
                )
                .overlay {
                    shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.16))
                    }
                }
                .overlay {
                    shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                }
        }
    }
}

struct NagiGlassEffectContainer<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    init(
        spacing: CGFloat = 0,
        @ViewBuilder content: () -> Content
    ) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *), liquidGlassEnabled {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
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
        if #available(iOS 26.0, *), liquidGlassEnabled {
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
        if #available(iOS 26.0, *), liquidGlassEnabled {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}

private struct NagiSharedBackgroundVisibilityModifier: ViewModifier {
    @AppStorage(NagiAppearanceSettings.liquidGlassEnabledKey)
    private var liquidGlassEnabled = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), liquidGlassEnabled {
            content.sharedBackgroundVisibility(.hidden)
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

    func nagiSharedBackgroundVisibilityHidden() -> some View {
        modifier(NagiSharedBackgroundVisibilityModifier())
    }
}
