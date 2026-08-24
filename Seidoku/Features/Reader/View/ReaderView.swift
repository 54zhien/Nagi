//
//  ReaderView.swift
//  Seidoku
//
//  阅读器主视图：三种翻页模式 + 工具栏 + 排版设置 + 目录。
//

import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ReaderViewModel
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showTOC = false

    init(book: Book) {
        _viewModel = State(initialValue: ReaderViewModel(book: book))
    }

    var body: some View {
        GeometryReader { geo in
            content
                .onAppear {
                    viewModel.pageSize = geo.size
                    Task { await viewModel.load() }
                }
                .onChange(of: geo.size) { _, newSize in
                    viewModel.pageSize = newSize
                }
        }
        .background(viewModel.theme.background)
        .ignoresSafeArea()
        .overlay(alignment: .top) { if showControls { topBar } }
        .overlay(alignment: .bottom) { if showControls { bottomBar } }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showTOC) { tocSheet }
        .statusBarHidden(!showControls)
    }

    // MARK: - 正文内容（三模式）

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = viewModel.errorMessage {
            ContentUnavailableView(
                "无法打开",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if viewModel.pages.isEmpty {
            ContentUnavailableView("暂无内容", systemImage: "book")
        } else {
            switch viewModel.transition {
            case .pageCurl:
                PageViewController(
                    pages: viewModel.pages,
                    transitionStyle: .pageCurl,
                    insets: readerInsets,
                    background: viewModel.theme.background,
                    currentPage: $viewModel.currentPageIndex
                )
            case .horizontal:
                PageViewController(
                    pages: viewModel.pages,
                    transitionStyle: .scroll,
                    insets: readerInsets,
                    background: viewModel.theme.background,
                    currentPage: $viewModel.currentPageIndex
                )
            case .vertical:
                ScrollableTextView(attributedText: viewModel.fullText, insets: readerInsets)
            }
        }
    }

    private var readerInsets: UIEdgeInsets {
        UIEdgeInsets(top: 24, left: viewModel.horizontalInset, bottom: 24, right: viewModel.horizontalInset)
    }

    // MARK: - 工具栏

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("返回")

            Spacer()

            VStack(spacing: 2) {
                Text(viewModel.book.title)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(viewModel.currentChapter?.title ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "textformat.size")
            }
            .accessibilityLabel("排版设置")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                showTOC = true
            } label: {
                Image(systemName: "list.bullet")
            }
            .accessibilityLabel("目录")

            Spacer()

            Text("\(viewModel.currentPageIndex + 1) / \(viewModel.pages.count)")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("设置")
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - 设置面板

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("字号") {
                    HStack {
                        Text("小")
                        Slider(value: $viewModel.fontSize, in: 12...30, step: 1)
                        Text("大")
                    }
                }
                Section("行距") {
                    Slider(value: $viewModel.lineSpacing, in: 0...16, step: 1)
                }
                Section("主题") {
                    Picker("主题", selection: $viewModel.theme) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.label).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("翻页方式") {
                    Picker("翻页方式", selection: $viewModel.transition) {
                        ForEach(PageTransitionMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - 目录

    private var tocSheet: some View {
        NavigationStack {
            List(viewModel.chapters) { chapter in
                Button {
                    viewModel.currentChapterIndex = chapter.index
                    showTOC = false
                    Task { await viewModel.loadCurrentChapter() }
                } label: {
                    HStack {
                        Text(chapter.title)
                            .foregroundColor(chapter.index == viewModel.currentChapterIndex ? .accentColor : .primary)
                        Spacer()
                        if chapter.index == viewModel.currentChapterIndex {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showTOC = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// 上下滚动模式：整章文本可滚动。
struct ScrollableTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let insets: UIEdgeInsets

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.isScrollEnabled = true
        textView.isEditable = false
        textView.isSelectable = false
        textView.backgroundColor = .clear
        textView.textContainer.lineFragmentPadding = 0
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        textView.textContainerInset = insets
        textView.attributedText = attributedText
    }
}
