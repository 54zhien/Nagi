//
//  SettingsView.swift
//  Seidoku
//
//  设置：阅读偏好等（第一阶段占位，后续实现）
//

import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("阅读") {
                    Label("字体", systemImage: "textformat")
                    Label("字号", systemImage: "textformat.size")
                    Label("主题", systemImage: "circle.lefthalf.filled")
                }
            }
            .scrollEdgeEffectStyle(.automatic, for: .all)
            .navigationTitle("设置")
        }
    }
}

#Preview {
    SettingsView()
}
