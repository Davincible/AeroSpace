@MainActor private var layoutMutationCounter: Int = 0

@MainActor
func markLayoutMutation() {
    layoutMutationCounter += 1
}

@MainActor
func currentLayoutMutationCounter() -> Int {
    layoutMutationCounter
}
