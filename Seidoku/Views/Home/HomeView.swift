//
//  HomeView.swift
//  Seidoku
//
//  主页：继续阅读入口（第一阶段先做骨架，书库数据接入后填充）
//

import SwiftUI

struct HomeView: View {
    var body: some View {
        NavigationStack {
            ZStack(alignment: .topLeading) {
                // 空态：屏幕中央（与书库空态对齐）
                ContentUnavailableView(
                    "还没有书",
                    systemImage: "book"
                )

                // 顶部"继续阅读"
                VStack(alignment: .leading) {
                    Text("继续阅读")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .padding()
                    Spacer()
                }
            }
            .navigationTitle("主页")
        }
    }
}

#Preview {
    HomeView()
}
