//
//  ReadiumNavigatorView.swift
//  Nagi
//
//  将 Readium 的 UIKit Navigator 嵌入 SwiftUI。
//

import ReadiumNavigator
import SwiftUI
import UIKit

struct ReadiumNavigatorView: UIViewControllerRepresentable {
    let navigator: EPUBNavigatorViewController
    let background: SwiftUI.Color

    func makeUIViewController(context: Context) -> EPUBNavigatorViewController {
        navigator.view.backgroundColor = UIColor(background)
        return navigator
    }

    func updateUIViewController(
        _ uiViewController: EPUBNavigatorViewController,
        context: Context
    ) {
        uiViewController.view.backgroundColor = UIColor(background)
    }
}
