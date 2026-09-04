
import SwiftUI
import UIKit

struct CustomReaderSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NagiAppearanceSettings.readerSettingsUseLiquidGlassKey)
    private var readerSettingsUseLiquidGlass = true

    let initialDraft: ReaderCustomizationDraft
    let previewText: String
    let previewChapterTitle: String
    let bookTitle: String
    let fontSize: Double
    let previewContentColor: UIColor
    let previewBackgroundColor: UIColor
    let isLoadingPreview: Bool
    let onCommit: (ReaderCustomizationDraft) -> Void

    @State private var draft: ReaderCustomizationDraft
    @State private var showDiscardConfirmation = false
    @State private var didFinish = false

    private enum Layout {
        static let previewHeight: CGFloat = 228
        static let previewMaskHeight: CGFloat = 32
        static let cardCornerRadius: CGFloat = 22
        static let rowHeight: CGFloat = 60
        static let cardHorizontalPadding: CGFloat = 20
        static let sliderValueWidth: CGFloat = 58
    }

    private enum LayoutSymbol {
        static let lineSpacing = ReaderSystemSymbol.name(
            "arrow.up.and.down.text.horizontal",
            fallback: "arrow.up.and.down"
        )
        static let characterSpacing = ReaderSystemSymbol.name(
            "textformat.abc",
            fallback: "character"
        )
        static let wordSpacing = ReaderSystemSymbol.name(
            "text.word.spacing",
            fallback: "text.alignleft"
        )
        static let pageMargins = ReaderSystemSymbol.name(
            "rectangle.portrait.inset.filled",
            fallback: "rectangle.portrait"
        )
    }

    private static let previewSampleText = """
    一切都像刚睡醒的样子，欣欣然张开了眼。山朗润起来了，水涨起来了，太阳的脸红起来了。

    小草偷偷地从土里钻出来，嫩嫩的，绿绿的。园子里，田野里，瞧去，一大片一大片满是的。风轻悄悄的，草软绵绵的。

    桃树、杏树、梨树，你不让我，我不让你，都开满了花赶趟儿。红的像火，粉的像霞，白的像雪。花里带着甜味；闭了眼，树上仿佛已经满是桃儿、杏儿、梨儿！
    """

    init(
        initialDraft: ReaderCustomizationDraft,
        previewText: String,
        previewChapterTitle: String,
        bookTitle: String,
        fontSize: Double,
        previewContentColor: UIColor,
        previewBackgroundColor: UIColor,
        isLoadingPreview: Bool,
        onCommit: @escaping (ReaderCustomizationDraft) -> Void
    ) {
        self.initialDraft = initialDraft
        self.previewText = previewText
        self.previewChapterTitle = previewChapterTitle
        self.bookTitle = bookTitle
        self.fontSize = fontSize
        self.previewContentColor = previewContentColor
        self.previewBackgroundColor = previewBackgroundColor
        self.isLoadingPreview = isLoadingPreview
        self.onCommit = onCommit
        _draft = State(initialValue: initialDraft)
    }

    private var isDirty: Bool { draft != initialDraft }

    private var nagiAccentColor: Color {
        Color("AccentColor")
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                ScrollView {
                    settingsContent
                        .padding(.horizontal, 16)
                        .padding(.top, Layout.previewHeight + 18)
                        .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)

                preview
                    .frame(maxWidth: .infinity)
                    .frame(height: Layout.previewHeight, alignment: .topLeading)
                    .background(Color(uiColor: previewBackgroundColor))
                    .overlay(alignment: .bottom) {
                        previewBottomMask
                    }
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(uiColor: .separator))
                            .frame(height: 1)
                            .allowsHitTesting(false)
                    }
                    .clipped()
                    .allowsHitTesting(false)
                    .zIndex(1)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("自定义主题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(uiColor: previewBackgroundColor), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(previewColorScheme, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .nagiGlass(
                        in: Circle(),
                        interactive: true,
                        enabled: readerSettingsUseLiquidGlass
                    )
                    .accessibilityLabel("取消")
                }
                .nagiSharedBackgroundVisibilityHidden()
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: commit) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .nagiGlass(
                        in: Circle(),
                        interactive: true,
                        tint: nagiAccentColor,
                        enabled: readerSettingsUseLiquidGlass
                    )
                    .accessibilityLabel("完成")
                }
                .nagiSharedBackgroundVisibilityHidden()
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isDirty && !didFinish)
        .confirmationDialog("放弃修改？", isPresented: $showDiscardConfirmation, titleVisibility: .visible) {
            Button("放弃修改", role: .destructive) {
                didFinish = true
                dismiss()
            }
            Button("继续编辑", role: .cancel) {}
        } message: {
            Text("尚未保存的文字和布局调整将被丢弃。")
        }
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 28) {
            settingsSection("文本") {
                VStack(spacing: 0) {
                    fontMenu
                    cardDivider
                    Toggle(isOn: $draft.boldText) {
                        Label {
                            Text("粗体文本")
                        } icon: {
                            Image(systemName: "bold")
                                .font(.system(size: 18, weight: .semibold))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(nagiAccentColor)
                        }
                        .font(.body)
                        .foregroundStyle(.primary)
                    }
                        .frame(maxWidth: .infinity, minHeight: Layout.rowHeight)
                        .padding(.horizontal, Layout.cardHorizontalPadding)
                        .contentShape(Rectangle())
                        .tint(nagiAccentColor)
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                )
            }

            settingsSection("布局选项") {
                VStack(spacing: 0) {
                    Toggle("保留出版方样式", isOn: $draft.publisherStyles)
                        .frame(minHeight: Layout.rowHeight)
                        .padding(.horizontal, Layout.cardHorizontalPadding)
                        .contentShape(Rectangle())

                    cardDivider

                    slider(
                        "行间距",
                        systemImage: LayoutSymbol.lineSpacing,
                        value: $draft.lineHeight,
                        range: ReaderLayoutMetrics.lineHeightRange,
                        step: 0.05,
                        text: String(format: "%.2f", draft.lineHeight)
                    )
                    .disabled(draft.publisherStyles)

                    cardDivider

                    slider(
                        "字符间距",
                        systemImage: LayoutSymbol.characterSpacing,
                        value: $draft.characterSpacing,
                        range: ReaderLayoutMetrics.characterSpacingRange,
                        step: 1,
                        text: "\(Int(draft.characterSpacing))%"
                    )
                    .disabled(draft.publisherStyles)

                    cardDivider

                    slider(
                        "词间距",
                        systemImage: LayoutSymbol.wordSpacing,
                        value: $draft.wordSpacing,
                        range: ReaderLayoutMetrics.wordSpacingRange,
                        step: 2,
                        text: "\(Int(draft.wordSpacing))%"
                    )
                    .disabled(draft.publisherStyles)

                    cardDivider

                    slider(
                        "页边空白",
                        systemImage: LayoutSymbol.pageMargins,
                        value: $draft.pageMargins,
                        range: ReaderLayoutMetrics.pageMarginsRange,
                        step: ReaderLayoutMetrics.pageMarginsStep,
                        text: "\(Int(draft.pageMargins.rounded())) pt"
                    )
                }
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: Layout.cardCornerRadius, style: .continuous)
                )

                Text("正文上下留白由系统安全区和页眉实际占用决定；首行缩进固定为 2；页边空白按设置调节。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func settingsSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)

            content()
        }
    }

    private var cardDivider: some View {
        Divider()
            .padding(.leading, Layout.cardHorizontalPadding)
    }

    private var preview: some View {
        Text(Self.previewSampleText)
            .font(previewFont)
            .fontWeight(draft.boldText ? .bold : .regular)
            .kerning(ReaderLayoutMetrics.spacingPoints(for: draft.characterSpacing))
            .lineSpacing(CGFloat(draft.lineHeight - 1) * 8)
            .padding(.horizontal, previewPageMarginInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .foregroundStyle(Color(uiColor: previewContentColor))
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("正文预览")
    }

    private var previewColorScheme: ColorScheme {
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        if previewBackgroundColor.getWhite(&white, alpha: &alpha) {
            return white < 0.5 ? .dark : .light
        }

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        guard previewBackgroundColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return .light
        }

        let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
        return luminance < 0.5 ? .dark : .light
    }

    private var previewBottomMask: some View {
        LinearGradient(
            stops: [
                .init(color: Color(uiColor: previewBackgroundColor), location: 0),
                .init(color: Color(uiColor: previewBackgroundColor).opacity(0.92), location: 0.55),
                .init(color: Color(uiColor: previewBackgroundColor).opacity(0), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: Layout.previewMaskHeight)
        .allowsHitTesting(false)
    }

    private var previewPageMarginInset: CGFloat {
        max(ReaderLayoutMetrics.pageBlankInset(for: draft.pageMargins) - 16, 0)
    }

    private var previewFont: Font {
        let size = CGFloat(min(max(fontSize, 8), 42))
        return draft.fontFamily.swiftUIFont(ofSize: size)
    }

    private var fontMenu: some View {
        Menu {
            ForEach(ReaderFontFamily.options) { family in
                Button {
                    draft.fontFamily = family
                } label: {
                    HStack(spacing: 10) {
                        Text(family.label)
                            .font(family.swiftUIFont(ofSize: 17))
                        Spacer(minLength: 16)
                        Image(systemName: family == draft.fontFamily ? "checkmark" : "textformat")
                            .font(.body.weight(.semibold))
                    }
                }
                .accessibilityLabel(family.label)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "textformat")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(nagiAccentColor)
                    .accessibilityHidden(true)

                Text("字体")
                    .font(.body)
                    .foregroundStyle(.primary)

                Spacer()
                Text(draft.fontFamily.label)
                    .font(draft.fontFamily.swiftUIFont(ofSize: 16))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Layout.rowHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .padding(.horizontal, Layout.cardHorizontalPadding)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel("字体")
        .accessibilityValue(draft.fontFamily.label)
    }

    private func slider(
        _ title: String,
        systemImage: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        text: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                Spacer()
            }
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28, height: 24)
                    .foregroundStyle(nagiAccentColor)
                    .accessibilityHidden(true)

                Slider(value: value, in: range, step: step)
                    .tint(nagiAccentColor)

                Text(text)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: Layout.sliderValueWidth, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Layout.cardHorizontalPadding)
        .padding(.vertical, 18)
    }

    private func cancel() {
        guard isDirty else {
            didFinish = true
            dismiss()
            return
        }
        showDiscardConfirmation = true
    }

    private func commit() {
        didFinish = true
        onCommit(draft)
        dismiss()
    }
}
