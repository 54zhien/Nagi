//
//  ShareSheet.swift
//  Seidoku
//
//  系统分享面板（UIActivityViewController 的 SwiftUI 包装）。
//

import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
