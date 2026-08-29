//
//  HomeView.swift
//  Nagi
//
//  主页：继续阅读入口（第一阶段先做骨架，书库数据接入后填充）
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "还没有书",
                systemImage: "book"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("主页")
        }
    }
}

#Preview {
    HomeView()
}
