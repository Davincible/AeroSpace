import AppKit
import Common

final class TilingContainer: TreeNode, NonLeafTreeNodeObject { // todo consider renaming to GenericContainer
    fileprivate var _orientation: Orientation
    var orientation: Orientation { _orientation }
    var layout: Layout

    @MainActor
    init(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, _ orientation: Orientation, _ layout: Layout, index: Int) {
        self._orientation = orientation
        self.layout = layout
        super.init(parent: parent, adaptiveWeight: adaptiveWeight, index: index)
    }

    @MainActor
    static func newHTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .h, .tiles, index: index)
    }

    @MainActor
    static func newVTiles(parent: NonLeafTreeNodeObject, adaptiveWeight: CGFloat, index: Int) -> TilingContainer {
        TilingContainer(parent: parent, adaptiveWeight: adaptiveWeight, .v, .tiles, index: index)
    }
}

extension TilingContainer {
    var isRootContainer: Bool { parent is Workspace }

    @MainActor
    func changeOrientation(_ targetOrientation: Orientation) {
        if orientation == targetOrientation {
            return
        }
        // Just change this container's orientation
        // Normalization will handle merging if it matches parent's orientation
        _orientation = targetOrientation
    }

    @MainActor
    func normalizeNestedContainers() {
        // First, recursively normalize children (bottom-up approach)
        // This ensures all nested containers are normalized before we check this one
        // Use a snapshot of children because the array may change during normalization
        let childrenSnapshot = Array(children)
        for child in childrenSnapshot {
            (child as? TilingContainer)?.normalizeNestedContainers()
        }
        
        // Then check if this container has the same orientation as its parent
        // If so, merge this container into its parent
        if let parentContainer = parent as? TilingContainer,
           orientation == parentContainer.orientation {
            // Merge this container into its parent
            guard let ownIndex = ownIndex else { return } // Should not happen, but be safe
            let mru = parentContainer.mostRecentChild
            let childrenToMove = Array(children) // Copy children array before unbinding
            
            // Calculate the total weight of this container (the one being merged)
            // This represents the total height/width that will be redistributed
            // We get this BEFORE unbinding, so we have the container's weight in the parent's orientation
            let mergedContainerWeight = getWeight(parentContainer.orientation)
            
            // Unbind all children from this container first, preserving their weights
            var childBindings: [(TreeNode, BindingData)] = []
            for child in childrenToMove {
                let binding = child.unbindFromParent()
                childBindings.append((child, binding))
            }
            
            // Unbind this container from its parent
            _ = unbindFromParent()
            
            // Calculate even distribution weight for children from merged container
            let mergedChildrenCount = CGFloat(childBindings.count)
            let evenWeight = mergedContainerWeight / mergedChildrenCount
            
            // Move all children from this container directly to the parent
            // Preserve weights of existing parent children (they're not touched, so their weights remain unchanged)
            // Use even distribution for children from the merged container
            // Note: The layout system will apply these weights and resize windows when layoutWorkspaces() is called
            // (which happens after refreshModel() in the normal refresh flow)
            for (index, (child, _)) in childBindings.enumerated() {
                // Use even distribution for children from the merged container
                child.bind(to: parentContainer, adaptiveWeight: evenWeight, index: ownIndex + index)
            }
            
            // Preserve MRU
            if mru != self {
                mru?.markAsMostRecentChild()
            } else if let firstMoved = childrenToMove.first {
                firstMoved.markAsMostRecentChild()
            }
            
            // After merging, we've been unbound, so we can't continue from this node
            // Re-normalize the parent to check if any of the newly merged children should also merge
            parentContainer.normalizeNestedContainers()
            return
        }
    }
}

enum Layout: String {
    case tiles
    case accordion
}

extension String {
    func parseLayout() -> Layout? {
        if let parsed = Layout(rawValue: self) {
            return parsed
        } else if self == "list" {
            return .tiles
        } else {
            return nil
        }
    }
}
