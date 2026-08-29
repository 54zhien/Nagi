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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("继续阅读")
                        .font(.title2.bold())
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    ContentUnavailableView(
                        "还没有书",
                        systemImage: "book"
                    )
                    .frame(maxWidth: .infinity, minHeight: 400)
                }
                .padding()
            }
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .navigationTitle("主页")
        }
    }
}

#Preview {
    HomeView()
}
