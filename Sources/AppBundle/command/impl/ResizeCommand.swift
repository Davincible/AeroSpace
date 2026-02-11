import AppKit
import Common

struct ResizeCommand: Command { // todo cover with tests
    let args: ResizeCmdArgs
    /*conforms*/ var shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }

        if let window = target.windowOrNil, window.isFloating {
            let size: CGSize
            let topLeftCorner: CGPoint
            if let rect = window.lastAppliedLayoutPhysicalRect {
                size = rect.size
                topLeftCorner = rect.topLeftCorner
            } else {
                guard let axSize = try await window.getAxSize(),
                      let axTopLeftCorner = try await window.getAxTopLeftCorner() else {
                    return false
                }
                size = axSize
                topLeftCorner = axTopLeftCorner
            }
            let monitorRect = target.workspace.workspaceMonitor.visibleRect

            let computeTopLeftCornerAndSize = { (diffSize: CGSize) -> (CGPoint, CGSize) in
                // Enforce minimum size of 1 to prevent zero-size windows
                var newWidth = max(1, size.width + diffSize.width)
                var newHeight = max(1, size.height + diffSize.height)
                newWidth = min(newWidth, monitorRect.width)
                newHeight = min(newHeight, monitorRect.height)

                // Center the resized window on its previous center point
                let centeredTopLeftX = topLeftCorner.x - diffSize.width / 2
                let centeredTopLeftY = topLeftCorner.y - diffSize.height / 2

                // Clamp to monitor bounds using absolute coordinates (multi-monitor safe)
                let clampedTopLeftX = min(max(centeredTopLeftX, monitorRect.minX), monitorRect.maxX - newWidth)
                let clampedTopLeftY = min(max(centeredTopLeftY, monitorRect.minY), monitorRect.maxY - newHeight)

                return (CGPoint(x: clampedTopLeftX, y: clampedTopLeftY), CGSize(width: newWidth, height: newHeight))
            }

            let isWidthDominant = size.width >= size.height
            let diff: CGFloat = switch (args.units.val, args.dimension.val) {
                case (.set(let unit), .width): CGFloat(unit) - size.width
                case (.set(let unit), .height): CGFloat(unit) - size.height
                case (.set(let unit), .smart): CGFloat(unit) - (isWidthDominant ? size.width : size.height)
                case (.set(let unit), .smartOpposite): CGFloat(unit) - (isWidthDominant ? size.height : size.width)
                case (.add(let unit), _): CGFloat(unit)
                case (.subtract(let unit), _): -CGFloat(unit)
            }

            let newTopLeftCorner: CGPoint
            let newSize: CGSize
            switch args.dimension.val {
                case .width:
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(CGSize(width: diff, height: 0))
                case .height:
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(CGSize(width: 0, height: diff))
                case .smart:
                    let diffSize = if isWidthDominant {
                        CGSize(width: diff, height: diff * (size.height / size.width))
                    } else {
                        CGSize(width: diff * (size.width / size.height), height: diff)
                    }
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(diffSize)
                case .smartOpposite:
                    let diffSize = if isWidthDominant {
                        CGSize(width: diff * (size.width / size.height), height: diff)
                    } else {
                        CGSize(width: diff, height: diff * (size.height / size.width))
                    }
                    (newTopLeftCorner, newSize) = computeTopLeftCornerAndSize(diffSize)
            }
            window.setAxFrame(newTopLeftCorner, newSize)
            return true
        }

        let candidates = target.windowOrNil?.parentsWithSelf
            .filter { ($0.parent as? TilingContainer)?.layout == .tiles }
            ?? []

        let orientation: Orientation?
        let parent: TilingContainer?
        let node: TreeNode?
        switch args.dimension.val {
            case .width:
                orientation = .h
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .height:
                orientation = .v
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
            case .smart:
                node = candidates.first
                parent = node?.parent as? TilingContainer
                orientation = parent?.orientation
            case .smartOpposite:
                orientation = (candidates.first?.parent as? TilingContainer)?.orientation.opposite
                node = candidates.first(where: { ($0.parent as? TilingContainer)?.orientation == orientation })
                parent = node?.parent as? TilingContainer
        }
        guard let parent else { return io.err("resize command supports only `tiles` layout") }
        guard let orientation else { return false }
        guard let node else { return false }
        let diff: CGFloat = switch args.units.val {
            case .set(let unit): CGFloat(unit) - node.getWeight(orientation)
            case .add(let unit): CGFloat(unit)
            case .subtract(let unit): -CGFloat(unit)
        }

        guard let childDiff = diff.div(parent.children.count - 1) else { return false }
        parent.children.lazy
            .filter { $0 != node }
            .forEach { $0.setWeight(parent.orientation, $0.getWeight(parent.orientation) - childDiff) }

        node.setWeight(orientation, node.getWeight(orientation) + diff)
        return true
    }
}
