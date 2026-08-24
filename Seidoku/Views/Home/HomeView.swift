//
//  HomeView.swift
//  Seidoku
//
//  主页：继续阅读入口（第一阶段先做骨架，书库数据接入后填充）
//

import SwiftUI

struct HomeView: View {
    @State private var showNavBar = true

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
            .navigationTitle("主页")
            .toolbar(showNavBar ? .visible : .hidden, for: .navigationBar)
        }
    }
}

#Preview {
    HomeView()
}
