import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

/// The PerroNote cassette: marker lettering on the label and two reels that can be turned.
/// Drawn on a 120 x 100 grid and scaled to `width`.
struct CassetteView: View {
    static let markerFont = "PermanentMarker-Regular"

    var label: String
    var width: CGFloat = 200
    var reelAngle: Angle = .zero

    private var s: CGFloat { width / 120 }

    var body: some View {
        ZStack {
            // Body
            RoundedRectangle(cornerRadius: 10 * s)
                .fill(LinearGradient(colors: [Color(hex: 0xFF7A45), Color(hex: 0xE85A24)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: 108 * s, height: 74 * s)
                .position(x: 60 * s, y: 51 * s)
            RoundedRectangle(cornerRadius: 10 * s)
                .stroke(Color(hex: 0xA63D16), lineWidth: 1.6 * s)
                .frame(width: 108 * s, height: 74 * s)
                .position(x: 60 * s, y: 51 * s)

            // Label with the meeting name in marker
            RoundedRectangle(cornerRadius: 4 * s)
                .fill(Color(hex: 0xFFF4DC))
                .frame(width: 94 * s, height: 30 * s)
                .position(x: 60 * s, y: 35 * s)
            Rectangle()
                .fill(Color(hex: 0xD6C9A4))
                .frame(width: 84 * s, height: max(1, s))
                .position(x: 60 * s, y: 43 * s)
            Text(label)
                .font(.custom(Self.markerFont, size: 14 * s))
                .foregroundColor(Color(hex: 0x1D3FB5))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .frame(width: 84 * s, height: 20 * s)
                .rotationEffect(.degrees(-2))
                .position(x: 60 * s, y: 32 * s)

            // Tape window with the two reels
            Capsule()
                .fill(Color(hex: 0x3A2418))
                .frame(width: 58 * s, height: 24 * s)
                .position(x: 60 * s, y: 66 * s)
            reel.position(x: 47 * s, y: 66 * s)
            reel.position(x: 73 * s, y: 66 * s)
            Circle().fill(Color(hex: 0x3A2418)).frame(width: 4 * s, height: 4 * s)
                .position(x: 47 * s, y: 66 * s)
            Circle().fill(Color(hex: 0x3A2418)).frame(width: 4 * s, height: 4 * s)
                .position(x: 73 * s, y: 66 * s)
        }
        .frame(width: 120 * s, height: 100 * s)
        .accessibilityHidden(true)
    }

    private var reel: some View {
        ZStack {
            Circle().fill(Color(hex: 0xEADFC4)).frame(width: 16 * s, height: 16 * s)
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color(hex: 0x7A6A4C))
                    .frame(width: 12.8 * s, height: 1.6 * s)
                    .rotationEffect(.degrees(Double(i) * 60))
            }
        }
        .rotationEffect(reelAngle)
    }
}
