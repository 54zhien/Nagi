//
//  AppImportState.swift
//  Seidoku
//
//  全局导入状态：用于「用 Seidoku 打开」的文件导入结果反馈。
//

import Foundation
import Observation

@MainActor
@Observable
final class AppImportState {
    static let shared = AppImportState()

    /// 导入结果提示（非 nil 时显示 alert）
    var message: String?

    private init() {}
}
