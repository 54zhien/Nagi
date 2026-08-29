//
//  ReaderView.swift
//  Nagi
//
//  阅读器入口。阅读编排层负责生命周期、统一设置和 chrome，
//  TXT / EPUB 的正文渲染交给各自的 renderer。
//

import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let book: Book

    @State private var model: ReaderViewModel
    @State private var showControls = true
    @State private var interactionRevision = 0
    @State private var showSettings = false
    @State private var showTableOfContents = false
    @State private var showCustomSettings = false

    init(book: Book) {
        self.book = book
        _model = State(initialValue: ReaderViewModel(book: book))
    }

    var body: some View {
        ReaderChrome(
            title: model.title,
            titleColor: Color(uiColor: model.headerColor),
            readerBackground: Color(uiColor: model.backgroundColor),
            showsTitle: model.preferences.showBookTitleInPageHeader,
            showControls: $showControls,
            interactionRevision: $interactionRevision,
            onDismiss: dismissReader,
            onTableOfContents: { showTableOfContents = true },
            onSettings: { showSettings = true },
            onSwipeStart: hideControlsForSwipe
        ) {
            content
        }
        .task {
            model.updateSystemAppearance(isDark: colorScheme == .dark)
            await model.loadIfNeeded()
        }
        .onChange(of: colorScheme) { _, newValue in
            model.updateSystemAppearance(isDark: newValue == .dark)
        }
        .onDisappear {
            model.saveProgress()
            try? modelContext.save()
            model.tearDown()
        }
        .sheet(isPresented: $showSettings) {
            settingsSheet
        }
        .sheet(isPresented: $showTableOfContents) {
            ReaderTableOfContentsSheet(
                entries: model.chapters.map {
                    ReaderTOCItem(id: $0.id, title: $0.title, depth: $0.depth)
                },
                currentID: model.currentChapterID
            ) { item in
                guard let chapter = model.chapters.first(where: { $0.id == item.id }) else { return }
                model.selectChapter(at: chapter.index)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        model.makeContentView(
            onToggleControls: toggleControls,
            onSwipeStart: hideControlsForSwipe
        )
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                guard model.handlesContentTap else { return }
                noteInteraction()
                toggleControls()
            }
        )
        .accessibilityAction(
            named: Text(showControls ? "隐藏阅读控件" : "显示阅读控件")
        ) {
            noteInteraction()
            toggleControls()
        }
    }

    @ViewBuilder
    private var settingsSheet: some View {
        NavigationStack {
            MediumReaderSettingsView(
                model: model,
                onCustomSettings: {
                    showCustomSettings = true
                }
            )
            .navigationTitle("主题与排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showCustomSettings) {
            CustomReaderSettingsSheet(
                initialDraft: model.makeCustomizationDraft(),
                previewText: model.previewText,
                previewChapterTitle: model.previewChapterTitle,
                bookTitle: model.title,
                fontSize: model.preferences.fontSize,
                previewContentColor: model.contentColor,
                previewBackgroundColor: model.backgroundColor,
                isLoadingPreview: model.isLoadingPreview,
                onCommit: { model.apply($0) }
            )
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls.toggle()
        }
    }

    private func hideControlsForSwipe() {
        guard showControls else { return }
        withAnimation(.easeOut(duration: 0.16)) {
            showControls = false
        }
    }

    private func noteInteraction() {
        interactionRevision &+= 1
    }

    private func dismissReader() {
        model.saveProgress()
        try? modelContext.save()
        dismiss()
    }
}
