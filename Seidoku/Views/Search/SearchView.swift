//
//  SearchView.swift
//  Seidoku
//
//  搜索：搜索书库内书籍（第一阶段占位，后续实现）
//

import SwiftUI

struct SearchView: View {
    @State private var showNavBar = true

    var body: some View {
        NavigationStack {
            ScrollView {
                ContentUnavailableView(
                    "搜索",
                    systemImage: "magnifyingglass",
                    description: Text("搜索书库里的书籍")
                )
                .frame(maxWidth: .infinity, minHeight: 400)
            }
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onScrollGeometryChange(for: CGFloat.self) { geo in
                geo.contentOffset.y
            } action: { oldValue, newValue in
                withAnimation(.easeInOut(duration: 0.25)) {
                    if newValue - oldValue > 8 {
                        showNavBar = false
                    } else if newValue - oldValue < -8 {
                        showNavBar = true
                    }
                }
            }
            .navigationTitle("搜索")
            .toolbar(showNavBar ? .visible : .hidden, for: .navigationBar)
        }
    }
}

#Preview {
    SearchView()
}
