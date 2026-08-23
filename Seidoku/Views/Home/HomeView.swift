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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sectionHeader("继续阅读")

                    // 空态：书库还没有书（后续接真实最近阅读数据）
                    ContentUnavailableView(
                        "还没有书",
                        systemImage: "book",
                        description: Text("去「书库」导入你的第一本小说")
                    )
                    .frame(maxWidth: .infinity, minHeight: 160)
                }
                .padding()
            }
            .navigationTitle("主页")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title2.bold())
            .foregroundStyle(.primary)
    }
}

#Preview {
    HomeView()
}
