
import SwiftUI
import UIKit

struct PageViewController: UIViewControllerRepresentable {
    let pages: [NSAttributedString]
    let pageRanges: [NSRange]
    let transitionStyle: UIPageViewController.TransitionStyle
    let insets: UIEdgeInsets
    let background: Color
    @Binding var currentPage: Int
    let onSwipeStart: (() -> Void)?
    let onNeedNextPages: (() -> Void)?
    let onNeedPreviousPages: (() -> Void)?

    init(
        pages: [NSAttributedString],
        transitionStyle: UIPageViewController.TransitionStyle,
        insets: UIEdgeInsets,
        background: Color,
        currentPage: Binding<Int>,
        pageRanges: [NSRange] = [],
        onSwipeStart: (() -> Void)? = nil,
        onNeedNextPages: (() -> Void)? = nil,
        onNeedPreviousPages: (() -> Void)? = nil
    ) {
        self.pages = pages
        self.pageRanges = pageRanges
        self.transitionStyle = transitionStyle
        self.insets = insets
        self.background = background
        self._currentPage = currentPage
        self.onSwipeStart = onSwipeStart
        self.onNeedNextPages = onNeedNextPages
        self.onNeedPreviousPages = onNeedPreviousPages
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let options: [UIPageViewController.OptionsKey: Any]? = transitionStyle == .pageCurl
            ? [.spineLocation: UIPageViewController.SpineLocation.min.rawValue]
            : nil
        let pageVC = UIPageViewController(
            transitionStyle: transitionStyle,
            navigationOrientation: .horizontal,
            options: options
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

        if context.coordinator.updatePageWindowIfNeeded() {
            let target = max(0, min(currentPage, pages.count - 1))
            pageVC.setViewControllers(
                [context.coordinator.hostingController(at: target)],
                direction: .forward,
                animated: false
            )
            return
        }

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
        private var pageRangeSignature: [NSRange]

        init(_ parent: PageViewController) {
            self.parent = parent
            pageRangeSignature = parent.pageRanges
        }

        func updatePageWindowIfNeeded() -> Bool {
            guard pageRangeSignature != parent.pageRanges else { return false }
            pageRangeSignature = parent.pageRanges
            controllers.removeAll(keepingCapacity: true)
            return true
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
            if index >= parent.pages.count - 2 {
                parent.onNeedNextPages?()
            }
            if index <= 1 {
                parent.onNeedPreviousPages?()
            }
        }
    }
}
