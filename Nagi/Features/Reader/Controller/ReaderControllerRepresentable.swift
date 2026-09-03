
import SwiftUI
import UIKit

struct ReaderChromeCornerInsets: Equatable {
    let bottomLeading: CGSize
    let bottomTrailing: CGSize
}

struct ReaderControllerRepresentable: UIViewControllerRepresentable {
    let model: ReaderViewModel
    let stateRevision: Int
    let title: String
    let titleColor: UIColor
    let readerBackground: UIColor
    let titleFontFamily: ReaderFontFamily
    let showsTitle: Bool
    let reduceMotion: Bool
    let cornerInsets: ReaderChromeCornerInsets
    let onDismiss: () -> Void
    let onTableOfContents: () -> Void
    let onSettings: () -> Void
    let transitionCoordinator: ReaderTransitionCoordinator

    typealias UIViewControllerType = ReaderViewController
    typealias Coordinator = Void

    func makeUIViewController(context: Context) -> ReaderViewController {
        ReaderViewController(
            model: model,
            title: title,
            titleColor: titleColor,
            readerBackground: readerBackground,
            titleFontFamily: titleFontFamily,
            showsTitle: showsTitle,
            reduceMotion: reduceMotion,
            cornerInsets: cornerInsets,
            onDismiss: onDismiss,
            onTableOfContents: onTableOfContents,
            onSettings: onSettings,
            transitionCoordinator: transitionCoordinator
        )
    }

    func updateUIViewController(
        _ uiViewController: ReaderViewController,
        context: Context
    ) {
        uiViewController.update(
            stateRevision: stateRevision,
            title: title,
            titleColor: titleColor,
            readerBackground: readerBackground,
            titleFontFamily: titleFontFamily,
            showsTitle: showsTitle,
            reduceMotion: reduceMotion,
            cornerInsets: cornerInsets,
            onDismiss: onDismiss,
            onTableOfContents: onTableOfContents,
            onSettings: onSettings
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: ReaderViewController,
        coordinator: Void
    ) {
        uiViewController.dismantle()
    }
}
