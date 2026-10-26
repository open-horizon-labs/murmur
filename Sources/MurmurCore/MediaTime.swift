import Foundation

#if canImport(CoreMedia)
import CoreMedia

/// On Apple platforms this is exactly `CMTime`, so capture code passes presentation timestamps through unchanged.
public typealias MediaTime = CMTime

extension CMTime {
    public var portableSeconds: Double { CMTimeGetSeconds(self) }
}
#else
/// Minimal stand-in for `CMTime` where CoreMedia is unavailable (Linux).
public struct MediaTime: Sendable, Equatable {
    public var value: Int64
    public var timescale: Int32

    public init(value: Int64, timescale: Int32) {
        self.value = value
        self.timescale = timescale
    }

    public var isNumeric: Bool { timescale != 0 }

    public var portableSeconds: Double {
        timescale == 0 ? .nan : Double(value) / Double(timescale)
    }
}
#endif
