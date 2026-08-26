import Foundation

public struct StorageBudget: Codable, Hashable, Sendable {
    public let sourceByteCount: Int64
    public let requiredByteCount: Int64
    public let availableByteCount: Int64
    public let reserveByteCount: Int64

    public var hasSufficientCapacity: Bool {
        availableByteCount >= requiredByteCount + reserveByteCount
    }

    public init(
        sourceByteCount: Int64,
        requiredByteCount: Int64,
        availableByteCount: Int64,
        reserveByteCount: Int64
    ) {
        self.sourceByteCount = max(0, sourceByteCount)
        self.requiredByteCount = max(0, requiredByteCount)
        self.availableByteCount = max(0, availableByteCount)
        self.reserveByteCount = max(0, reserveByteCount)
    }
}
