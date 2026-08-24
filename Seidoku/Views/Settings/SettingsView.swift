//
//  SettingsView.swift
//  Seidoku
//
//  设置：阅读偏好等（第一阶段占位，后续实现）
//

import SwiftUI

struct SettingsView: View {
    @State private var showNavBar = true

    var body: some View {
        NavigationStack {
            List {
                Section("阅读") {
                    Label("字体", systemImage: "textformat")
                    Label("字号", systemImage: "textformat.size")
                    Label("主题", systemImage: "circle.lefthalf.filled")
                }
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
            .navigationTitle("设置")
            .toolbar(showNavBar ? .visible : .hidden, for: .navigationBar)
        }
    }
}

#Preview {
    SettingsView()
}
