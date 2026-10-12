import SwiftUI
import UIKit

/// The yellow legal pad look picked under Settings > Appearance. Every screen but Settings uses it.
enum Paper {
    static let canary = Color(red: 0.988, green: 0.953, blue: 0.643)
    static let rule = UIColor(red: 0.561, green: 0.706, blue: 0.863, alpha: 1)
    static let topRule = Color(red: 0.435, green: 0.612, blue: 0.804)
    static let margin = Color(red: 0.878, green: 0.451, blue: 0.478)

    /// Where the two red margin lines sit, and where writing starts to the right of them.
    static let marginX: CGFloat = 66
    static let textX: CGFloat = 80
    /// Space between two blue rules at the default text size.
    static let pitch: CGFloat = 28

    /// The distance from a rule down to the top of the next line of text, so the text sits on the rule.
    static func lead(_ pitch: CGFloat) -> CGFloat { (pitch * 0.215).rounded() }

    private static var tiles: [CGFloat: UIImage] = [:]

    /// One rule, repeated down the page as a tile.
    static func ruleTile(_ pitch: CGFloat) -> UIImage {
        if let tile = tiles[pitch] { return tile }
        let tile = UIGraphicsImageRenderer(size: CGSize(width: 8, height: pitch)).image { ctx in
            rule.setFill()
            ctx.fill(CGRect(x: 0, y: pitch - 1, width: 8, height: 1))
        }
        tiles[pitch] = tile
        return tile
    }
}

/// The pad itself: canary paper with the two red margin lines. It stays put while the rules scroll.
struct PaperBackground: View {
    var body: some View {
        Paper.canary
            .overlay(alignment: .topLeading) {
                HStack(spacing: 2.5) {
                    Paper.margin.frame(width: 1.5)
                    Paper.margin.frame(width: 1.5)
                }
                .padding(.leading, Paper.marginX)
            }
            .ignoresSafeArea()
    }
}

/// Blue rules, every `pitch` points from `from` down. Put it behind content that scrolls so the two move together.
struct PaperRules: View {
    let pitch: CGFloat
    var from: CGFloat = 0
    var topLine = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: max(0, from))
            Image(uiImage: Paper.ruleTile(pitch))
                .resizable(resizingMode: .tile)
        }
        .overlay(alignment: .top) {
            if topLine {
                Paper.topRule.frame(height: 1.5).offset(y: from - 0.75)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The rule spacing for the current text size, rounded to whole points so the rules never drift from the text.
@propertyWrapper
struct PaperPitch: DynamicProperty {
    @ScaledMetric(relativeTo: .body) private var raw: CGFloat = Paper.pitch
    init() {}
    var wrappedValue: CGFloat { max(Paper.pitch, raw.rounded()) }
}

extension View {
    /// Spaces wrapped lines one rule apart and pads the text so it fills whole rules.
    func onRules(_ style: UIFont.TextStyle, pitch: CGFloat) -> some View {
        let height = UIFont.preferredFont(forTextStyle: style).lineHeight
        let gap = max(0, pitch - height)
        return lineSpacing(gap).padding(.vertical, gap / 2)
    }

    /// Pads the view at the bottom so it takes a whole number of rules, keeping what comes after it on the lines.
    func snapToRules(_ pitch: CGFloat) -> some View {
        modifier(SnapToRules(pitch: pitch))
    }

    /// Paper behind a list, form or plain screen when the Paper look is on.
    func paperScreen() -> some View {
        modifier(PaperScreen())
    }
}

private struct SnapToRules: ViewModifier {
    let pitch: CGFloat
    @State private var extra: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { fit(g.size.height) }
                    .onChange(of: g.size.height) { fit($0) }
            })
            .padding(.bottom, extra)
    }

    private func fit(_ height: CGFloat) {
        guard pitch > 0, height > 0.5 else { extra = 0; return }
        extra = max(0, ((height - 0.5) / pitch).rounded(.up) * pitch - height)
    }
}

private struct PaperScreen: ViewModifier {
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearance == AppAppearance.paper.rawValue {
            content
                .scrollContentBackground(.hidden)
                .background(PaperBackground())
        } else {
            content
        }
    }
}

/// How one meeting's sticky note looks. It comes from the meeting's ID, so a note keeps its look.
struct StickyStyle {
    enum Fold { case flat, bottomTrailing, topTrailing }

    let color: Color
    let tilt: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat
    let shadowOpacity: Double
    let fold: Fold
    let tape: Bool
    let pin: Bool

    private static let colors: [Color] = [
        Color(red: 1.00, green: 0.83, blue: 0.86),
        Color(red: 0.81, green: 0.92, blue: 0.99),
        Color(red: 0.85, green: 0.96, blue: 0.78),
        Color(red: 1.00, green: 0.88, blue: 0.74),
        Color(red: 1.00, green: 0.99, blue: 0.94),
    ]

    init(_ id: UUID) {
        let b = id.uuid
        color = Self.colors[Int(b.0) % Self.colors.count]
        tilt = Double(Int(b.1) % 25 - 12) / 10
        let lift = Int(b.2) % 3
        shadowRadius = [1.5, 4, 8][lift]
        shadowY = [1.5, 4, 8][lift]
        shadowOpacity = [0.20, 0.24, 0.28][lift]
        fold = [Fold.flat, .bottomTrailing, .flat, .topTrailing][Int(b.3) % 4]
        let extra = Int(b.4) % 5
        tape = extra == 0
        pin = extra == 1
    }
}

/// A sticky note, drawn behind one meeting on the list.
struct StickyNote: View {
    let style: StickyStyle
    private let fold: CGFloat = 18

    var body: some View {
        ZStack(alignment: .top) {
            NoteShape(fold: style.fold, size: fold)
                .fill(LinearGradient(colors: [style.color.opacity(0.92), style.color],
                                     startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
                .background(NoteShape(fold: style.fold, size: fold).fill(Color.white))
            if style.fold != .flat {
                FoldFlap(fold: style.fold, size: fold)
                    .fill(style.color)
                    .overlay(FoldFlap(fold: style.fold, size: fold).fill(Color.black.opacity(0.13)))
            }
            if style.tape {
                Rectangle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 70, height: 18)
                    .rotationEffect(.degrees(-3))
                    .offset(y: -9)
            }
            if style.pin {
                Circle()
                    .fill(RadialGradient(colors: [Color(red: 1, green: 0.54, blue: 0.5), Color(red: 0.82, green: 0.2, blue: 0.17)],
                                         center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: 8))
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, x: 1, y: 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 12)
                    .offset(y: -5)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(style.shadowOpacity), radius: style.shadowRadius, y: style.shadowY)
    }
}

private struct NoteShape: Shape {
    let fold: StickyStyle.Fold
    let size: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch fold {
        case .flat:
            p.addRect(r)
        case .bottomTrailing:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - size))
            p.addLine(to: CGPoint(x: r.maxX - size, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        case .topTrailing:
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - size, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + size))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// The folded-over corner of a sticky note.
private struct FoldFlap: Shape {
    let fold: StickyStyle.Fold
    let size: CGFloat

    func path(in r: CGRect) -> Path {
        var p = Path()
        switch fold {
        case .flat:
            break
        case .bottomTrailing:
            p.move(to: CGPoint(x: r.maxX - size, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX - size, y: r.maxY - size))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - size))
            p.closeSubpath()
        case .topTrailing:
            p.move(to: CGPoint(x: r.maxX - size, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX - size, y: r.minY + size))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY + size))
            p.closeSubpath()
        }
        return p
    }
}
