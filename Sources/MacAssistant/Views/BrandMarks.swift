import SwiftUI

/// GitHub / X / Telegram 的官方标志（Simple Icons 的品牌 path，Telegram 按官方蓝着色）。
struct BrandIcon: View {
    enum Glyph {
        case github
        case x
        case telegram
    }

    let glyph: Glyph
    var size: CGFloat = 16

    var body: some View {
        switch glyph {
        case .github:
            SVGMark(viewBox: Self.box, d: Self.github)
                .fill(Color.primary)
                .frame(width: size, height: size)
        case .x:
            SVGMark(viewBox: Self.box, d: Self.x)
                .fill(Color.primary, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        case .telegram:
            SVGMark(viewBox: Self.box, d: Self.telegram)
                .fill(Self.telegramBlue, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        }
    }

    private static let box = CGSize(width: 24, height: 24)
    /// Telegram 品牌色 `#26A5E4`。
    private static let telegramBlue = Color(red: 38 / 255, green: 165 / 255, blue: 228 / 255)

    /// Simple Icons `github`，viewBox 0 0 24 24。换行只当空白，不能用 `\` 续行。
    private static let github = """
    M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577
    0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633
    17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809
    1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38
    1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405
    1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84
    1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015
    2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12
    """

    /// Simple Icons `x`，viewBox 0 0 24 24，第二子路径挖空。
    private static let x = """
    M18.901 1.153h3.68l-8.04 9.19L24 22.846h-7.406l-5.8-7.584-6.638 7.584H.474l8.6-9.83L0
    1.154h7.594l5.243 6.932ZM17.61 20.644h2.039L6.486 3.24H4.298Z
    """

    /// Simple Icons `telegram`，圆 + 纸飞机挖空，viewBox 0 0 24 24。
    private static let telegram = """
    M11.944 0A12 12 0 0 0 0 12a12 12 0 0 0 12 12 12 12 0 0 0 12-12A12 12 0 0 0 12 0a12 12
    0 0 0-.056 0zm4.962 7.224c.1-.002.321.023.465.14a.506.506 0 0 1 .171.325c.016.093.036.306.02.472
    -.18 1.898-.962 6.502-1.36 8.627-.168.9-.499 1.201-.82 1.23-.696.065-1.225-.46-1.9-.902-1.056
    -.693-1.653-1.124-2.678-1.8-1.185-.78-.417-1.21.258-1.911.177-.184 3.247-2.977 3.307-3.23.007
    -.032.014-.15-.056-.212s-.174-.041-.249-.024c-.106.024-1.793 1.14-5.061 3.345-.48.33-.913.49
    -1.302.48-.428-.008-1.252-.241-1.865-.44-.752-.245-1.349-.374-1.297-.789.027-.216.325-.437.893
    -.663 3.498-1.524 5.831-2.529 6.998-3.014 3.332-1.386 4.025-1.627 4.476-1.635z
    """
}

private struct SVGMark: Shape {
    let viewBox: CGSize
    let d: String

    func path(in rect: CGRect) -> Path {
        let parsed = SVGPathParser.parse(d)
        let sx = rect.width / viewBox.width
        let sy = rect.height / viewBox.height
        return parsed.applying(CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: rect.minX, ty: rect.minY))
    }
}

/// 官方 path 用到的命令：M/L/H/V/C/S/A/Z 及相对形式、隐式重复。
private enum SVGPathParser {
    static func parse(_ d: String) -> Path {
        let tokens = tokenize(d)
        var path = Path()
        var i = 0
        var command: Character = "M"
        var current = CGPoint.zero
        var start = CGPoint.zero
        var lastCubicControl: CGPoint?

        func nextNumber() -> CGFloat? {
            guard i < tokens.count, let value = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(value)
        }

        func nextPoint(relative: Bool) -> CGPoint? {
            guard let x = nextNumber(), let y = nextNumber() else { return nil }
            return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
        }

        while i < tokens.count {
            if let first = tokens[i].first, first.isLetter {
                command = first
                i += 1
            }

            let relative = command.isLowercase
            switch command.lowercased() {
            case "m":
                guard let point = nextPoint(relative: relative) else { return path }
                path.move(to: point)
                current = point
                start = point
                lastCubicControl = nil
                command = relative ? "l" : "L"
            case "l":
                guard let point = nextPoint(relative: relative) else { return path }
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
            case "h":
                guard let x = nextNumber() else { return path }
                let point = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
            case "v":
                guard let y = nextNumber() else { return path }
                let point = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: point)
                current = point
                lastCubicControl = nil
            case "c":
                guard
                    let control1 = nextPoint(relative: relative),
                    let control2 = nextPoint(relative: relative),
                    let point = nextPoint(relative: relative)
                else { return path }
                path.addCurve(to: point, control1: control1, control2: control2)
                current = point
                lastCubicControl = control2
            case "s":
                let reflected: CGPoint
                if let last = lastCubicControl {
                    reflected = CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
                } else {
                    reflected = current
                }
                guard
                    let control2 = nextPoint(relative: relative),
                    let point = nextPoint(relative: relative)
                else { return path }
                path.addCurve(to: point, control1: reflected, control2: control2)
                current = point
                lastCubicControl = control2
            case "a":
                guard
                    let rx = nextNumber(),
                    let ry = nextNumber(),
                    let rotation = nextNumber(),
                    let large = nextNumber(),
                    let sweep = nextNumber(),
                    let end = nextPoint(relative: relative)
                else { return path }
                addArc(
                    to: &path,
                    from: current,
                    rx: rx,
                    ry: ry,
                    rotation: rotation,
                    largeArc: large != 0,
                    sweep: sweep != 0,
                    end: end
                )
                current = end
                lastCubicControl = nil
            case "z":
                path.closeSubpath()
                current = start
                lastCubicControl = nil
            default:
                return path
            }
        }
        return path
    }

    /// SVG 椭圆弧转贝塞尔，按 W3C 实现注释。
    private static func addArc(
        to path: inout Path,
        from start: CGPoint,
        rx rxIn: CGFloat,
        ry ryIn: CGFloat,
        rotation degrees: CGFloat,
        largeArc: Bool,
        sweep: Bool,
        end: CGPoint
    ) {
        if start == end { return }
        var rx = abs(rxIn)
        var ry = abs(ryIn)
        if rx < 1e-6 || ry < 1e-6 {
            path.addLine(to: end)
            return
        }

        let phi = degrees * .pi / 180
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2
        let dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
        }

        let rx2 = rx * rx
        let ry2 = ry * ry
        let num = max(0, rx2 * ry2 - rx2 * y1p * y1p - ry2 * x1p * x1p)
        let den = rx2 * y1p * y1p + ry2 * x1p * x1p
        var coeff = den == 0 ? 0 : sqrt(num / den)
        if largeArc == sweep { coeff = -coeff }

        let cxp = coeff * (rx * y1p) / ry
        let cyp = coeff * -(ry * x1p) / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let sign: CGFloat = (ux * vy - uy * vx) < 0 ? -1 : 1
            let dot = ux * vx + uy * vy
            let len = hypot(ux, uy) * hypot(vx, vy)
            guard len > 0 else { return 0 }
            return sign * acos(min(1, max(-1, dot / len)))
        }

        let startAngle = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var delta = angle(
            (x1p - cxp) / rx, (y1p - cyp) / ry,
            (-x1p - cxp) / rx, (-y1p - cyp) / ry
        )
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int(ceil(abs(delta) / (.pi / 2))))
        let step = delta / CGFloat(segments)
        for index in 0..<segments {
            let theta1 = startAngle + CGFloat(index) * step
            addArcSegment(to: &path, cx: cx, cy: cy, rx: rx, ry: ry, phi: phi, theta1: theta1, delta: step)
        }
    }

    private static func addArcSegment(
        to path: inout Path,
        cx: CGFloat,
        cy: CGFloat,
        rx: CGFloat,
        ry: CGFloat,
        phi: CGFloat,
        theta1: CGFloat,
        delta: CGFloat
    ) {
        let theta2 = theta1 + delta
        let alpha = (4 / 3) * tan(delta / 4)
        let cosPhi = cos(phi)
        let sinPhi = sin(phi)

        func point(_ theta: CGFloat) -> CGPoint {
            let dx = rx * cos(theta)
            let dy = ry * sin(theta)
            return CGPoint(
                x: cx + cosPhi * dx - sinPhi * dy,
                y: cy + sinPhi * dx + cosPhi * dy
            )
        }

        func tangent(_ theta: CGFloat, sign: CGFloat) -> CGPoint {
            let dx = -rx * sin(theta)
            let dy = ry * cos(theta)
            return CGPoint(
                x: sign * (cosPhi * dx - sinPhi * dy),
                y: sign * (sinPhi * dx + cosPhi * dy)
            )
        }

        let end = point(theta2)
        let control1 = CGPoint(
            x: point(theta1).x + alpha * tangent(theta1, sign: 1).x,
            y: point(theta1).y + alpha * tangent(theta1, sign: 1).y
        )
        let control2 = CGPoint(
            x: end.x + alpha * tangent(theta2, sign: -1).x,
            y: end.y + alpha * tangent(theta2, sign: -1).y
        )
        path.addCurve(to: end, control1: control1, control2: control2)
    }

    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        var number = ""

        func flush() {
            guard !number.isEmpty else { return }
            tokens.append(number)
            number = ""
        }

        for character in d {
            if character.isLetter {
                flush()
                tokens.append(String(character))
            } else if character == "," || character.isWhitespace {
                flush()
            } else if character == "+" || character == "-" {
                if !number.isEmpty, number.last?.lowercased() != "e" {
                    flush()
                }
                number.append(character)
            } else if character == "." {
                if number.contains("."), !(number.contains("e") || number.contains("E")) {
                    flush()
                }
                number.append(character)
            } else if character.isNumber {
                number.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }
}
