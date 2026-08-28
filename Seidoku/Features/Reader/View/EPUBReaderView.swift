//
//  EPUBReaderView.swift
//  Seidoku
//
//  Readium EPUB 阅读界面：内容优先的控制栏、目录和排版设置。
//

import SwiftUI

struct EPUBReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var model: EPUBReaderModel
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showTableOfContents = false

    init(book: Book) {
        _model = State(initialValue: EPUBReaderModel(book: book))
    }

    var body: some View {
        ZStack {
            content
                .ignoresSafeArea()

            if showControls {
                controls
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showControls)
        .task {
            model.onToggleControls = toggleControls
            await model.loadIfNeeded()
        }
        .onDisappear {
            model.onToggleControls = nil
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showTableOfContents) { tableOfContentsSheet }
        .alert(
            "阅读失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if let navigator = model.navigator {
            ReadiumNavigatorView(navigator: navigator)
        } else if model.isLoading {
            ProgressView("正在打开 EPUB…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
        } else {
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "无法显示内容",
                    systemImage: "book.closed",
                    description: Text(model.errorMessage ?? "EPUB 没有可阅读内容")
                )

                Button("重试") {
                    Task { await model.loadIfNeeded() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                controlButton("返回", systemImage: "chevron.left") { dismiss() }

                VStack(spacing: 1) {
                    Text(model.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !model.chapterTitle.isEmpty {
                        Text(model.chapterTitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity)

                controlButton("排版设置", systemImage: "textformat.size") {
                    showSettings = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
            .background(.regularMaterial)

            Spacer()

            HStack(spacing: 24) {
                controlButton("目录", systemImage: "list.bullet") {
                    showTableOfContents = true
                }

                controlButton("上一页", systemImage: "chevron.left") {
                    model.goBackward()
                }

                Text(model.progress, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 44)
                    .accessibilityLabel("阅读进度")

                controlButton("下一页", systemImage: "chevron.right") {
                    model.goForward()
                }

                controlButton("排版设置", systemImage: "gearshape") {
                    showSettings = true
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .background(.regularMaterial)
        }
    }

    private func controlButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("阅读方式") {
                    Picker("阅读方式", selection: $model.flowMode) {
                        ForEach(EPUBFlowMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("文字") {
                    Picker("字体", selection: $model.fontFamily) {
                        ForEach(EPUBFontFamily.allCases) { family in
                            Text(family.label).tag(family)
                        }
                    }

                    LabeledContent("字号", value: "\(Int(model.fontScale * 100))%")
                    Slider(value: $model.fontScale, in: 0.8 ... 2.0, step: 0.05)

                    LabeledContent("行高", value: model.lineHeight.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.lineHeight, in: 1.0 ... 2.0, step: 0.1)

                    LabeledContent("首行缩进", value: model.paragraphIndent.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.paragraphIndent, in: 0 ... 3.0, step: 0.5)
                }

                Section("页面") {
                    LabeledContent("页边距", value: model.pageMargins.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: $model.pageMargins, in: 0.5 ... 2.0, step: 0.1)

                    Picker("主题", selection: $model.theme) {
                        ForEach(EPUBReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    Toggle("保留出版方样式", isOn: $model.publisherStyles)
                } footer: {
                    Text("关闭后，字号、行高和缩进等个性化设置会更稳定。")
                }

                Section {
                    Button("恢复默认排版") { model.resetTypography() }
                }
            }
            .navigationTitle("EPUB 阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var tableOfContentsSheet: some View {
        NavigationStack {
            Group {
                if model.tableOfContents.isEmpty {
                    ContentUnavailableView("没有目录", systemImage: "list.bullet")
                } else {
                    List(model.tableOfContents) { entry in
                        Button {
                            model.go(to: entry)
                            showTableOfContents = false
                        } label: {
                            Text(entry.title)
                                .foregroundStyle(.primary)
                                .padding(.leading, CGFloat(entry.depth) * 16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showTableOfContents = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func toggleControls() {
        if reduceMotion {
            showControls.toggle()
        } else {
            withAnimation(.easeInOut(duration: 0.18)) {
                showControls.toggle()
            }
        }
    }
}


