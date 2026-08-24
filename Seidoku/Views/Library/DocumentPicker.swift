//
//  DocumentPicker.swift
//  Seidoku
//
//  用 UIKit 的 rootViewController.present 直接弹出 UIDocumentPickerViewController，
//  绕开 SwiftUI .sheet 与 UIKit picker 的双重 modal 嵌套（后者会导致 delegate 回调不触发）。
//

import SwiftUI
import UniformTypeIdentifiers

final class DocumentPickerCoordinator: NSObject, UIDocumentPickerDelegate {
    private let onPick: ([URL]) -> Void
    private let onCancel: () -> Void

    init(onPick: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
        self.onPick = onPick
        self.onCancel = onCancel
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        onPick(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onCancel()
    }
}

enum DocumentPickerPresenter {
    /// 从 key window 的 rootViewController present picker。
    @discardableResult
    static func present(
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        onPick: @escaping ([URL]) -> Void,
        onCancel: @escaping () -> Void = {}
    ) -> DocumentPickerCoordinator? {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else {
            return nil
        }

        let coordinator = DocumentPickerCoordinator(onPick: onPick, onCancel: onCancel)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = coordinator
        root.present(picker, animated: true)
        return coordinator
    }
}
