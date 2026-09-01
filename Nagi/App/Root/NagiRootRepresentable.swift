//
//  NagiRootRepresentable.swift
//  Nagi
//
//  SwiftUI 只负责把持久化 UIKit Root 挂进 WindowGroup；不会在外层
//  再包 TabView、searchable、ignoresSafeArea 或额外的 safe-area padding。
//

import SwiftUI

struct NagiRootRepresentable: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeUIViewController(context: Context) -> NagiRootViewController {
        NagiRootViewController(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    func updateUIViewController(_ viewController: NagiRootViewController, context: Context) {
        viewController.updateAccessibility(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    static func dismantleUIViewController(_ viewController: NagiRootViewController, coordinator: ()) {
        viewController.stopKeyboardObservation()
    }
}
