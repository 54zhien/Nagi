//
//  PageViewController.swift
//  Nagi
//
//  UIPageViewController 包装：支持仿真翻页(.pageCurl) 与覆盖翻页(.scroll)。
//

import SwiftUI
import UIKit

struct PageViewController: UIViewControllerRepresentable {
    let pages: [NSAttributedString]
    let transitionStyle: UIPageViewController.TransitionStyle
    let insets: UIEdgeInsets
    let background: Color
    @Binding var currentPage: Int
    let onSwipeStart: (() -> Void)?

    init(
        pages: [NSAttributedString],
        transitionStyle: UIPageViewController.TransitionStyle,
        insets: UIEdgeInsets,
        background: Color,
        currentPage: Binding<Int>,
        onSwipeStart: (() -> Void)? = nil
    ) {
        self.pages = pages
        self.transitionStyle = transitionStyle
        self.insets = insets
        self.background = background
        self._currentPage = currentPage
        self.onSwipeStart = onSwipeStart
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageVC = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: [.spineLocation: UIPageViewController.SpineLocation.none.rawValue]
        )
        pageVC.dataSource = context.coordinator
        pageVC.delegate = context.coordinator
        pageVC.view.backgroundColor = UIColor(background)
        guard !pages.isEmpty else { return pageVC }

        let initial = max(0, min(currentPage, pages.count - 1))
        pageVC.setViewControllers(
            [context.coordinator.hostingController(at: initial)],
            direction: .forward,
            animated: false
        )
        return pageVC
    }

    func updateUIViewController(_ pageVC: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        guard !pages.isEmpty else { return }
        // 外部 currentPage 变化（目录跳转等）时同步
        if let current = pageVC.viewControllers?.first as? UIHostingController<PageTextView>,
           let index = context.coordinator.index(of: current),
           index != currentPage {
            let target = max(0, min(currentPage, pages.count - 1))
            pageVC.setViewControllers(
                [context.coordinator.hostingController(at: target)],
                direction: index < target ? .forward : .reverse,
                animated: false
            )
        }
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: PageViewController
        private var controllers: [Int: UIHostingController<PageTextView>] = [:]

        init(_ parent: PageViewController) {
            self.parent = parent
        }

        func hostingController(at index: Int) -> UIHostingController<PageTextView> {
            if let existing = controllers[index] { return existing }
            let page = parent.pages[index]
            let view = PageTextView(attributedText: page, insets: parent.insets)
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = UIColor(parent.background)
            controllers[index] = host
            return host
        }

        func index(of controller: UIViewController) -> Int? {
            controllers.first { $0.value === controller }?.key
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController), index > 0 else { return nil }
            return hostingController(at: index - 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            parent.onSwipeStart?()
        }

        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let index = index(of: viewController), index < parent.pages.count - 1 else { return nil }
            return hostingController(at: index + 1)
        }

        func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let current = pageViewController.viewControllers?.first,
                  let index = index(of: current) else { return }
            parent.currentPage = index
        }
    }
}
