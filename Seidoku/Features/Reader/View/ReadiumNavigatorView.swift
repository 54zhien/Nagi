//
//  ReadiumNavigatorView.swift
//  Seidoku
//
//  将 Readium 的 UIKit Navigator 嵌入 SwiftUI。
//

import ReadiumNavigator
import SwiftUI

struct ReadiumNavigatorView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator
    }

    func updateUIViewController(_ uiViewController: EPUBNavigatorViewController, context: Context) {}
}


