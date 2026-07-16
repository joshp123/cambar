import CoreGraphics

public enum StatusItemHitRegion {
    public static func contains(
        screenPoint: CGPoint,
        eventWindowNumber: Int,
        statusRect: CGRect,
        statusWindowNumber: Int,
        tolerance: CGFloat = 2
    ) -> Bool {
        if eventWindowNumber != 0,
           statusWindowNumber != 0,
           eventWindowNumber == statusWindowNumber {
            return true
        }
        return statusRect.insetBy(dx: -tolerance, dy: -tolerance).contains(screenPoint)
    }
}
