import Observation

@MainActor
@Observable
final class AppImportState {
    static let shared = AppImportState()

    /// 导入结果提示（非 nil 时显示 alert）
    var message: String?

    private init() {}
}
