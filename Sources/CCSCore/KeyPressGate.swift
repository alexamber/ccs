/// Accept distinct presses immediately and suppress auto-repeat while held.
public struct KeyPressGate {
    private var isDown = false
    public init() {}
    public mutating func press() -> Bool {
        guard !isDown else { return false }
        isDown = true; return true
    }
    public mutating func release() { isDown = false }
}
