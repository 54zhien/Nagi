//
//  SearchView.swift
//  Seidoku
//
//  搜索：搜索书库内书籍（第一阶段占位，后续实现）
//

import SwiftUI

struct SearchView: View {
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
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .navigationTitle("搜索")
        }
    }
}

#Preview {
    SearchView()
}
