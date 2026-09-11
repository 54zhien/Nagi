import Foundation
import UIKit

/// The document styling inputs shared by every injected script.
///
/// Captured once so the scripts are pure functions of a snapshot, and so a
/// repeated update can be recognised as a no-op.
struct ReadiumStyleSnapshot: Equatable {
    let backgroundColor: UIColor
    let contentColor: UIColor
    let fontFamily: ReaderFontFamily
    let lineHeight: Double
    let characterSpacing: Double
    let wordSpacing: Double
    let publisherStyles: Bool
    /// Readium CSS class applied to the document, if any.
    let themeMarker: String?
}

/// Builds the JavaScript injected into Readium's web view.
enum ReadiumJavaScriptBuilder {
    static func override(snapshot: ReadiumStyleSnapshot, requestGeneration: UInt64) -> String {
        let backgroundColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.backgroundColor)
        )
        let contentColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.contentColor)
        )
        let publisherFontFamily = Self.javascriptStringLiteral(
            Self.cssFontFamilyValue(for: snapshot.fontFamily)
        )
        let lineHeightValue = Self.javascriptStringLiteral(
            Self.cssDecimal(ReaderLayoutMetrics.clampLineHeight(snapshot.lineHeight))
        )
        let letterSpacingValue = Self.javascriptStringLiteral(
            Self.cssEmSpacing(for: snapshot.characterSpacing, range: ReaderLayoutMetrics.characterSpacingRange)
        )
        let wordSpacingValue = Self.javascriptStringLiteral(
            Self.cssEmSpacing(for: snapshot.wordSpacing, range: ReaderLayoutMetrics.wordSpacingRange)
        )
        let typographyEnabled = snapshot.publisherStyles ? "false" : "true"
        let themeMarker = Self.javascriptStringLiteral(snapshot.themeMarker ?? "light")
        let overrideGeneration = String(requestGeneration)
        return """
        (() => {
            const styleID = "nagi-reader-reader-overrides";
            const styleVersion = "2";
            const requestGeneration = \(overrideGeneration);
            const readerBackground = \(backgroundColor);
            const readerContent = \(contentColor);
            const appFontFamily = \(publisherFontFamily);
            const lineHeight = \(lineHeightValue);
            const letterSpacing = \(letterSpacingValue);
            const wordSpacing = \(wordSpacingValue);
            const typographyEnabled = \(typographyEnabled);
            const themeMarker = \(themeMarker);
            const root = document.documentElement;

            if (!root || !document.body) {
                return;
            }

            const bootstrapStyle = document.getElementById(
                "nagi-reader-surface-bootstrap"
            );
            if (bootstrapStyle) bootstrapStyle.remove();

            const appliedGeneration = Number(
                root.getAttribute("data-nagi-reader-override-generation") || "0"
            );
            if (requestGeneration > 0 && appliedGeneration > requestGeneration) {
                return;
            }
            if (requestGeneration > 0) {
                root.setAttribute(
                    "data-nagi-reader-override-generation",
                    String(requestGeneration)
                );
            }

            root.setAttribute("data-nagi-reader-overrides", "true");
            root.setAttribute("data-nagi-reader-theme-marker", themeMarker);
            root.style.setProperty("--nagi-line-height", lineHeight);
            root.style.setProperty("--nagi-letter-spacing", letterSpacing);
            root.style.setProperty("--nagi-word-spacing", wordSpacing);
            root.style.setProperty("--nagi-font-family", appFontFamily);
            root.style.setProperty("--nagi-reader-background", readerBackground);
            root.style.setProperty("--nagi-reader-content", readerContent);

            if (typographyEnabled) {
                root.setAttribute("data-nagi-reader-typography", "app");
            } else {
                root.removeAttribute("data-nagi-reader-typography");
            }
            root.setAttribute("data-nagi-reader-font", "app");

            let style = document.getElementById(styleID);
            if (!style || style.getAttribute("data-nagi-reader-style-version") !== styleVersion) {
                if (style) style.remove();
                style = document.createElement("style");
                style.id = styleID;
                style.setAttribute("data-nagi-reader-style-version", styleVersion);

                const rootSelector = ":root[data-nagi-reader-overrides]";
                const bodySelector = rootSelector + " body";
                const excludedSubtreeSelector = [
                    ":not(code)", ":not(code *)",
                    ":not(pre)", ":not(pre *)",
                    ":not(kbd)", ":not(kbd *)",
                    ":not(samp)", ":not(samp *)",
                    ":not(svg)", ":not(svg *)",
                    ":not(math)", ":not(math *)",
                    ":not([data-nagi-reader-preserve])",
                    ":not([data-nagi-reader-special])",
                    ":not(.icon)", ":not(.iconfont)", ":not(.icon-font)",
                    ":not([class^='icon-'])",
                    ":not([class*=' icon-'])"
                ].join("");
                const contentSelectors = [
                    "body",
                    "body *"
                ].map(selector => selector + excludedSubtreeSelector);
                const appFontSelectors = contentSelectors.map(
                    selector => rootSelector + "[data-nagi-reader-font='app'] " + selector
                );
                const appColorSelectors = contentSelectors.map(
                    selector => rootSelector + " " + selector
                );
                const appTypographySelectors = contentSelectors.map(
                    selector => rootSelector + "[data-nagi-reader-typography='app'] " + selector
                );

                style.textContent = [
                    [rootSelector, bodySelector].join(", ")
                        + " { background-color: var(--nagi-reader-background) !important;"
                        + " background-image: none !important;"
                        + " color: var(--nagi-reader-content) !important; }",
                    rootSelector + " {"
                        + " --nagi-line-height: 1;"
                        + " --nagi-letter-spacing: 0em;"
                        + " --nagi-word-spacing: 0em;"
                        + " --nagi-font-family: -apple-system, sans-serif;"
                        + " }",
                    appColorSelectors.join(", ")
                        + " { color: var(--nagi-reader-content) !important; }",
                    appFontSelectors.join(", ")
                        + " { font-family: var(--nagi-font-family) !important; }",
                    appTypographySelectors.join(", ")
                        + " { line-height: var(--nagi-line-height) !important;"
                        + " letter-spacing: var(--nagi-letter-spacing) !important;"
                        + " word-spacing: var(--nagi-word-spacing) !important; }"
                ].join("\\n");
                (document.head || root).appendChild(style);
            }
        })();
        """
    }

    static func bootstrap(snapshot: ReadiumStyleSnapshot) -> String {
        let backgroundColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.backgroundColor)
        )
        let contentColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.contentColor)
        )

        return """
        (() => {
            const root = document.documentElement;
            if (!root) return;

            const style = document.createElement("style");
            style.id = "nagi-reader-surface-bootstrap";
            style.textContent = "html, body { background-color: "
                + \(backgroundColor)
                + " !important; color: "
                + \(contentColor)
                + " !important; }";
            root.appendChild(style);
        })();
        """
    }

    static func readiness(snapshot: ReadiumStyleSnapshot, kind: ReaderVisualMutationKind) -> String {
        let expectedTextColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.contentColor)
        )
        let expectedBackgroundColor = Self.javascriptStringLiteral(
            Self.cssColorLiteral(snapshot.backgroundColor)
        )
        let expectedThemeMarker = Self.javascriptStringLiteral(
            snapshot.themeMarker ?? "light"
        )
        let expectedFontFamily = Self.javascriptStringLiteral(snapshot.fontFamily.readiumFamilyName)
        let expectedLineHeight = Self.cssDecimal(
            ReaderLayoutMetrics.clampLineHeight(snapshot.lineHeight)
        )
        let expectedLetterSpacing = Self.cssDecimal(
            min(max(snapshot.characterSpacing, ReaderLayoutMetrics.characterSpacingRange.lowerBound),
                ReaderLayoutMetrics.characterSpacingRange.upperBound) / 100
        )
        let expectedWordSpacing = Self.cssDecimal(
            min(max(snapshot.wordSpacing, ReaderLayoutMetrics.wordSpacingRange.lowerBound),
                ReaderLayoutMetrics.wordSpacingRange.upperBound) / 100
        )
        let typographyEnabled = snapshot.publisherStyles ? "false" : "true"
        let mutationKind: String
        switch kind {
        case .theme: mutationKind = "theme"
        case .typography: mutationKind = "typography"
        case .font: mutationKind = "font"
        case .geometry: mutationKind = "geometry"
        case .full: mutationKind = "full"
        }

        return """
        (() => {
            const root = document.documentElement;
            const body = document.body;
            if (!root || !body) {
                return "";
            }

            const rootStyle = getComputedStyle(root);
            const bodyStyle = getComputedStyle(body);
            const sample = body.querySelector(
                "p, li, div, dt, dd, blockquote, section, article, span, td, th"
            ) || body;
            const sampleStyle = getComputedStyle(sample);
            const expectedThemeMarker = \(expectedThemeMarker);
            const expectedTextColor = \(expectedTextColor);
            const expectedBackgroundColor = \(expectedBackgroundColor);
            const expectedFontFamily = \(expectedFontFamily);
            const expectedLineHeight = \(expectedLineHeight);
            const expectedLetterSpacing = \(expectedLetterSpacing);
            const expectedWordSpacing = \(expectedWordSpacing);
            const typographyEnabled = \(typographyEnabled);
            const mutationKind = "\(mutationKind)";

            const normalizeColor = (value) => {
                return value.replace(/\\s+/g, "").toLowerCase();
            };

            const approximately = (value, expected, tolerance) => {
                const number = parseFloat(value);
                return Number.isFinite(number) && Math.abs(number - expected) <= tolerance;
            };

            const fontReady = [
                rootStyle.fontFamily,
                bodyStyle.fontFamily,
                sampleStyle.fontFamily
            ].some(value => value.toLowerCase().includes(expectedFontFamily.toLowerCase()));

            const expectedColor = normalizeColor(expectedTextColor);
            const textReady = [bodyStyle.color, sampleStyle.color]
                .every(value => normalizeColor(value) === expectedColor);

            const themeReady = root.getAttribute("data-nagi-reader-theme-marker")
                === expectedThemeMarker;

            const sampleFontSize = parseFloat(sampleStyle.fontSize)
                || parseFloat(bodyStyle.fontSize)
                || 16;
            const lineHeightReady = approximately(sampleStyle.lineHeight, expectedLineHeight, 0.02)
                || approximately(
                    sampleStyle.lineHeight,
                    expectedLineHeight * sampleFontSize,
                    0.5
                );
            const letterSpacingReady = approximately(
                sampleStyle.letterSpacing,
                expectedLetterSpacing * sampleFontSize,
                0.25
            );
            const wordSpacingReady = approximately(
                sampleStyle.wordSpacing,
                expectedWordSpacing * sampleFontSize,
                0.25
            );
            const typographyReady = !typographyEnabled || (
                root.getAttribute("data-nagi-reader-typography") === "app"
                    && lineHeightReady
                    && letterSpacingReady
                    && wordSpacingReady
            );
            const appFontReady = root.getAttribute("data-nagi-reader-font") === "app"
                && fontReady;
            const expectedBackground = normalizeColor(expectedBackgroundColor);
            const surfaceReady = root.getAttribute("data-nagi-reader-overrides") === "true"
                && normalizeColor(rootStyle.backgroundColor) === expectedBackground
                && normalizeColor(bodyStyle.backgroundColor) === expectedBackground
                && rootStyle.backgroundImage === "none"
                && bodyStyle.backgroundImage === "none";

            if (!surfaceReady) return "";
            if (mutationKind === "theme") return themeReady && textReady ? "ready" : "";
            if (mutationKind === "font") return appFontReady ? "ready" : "";
            if (mutationKind === "typography") return typographyReady ? "ready" : "";
            return themeReady && textReady && appFontReady && typographyReady
                ? "ready"
                : "";
        })();
        """
    }

    static func cssDecimal(_ value: Double) -> String {
        String(format: "%.4f", value).replacingOccurrences(of: ",", with: ".")
    }

    static func cssEmSpacing(
        for value: Double,
        range: ClosedRange<Double>
    ) -> String {
        let clampedValue = min(max(value, range.lowerBound), range.upperBound)
        return "\(cssDecimal(clampedValue / 100))em"
    }

    static func cssFontFamilyValue(for family: ReaderFontFamily) -> String {
        switch family {
        case .original, .pingFang:
            return "-apple-system, BlinkMacSystemFont, sans-serif"
        case .song, .kai, .yuan:
            return "\(family.readiumFamilyName), -apple-system, sans-serif"
        }
    }

    static func cssColorLiteral(_ color: UIColor) -> String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1

        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            let components = [red, green, blue].map { Int((min(max($0, 0), 1) * 255).rounded()) }
            let redValue = components[0]
            let greenValue = components[1]
            let blueValue = components[2]
            if alpha >= 0.999 {
                return "rgb(\(redValue), \(greenValue), \(blueValue))"
            }
            return "rgba(\(redValue), \(greenValue), \(blueValue), \(cssDecimal(Double(alpha))))"
        }

        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            let value = Int((min(max(white, 0), 1) * 255).rounded())
            if alpha >= 0.999 {
                return "rgb(\(value), \(value), \(value))"
            }
            return "rgba(\(value), \(value), \(value), \(cssDecimal(Double(alpha))))"
        }

        return "rgb(18, 18, 18)"
    }

    static func javascriptStringLiteral(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let encoded = String(data: data, encoding: .utf8),
            encoded.count >= 2
        else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}
