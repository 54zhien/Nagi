//
//  SharePresenter.swift
//  Nagi
//
//  用 UIKit 的 rootViewController 直接 present UIActivityViewController（系统原生分享面板），
//  绕开 SwiftUI .sheet 双重 modal 嵌套导致的空白问题。
//

import UIKit

enum SharePresenter {
    static func present(items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        root.present(activityVC, animated: true)
    }
}
