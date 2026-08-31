//
//  GlassState.swift
//  Nagi
//
//  Small, value-typed state snapshots for the UIKit reader glass layer.
//

import UIKit

struct GlassColor: Equatable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    init(_ color: UIColor) {
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var alpha: CGFloat = 1

        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 1
            if color.getWhite(&white, alpha: &alpha) {
                red = white
                green = white
                blue = white
            }
        }

        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct GlassState: Equatable {
    let tint: GlassColor?
    let isEnabled: Bool
    let isInteractive: Bool
    let cornerRadius: CGFloat

    init(
        tint: GlassColor? = nil,
        isEnabled: Bool = true,
        isInteractive: Bool = true,
        cornerRadius: CGFloat = 24
    ) {
        self.tint = tint
        self.isEnabled = isEnabled
        self.isInteractive = isInteractive
        self.cornerRadius = cornerRadius
    }
}

enum GlassBackend: Equatable {
    case native
}
