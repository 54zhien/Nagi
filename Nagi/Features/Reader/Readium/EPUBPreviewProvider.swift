import Foundation

/// Owns the reader's chapter preview: which resource is loaded, the excerpt
/// text and the loading flag.
@MainActor
final class EPUBPreviewProvider {
    private(set) var text = ""
    private(set) var chapterTitle = ""
    private(set) var isLoading = false

    private var task: Task<Void, Never>?
    private var loadedHref: String?

    /// Called whenever the published state changes.
    var didChange: (() -> Void)?

    /// Loads the preview for a resource unless it is already loaded.
    ///
    /// `currentChapterTitle` is read once the content arrives, so the excerpt
    /// is labelled with the chapter the reader is on by then.
    func loadIfNeeded(
        href: String?,
        sourceURL: URL?,
        currentChapterTitle: @escaping () -> String
    ) {
        guard let href else {
            text = "暂时无法载入正文预览"
            return
        }

        let normalizedHref = EPUBResourcePath.normalize(href)
        guard loadedHref != normalizedHref else { return }
        loadedHref = normalizedHref
        task?.cancel()
        isLoading = true

        guard let sourceURL else {
            isLoading = false
            text = "暂时无法载入正文预览"
            didChange?()
            return
        }

        task = Task { [weak self] in
            let content = await Task.detached(priority: .userInitiated) {
                try? EPUBParser().loadChapterContent(url: sourceURL, href: normalizedHref)
            }.value

            guard !Task.isCancelled, let self else { return }
            self.isLoading = false
            guard let content, !content.isEmpty else {
                self.text = "暂时无法载入正文预览"
                self.didChange?()
                return
            }
            self.text = Self.excerpt(from: content)
            let title = currentChapterTitle()
            self.chapterTitle = title.isEmpty ? "当前章节" : title
            self.didChange?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Collapses the chapter body into the short excerpt shown in settings.
    nonisolated static func excerpt(from text: String) -> String {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let cleaned = (paragraphs.isEmpty ? text : paragraphs.joined(separator: "\n\n"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > 280 else { return cleaned }
        return String(cleaned.prefix(280)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
