#if os(macOS) || targetEnvironment(macCatalyst)
import Foundation
import IOKit

/// The Mac's own id, read in-process through IOKit: the platform expert device's
/// `IOPlatformUUID`, the value `/usr/sbin/ioreg -rd1 -c IOPlatformExpertDevice` prints (which a
/// sandboxed Mac App Store app could not launch). The same UUID the Electron SDK reads, so the
/// same machine fingerprint, in a Mac app and in a Mac Catalyst app alike.
enum PlatformExpert {
    /// The `IOPlatformUUID`, or nil when there is no platform expert or it has none.
    static func uuid() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { _ = IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        return property.takeRetainedValue() as? String
    }
}
#endif
