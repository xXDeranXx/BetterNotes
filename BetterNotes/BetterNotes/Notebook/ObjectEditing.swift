import CoreGraphics

/// A grip on a selected object: images resize at their corners (keeping their shape), text
/// boxes at their left and right edges (their height follows the text).
nonisolated enum ObjectHandle: Equatable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight, left, right
}

/// The geometry of selecting, moving and resizing objects (M8), in page points. No views here,
/// so it is tested directly; the editor converts touches to page points first.
nonisolated enum ObjectEditing {
    /// No object gets smaller than this (points), so it can still be grabbed.
    static let minimumSize: CGFloat = 20
    /// How much of an object must stay on the page when it is moved, so it can be found again.
    static let minimumVisible: CGFloat = 24

    /// The topmost object under `point`. `slop` widens every object a little, so a thin text
    /// line is easy to hit.
    static func object(at point: CGPoint, in objects: [PageObject], slop: CGFloat = 0) -> PageObject? {
        objects.last { $0.frame.insetBy(dx: -slop, dy: -slop).contains(point) }
    }

    static func handles(for object: PageObject) -> [ObjectHandle] {
        switch object.content {
        case .image: [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .text: [.left, .right]
        }
    }

    static func point(of handle: ObjectHandle, in frame: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
        case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
        case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
        case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
        case .left: CGPoint(x: frame.minX, y: frame.midY)
        case .right: CGPoint(x: frame.maxX, y: frame.midY)
        }
    }

    /// The handle of `object` within `radius` of `point`, the nearest one if several are.
    static func handle(at point: CGPoint, of object: PageObject, radius: CGFloat) -> ObjectHandle? {
        handles(for: object)
            .map { ($0, hypot(self.point(of: $0, in: object.frame).x - point.x, self.point(of: $0, in: object.frame).y - point.y)) }
            .filter { $0.1 <= radius }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// `frame` moved by `translation`, but never so far that less than `minimumVisible` points
    /// of it stay on a page of `pageSize`.
    static func moved(_ frame: CGRect, by translation: CGPoint, pageSize: CGSize) -> CGRect {
        let keep = min(minimumVisible, frame.width, frame.height)
        var result = frame.offsetBy(dx: translation.x, dy: translation.y)
        result.origin.x = min(max(result.origin.x, keep - result.width), pageSize.width - keep)
        result.origin.y = min(max(result.origin.y, keep - result.height), pageSize.height - keep)
        return result
    }

    /// `frame` with `handle` dragged by `translation`. The opposite corner or edge stays where
    /// it is. Corners keep the frame's proportions (images are never stretched); the side
    /// handles only change the width.
    static func resized(_ frame: CGRect, handle: ObjectHandle, by translation: CGPoint, minimumWidth: CGFloat = minimumSize) -> CGRect {
        switch handle {
        case .left:
            let width = max(frame.width - translation.x, minimumWidth)
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        case .right:
            return CGRect(x: frame.minX, y: frame.minY, width: max(frame.width + translation.x, minimumWidth), height: frame.height)
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let growsRight = handle == .topRight || handle == .bottomRight
            let growsDown = handle == .bottomLeft || handle == .bottomRight
            let proposedWidth = frame.width + (growsRight ? translation.x : -translation.x)
            let proposedHeight = frame.height + (growsDown ? translation.y : -translation.y)
            // Follow whichever direction the Pencil moved more, in proportion.
            var factor = max(proposedWidth / frame.width, proposedHeight / frame.height)
            factor = max(factor, minimumSize / min(frame.width, frame.height))
            let size = CGSize(width: frame.width * factor, height: frame.height * factor)
            let x = growsRight ? frame.minX : frame.maxX - size.width
            let y = growsDown ? frame.minY : frame.maxY - size.height
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }
}
