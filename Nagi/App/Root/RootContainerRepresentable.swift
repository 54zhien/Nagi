//
//  RootContainerRepresentable.swift
//  Nagi
//
//  SwiftUI entry bridge for the persistent UIKit root.
//

import SwiftUI
import UIKit

struct RootContainerRepresentable: UIViewControllerRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    typealias UIViewControllerType = RootContainerViewController
    typealias Coordinator = Void

    func makeUIViewController(context: Context) -> RootContainerViewController {
        RootContainerViewController(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    func updateUIViewController(
        _ uiViewController: RootContainerViewController,
        context: Context
    ) {
        uiViewController.updateAccessibility(
            reduceMotion: reduceMotion,
            reduceTransparency: reduceTransparency
        )
    }

    static func dismantleUIViewController(
        _ uiViewController: RootContainerViewController,
        coordinator: ()
    ) {
        uiViewController.dismantle()
    }
}
