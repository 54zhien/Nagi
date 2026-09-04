import SwiftData
import SwiftUI
import UIKit

struct ReaderView: View {
    @Environment(\.colorScheme) private var colorScheme

    let book: Book

    @State private var model: ReaderViewModel?
    @State private var systemBrightness = 0.5
    @State private var brightnessBeforeReader: CGFloat?

    var body: some View {
        Group {
            if let model {
                ReaderSessionView(model: model, systemBrightness: $systemBrightness)
            } else {
                ReaderLoadingView(bookTitle: book.title)
            }
        }
        .task(id: book.id) {
            if model?.book.id != book.id {
                model = nil
            }
            guard model == nil else { return }

            // Let the presentation reach its first frame before opening Readium.
            await Task.yield()
            guard !Task.isCancelled else { return }

            let nextModel = ReaderViewModel(book: book)
            nextModel.updateSystemAppearance(isDark: colorScheme == .dark)
            model = nextModel

            // Show the loading state before creating the navigator.
            await Task.yield()
            guard !Task.isCancelled else { return }

            await nextModel.loadIfNeeded()
        }
        .onAppear {
            beginSystemBrightnessSession()
        }
        .onChange(of: systemBrightness) { _, newValue in
            guard brightnessBeforeReader != nil else { return }
            UIScreen.main.brightness = CGFloat(min(max(newValue, 0), 1))
        }
        .onDisappear {
            restoreSystemBrightness()
        }
    }

    private func beginSystemBrightnessSession() {
        guard brightnessBeforeReader == nil else { return }
        let currentBrightness = UIScreen.main.brightness
        brightnessBeforeReader = currentBrightness
        systemBrightness = Double(currentBrightness)
    }

    private func restoreSystemBrightness() {
        guard let brightnessBeforeReader else { return }
        UIScreen.main.brightness = brightnessBeforeReader
        self.brightnessBeforeReader = nil
    }
}

private struct ReaderLoadingView: View {
    let bookTitle: String

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)

            ProgressView("正在打开阅读器…")
                .accessibilityLabel("正在打开 \(bookTitle)")
        }
        .ignoresSafeArea()
    }
}

private struct ReaderSessionView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let model: ReaderViewModel
    @Binding var systemBrightness: Double
    @State private var showSettings = false
    @State private var showTableOfContents = false
    @State private var showCustomSettings = false
    @State private var transitionCoordinator = ReaderTransitionCoordinator()
    @State private var foregroundRestoreRevision = 0

    var body: some View {
        GeometryReader { geometry in
            ReaderControllerRepresentable(
                model: model,
                stateRevision: model.stateRevision,
                title: model.title,
                titleColor: model.headerColor,
                readerBackground: model.backgroundColor,
                titleFontFamily: model.preferences.fontFamily,
                showsTitle: model.preferences.showBookTitleInPageHeader,
                reduceMotion: reduceMotion,
                cornerInsets: ReaderChromeCornerInsets(
                    bottomLeading: geometry.containerCornerInsets.bottomLeading,
                    bottomTrailing: geometry.containerCornerInsets.bottomTrailing
                ),
                onDismiss: dismissReader,
                onTableOfContents: { showTableOfContents = true },
                onSettings: { showSettings = true },
                transitionCoordinator: transitionCoordinator
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .all)
        .statusBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
        .onChange(of: colorScheme) { _, newValue in
            guard model.preferences.appearanceMode == .system else { return }
            transitionCoordinator.begin(kind: .theme, reduceMotion: reduceMotion)
            model.updateSystemAppearance(isDark: newValue == .dark)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            foregroundRestoreRevision &+= 1
        }
        .task(id: foregroundRestoreRevision) {
            guard foregroundRestoreRevision > 0 else { return }
            await model.restoreFromForeground(isDark: colorScheme == .dark)
        }
        .onChange(of: model.stateRevision) { _, _ in
            transitionCoordinator.readerStateDidUpdate { kind in
                await model.waitForVisualUpdate(for: kind)
            }
        }
        .onDisappear {
            transitionCoordinator.cancel()
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
    private var settingsSheet: some View {
        NavigationStack {
            ReaderSettingsViewControllerRepresentable(
                model: model,
                preferences: model.preferences,
                systemBrightness: systemBrightness,
                isDarkAppearance: isDarkAppearance,
                reduceMotion: reduceMotion,
                onCustomSettings: {
                    showCustomSettings = true
                },
                onBeforeMutation: { kind in
                    transitionCoordinator.begin(kind: kind, reduceMotion: reduceMotion)
                },
                onSystemBrightnessChanged: { value in
                    systemBrightness = value
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("主题与排版")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showSettings = false
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                            .contentShape(Circle())
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
                    .accessibilityLabel("关闭主题与排版")
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
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
                onCommit: {
                    transitionCoordinator.begin(
                        kind: model.visualMutationKind(for: $0),
                        reduceMotion: reduceMotion
                    )
                    model.apply($0)
                }
            )
        }
    }

    private var isDarkAppearance: Bool {
        switch model.preferences.appearanceMode {
        case .light:
            return false
        case .dark:
            return true
        case .system:
            return colorScheme == .dark
        }
    }

    private func dismissReader() {
        model.saveProgress()
        try? modelContext.save()
        dismiss()
    }
}
