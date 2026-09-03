
import UIKit

enum SharePresenter {
    static func present(items: [Any]) {
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?
            .rootViewController else {
            return
        }

        let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
        root.present(activityVC, animated: true)
    }
}
