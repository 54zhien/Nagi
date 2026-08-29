//
//  PageViewController.swift
//  Seidoku
//
//  TXT 横向分页：UICollectionView 是主路径，UIPageViewController 只负责仿真翻页。
//  两者共享同一个 TXTLayoutSnapshot，不参与文本分页。
//

import SwiftUI
import UIKit

struct TXTPageCollectionView: UIViewRepresentable {
    let snapshot: TXTLayoutSnapshot
    let background: UIColor
    let currentPage: Int
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let flowLayout = UICollectionViewFlowLayout()
        flowLayout.scrollDirection = .horizontal
        flowLayout.minimumLineSpacing = 0
        flowLayout.minimumInteritemSpacing = 0
        flowLayout.sectionInset = .zero
        flowLayout.itemSize = .zero

        let collectionView = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        collectionView.backgroundColor = background
        collectionView.isPagingEnabled = true
        collectionView.isDirectionalLockEnabled = true
        collectionView.alwaysBounceHorizontal = false
        collectionView.alwaysBounceVertical = false
        collectionView.bounces = false
        collectionView.decelerationRate = .fast
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.register(
            TXTPageCell.self,
            forCellWithReuseIdentifier: TXTPageCell.reuseIdentifier
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.reloadData()
        return collectionView
    }

    func updateUIView(_ collectionView: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    final class Coordinator: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        var parent: TXTPageCollectionView
        weak var collectionView: UICollectionView?
        private var lastLayoutKey: TXTLayoutKey?
        private var isApplyingExternalPage = false

        init(_ parent: TXTPageCollectionView) {
            self.parent = parent
        }

        func reloadData() {
            guard let collectionView else { return }
            lastLayoutKey = parent.snapshot.key
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            scrollToCurrentPage(animated: false)
            DispatchQueue.main.async { [weak self] in
                self?.collectionView?.collectionViewLayout.invalidateLayout()
                self?.collectionView?.layoutIfNeeded()
                self?.scrollToCurrentPage(animated: false)
            }
        }

        func update() {
            guard let collectionView else { return }

            collectionView.backgroundColor = parent.background
            if lastLayoutKey != parent.snapshot.key {
                lastLayoutKey = parent.snapshot.key
                collectionView.reloadData()
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
                scrollToCurrentPage(animated: false)
                return
            }

            let visiblePage = currentVisiblePage()
            if visiblePage != parent.currentPage {
                scrollToCurrentPage(animated: false)
            }
        }

        func collectionView(
            _ collectionView: UICollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            parent.snapshot.pages.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TXTPageCell.reuseIdentifier,
                for: indexPath
            )
            guard let pageCell = cell as? TXTPageCell,
                  parent.snapshot.pages.indices.contains(indexPath.item) else {
                return cell
            }

            let page = parent.snapshot.pages[indexPath.item]
            pageCell.configure(
                attributedText: parent.snapshot.attributedText(for: page),
                insets: parent.snapshot.insets,
                background: parent.background
            )
            return pageCell
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            collectionView.bounds.size
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            publishCurrentPage()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                publishCurrentPage()
            }
        }

        private func publishCurrentPage() {
            guard !isApplyingExternalPage else { return }
            let page = currentVisiblePage()
            guard parent.snapshot.pages.indices.contains(page) else { return }
            parent.onPageChanged(page)
        }

        private func currentVisiblePage() -> Int {
            guard let collectionView, collectionView.bounds.width > 0 else {
                return parent.currentPage
            }
            let raw = collectionView.contentOffset.x / collectionView.bounds.width
            return min(
                max(Int(raw.rounded()), 0),
                max(0, parent.snapshot.pages.count - 1)
            )
        }

        private func scrollToCurrentPage(animated: Bool) {
            guard let collectionView,
                  !parent.snapshot.pages.isEmpty,
                  collectionView.bounds.width > 0 else { return }

            let page = min(
                max(parent.currentPage, 0),
                parent.snapshot.pages.count - 1
            )
            isApplyingExternalPage = true
            collectionView.setContentOffset(
                CGPoint(x: CGFloat(page) * collectionView.bounds.width, y: 0),
                animated: animated
            )
            isApplyingExternalPage = false
        }
    }
}

struct TXTPageCurlView: UIViewControllerRepresentable {
    let snapshot: TXTLayoutSnapshot
    let background: UIColor
    let currentPage: Int
    let onPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pageViewController = UIPageViewController(
            transitionStyle: .pageCurl,
            navigationOrientation: .horizontal,
            options: nil
        )
        pageViewController.view.backgroundColor = background
        pageViewController.dataSource = context.coordinator
        pageViewController.delegate = context.coordinator
        context.coordinator.pageViewController = pageViewController

        let index = min(
            max(currentPage, 0),
            max(0, snapshot.pages.count - 1)
        )
        if !snapshot.pages.isEmpty {
            pageViewController.setViewControllers(
                [context.coordinator.controller(at: index)],
                direction: .forward,
                animated: false
            )
        }
        return pageViewController
    }

    func updateUIViewController(_ pageViewController: UIPageViewController, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update()
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: TXTPageCurlView
        weak var pageViewController: UIPageViewController?
        private var controllers: [Int: TXTPageController] = [:]
        private var layoutKey: TXTLayoutKey?
        private var isApplyingExternalPage = false

        init(_ parent: TXTPageCurlView) {
            self.parent = parent
        }

        func controller(at index: Int) -> TXTPageController {
            if let controller = controllers[index] {
                return controller
            }

            let page = parent.snapshot.pages[index]
            let controller = TXTPageController(
                pageIndex: index,
                attributedText: parent.snapshot.attributedText(for: page),
                insets: parent.snapshot.insets,
                background: parent.background
            )
            controllers[index] = controller
            return controller
        }

        func update() {
            guard let pageViewController else { return }
            pageViewController.view.backgroundColor = parent.background

            if layoutKey != parent.snapshot.key {
                layoutKey = parent.snapshot.key
                controllers.removeAll()
                guard !parent.snapshot.pages.isEmpty else { return }
                setCurrentPage(animated: false, force: true)
                return
            }

            guard let current = pageViewController.viewControllers?.first as? TXTPageController,
                  current.pageIndex != parent.currentPage else { return }
            setCurrentPage(animated: false)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let page = viewController as? TXTPageController,
                  page.pageIndex > 0 else { return nil }
            return controller(at: page.pageIndex - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let page = viewController as? TXTPageController,
                  page.pageIndex < parent.snapshot.pages.count - 1 else { return nil }
            return controller(at: page.pageIndex + 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            didFinishAnimating finished: Bool,
            previousViewControllers: [UIViewController],
            transitionCompleted completed: Bool
        ) {
            guard completed,
                  !isApplyingExternalPage,
                  let current = pageViewController.viewControllers?.first as? TXTPageController else {
                return
            }
            parent.onPageChanged(current.pageIndex)
        }

        private func setCurrentPage(animated: Bool, force: Bool = false) {
            guard let pageViewController,
                  !parent.snapshot.pages.isEmpty else { return }
            let index = min(
                max(parent.currentPage, 0),
                parent.snapshot.pages.count - 1
            )
            let currentIndex = (pageViewController.viewControllers?.first as? TXTPageController)?.pageIndex
            guard force || currentIndex != index else { return }

            isApplyingExternalPage = true
            let direction: UIPageViewController.NavigationDirection =
                (currentIndex ?? 0) < index ? .forward : .reverse
            pageViewController.setViewControllers(
                [controller(at: index)],
                direction: direction,
                animated: animated
            )
            isApplyingExternalPage = false
        }
    }
}
