import AppKit

extension VideoHostView {
    static func pixelRatios(in bitmap: NSBitmapImageRep) -> (white: Double, dark: Double, color: Double, total: Int) {
        let step = max(1, min(bitmap.pixelsWide, bitmap.pixelsHigh) / 500)
        var total = 0
        var white = 0
        var dark = 0
        var color = 0

        for y in stride(from: 0, to: bitmap.pixelsHigh, by: step) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: step) {
                guard let raw = bitmap.colorAt(x: x, y: y),
                      let c = raw.usingColorSpace(.sRGB),
                      c.alphaComponent > 0.1 else { continue }
                total += 1
                let r = c.redComponent
                let g = c.greenComponent
                let b = c.blueComponent
                if r > 0.92, g > 0.92, b > 0.92 {
                    white += 1
                } else if r < 0.05, g < 0.05, b < 0.05 {
                    dark += 1
                } else {
                    color += 1
                }
            }
        }

        guard total > 0 else { return (white: 1, dark: 0, color: 0, total: 0) }
        return (
            white: Double(white) / Double(total),
            dark: Double(dark) / Double(total),
            color: Double(color) / Double(total),
            total: total
        )
    }
}
