import Foundation
import ReadiumNavigator
import ReadiumShared

enum EPUBFontResources {
    private static let resources: [(family: ReaderFontFamily, resourceName: String)] = [
        (.song, "NagiSong-Regular"),
        (.kai, "NagiKai-Regular"),
        (.yuan, "NagiRounded-Regular"),
    ]

    static func declarations(bundle: Bundle = .main) -> [AnyHTMLFontFamilyDeclaration] {
        resources.compactMap { resource in
            guard
                let url = bundle.url(forResource: resource.resourceName, withExtension: "ttf"),
                let file = FileURL(url: url)
            else {
                return nil
            }

            let declaration = CSSFontFamilyDeclaration(
                fontFamily: FontFamily(rawValue: resource.family.readiumFamilyName),
                fontFaces: [
                    CSSFontFace(
                        file: file,
                        preload: true,
                        style: .normal,
                        weight: .standard(.normal)
                    )
                ]
            )
            return declaration.eraseToAnyHTMLFontFamilyDeclaration()
        }
    }
}
