import Foundation

/// Public entry point shared by the `hdmax` command-line product and the
/// `libhdmax.framework` library. Swift callers use `run(arguments:)`; the
/// Objective-C bridge exposes the same command behavior as an `NSError` API.
@objc(HDMAX)
public final class HDMAX: NSObject {
    public class func run(arguments: [String]) throws {
        try DTSHDMACommandLine.run(arguments: arguments)
    }

    @objc(executeWithArguments:error:)
    public class func execute(
        arguments: [String],
        error outError: AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool {
        do {
            try run(arguments: arguments)
            return true
        } catch {
            outError?.pointee = error as NSError
            return false
        }
    }

    @objc(supportedFrameRates)
    public class func supportedFrameRates() -> [String] {
        DTSFrameRate.supportedArgumentValues
    }

    /// The optional --encode-mode argument is shared with the CLI; omission
    /// selects auto. Typed callers may also pass DTSEncodeMode to encoders.
    @objc(supportedEncodeModes)
    public class func supportedEncodeModes() -> [String] {
        DTSEncodeMode.allCases.map(\.rawValue)
    }

    /// Fixed standard presentations accepted by --set-channel-format.
    @objc(supportedChannelFormats)
    public class func supportedChannelFormats() -> [String] {
        DTSXChannelFormat.allCases.map(\.rawValue)
    }

    @objc(supportedDTSXVisions)
    public class func supportedDTSXVisions() -> [String] {
        DTSXVision.allCases.map(\.rawValue)
    }

    /// Vision 1 defaults to dynamic for 7.1.4 Atmos input. Additional fixed
    /// formats and IMAX default to channelbase; explicit mode is validated.
    @objc(supportedObjectModes)
    public class func supportedObjectModes() -> [String] {
        DTSObjectMode.allCases.map(\.rawValue)
    }

    @objc(experimentalDynamicLayouts)
    public class func experimentalDynamicLayouts() -> [String] {
        DTSXDynamicLayout.allCases.map(\.rawValue)
    }
}
