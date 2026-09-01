import SwiftUI

enum GhostRunTheme {
    static let canvas = Color(red: 7 / 255, green: 11 / 255, blue: 19 / 255)
    static let surface = Color(red: 16 / 255, green: 26 / 255, blue: 38 / 255)
    static let elevated = Color(red: 22 / 255, green: 35 / 255, blue: 52 / 255)
    static let signal = Color(red: 85 / 255, green: 230 / 255, blue: 217 / 255)
    static let hazard = Color(red: 255 / 255, green: 77 / 255, blue: 115 / 255)
    static let supply = Color(red: 255 / 255, green: 202 / 255, blue: 88 / 255)
    static let energy = Color(red: 182 / 255, green: 243 / 255, blue: 107 / 255)
    static let debug = Color(red: 173 / 255, green: 139 / 255, blue: 255 / 255)
    static let secondaryText = Color(red: 154 / 255, green: 170 / 255, blue: 189 / 255)
}

extension View {
    func nightPanel(cornerRadius: CGFloat = 18) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
    }
}
