import Foundation
import AVFoundation
import CoreMedia
import UIKit
import FoyerFoundation

/// Asks tvOS to switch the display to the content's frame rate for the advanced engine.
/// (AVPlayerViewController does this on its own for the native engine.) Only effective when
/// the user enabled "Match Frame Rate" in Settings › Video and Audio.
@MainActor
enum DisplayCriteriaController {
    static func apply(frameRate: Double?) {
        guard #available(tvOS 17.0, *), let frameRate, frameRate > 0 else { return }
        guard let manager = displayManager(), manager.isDisplayCriteriaMatchingEnabled else {
            Log.debug(.playback, "Display criteria matching disabled by the user")
            return
        }
        // The advanced engine renders SDR (tone-mapped); describe an SDR BT.709 stream at the content rate.
        var description: CMVideoFormatDescription?
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        ]
        let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
                                                    width: 3840, height: 2160, extensions: extensions as CFDictionary,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else {
            Log.notice(.playback, "Could not create format description for display criteria (\(status))")
            return
        }
        let criteria = AVDisplayCriteria(refreshRate: Float(frameRate), formatDescription: description)
        manager.preferredDisplayCriteria = criteria
        Log.info(.playback, "Requested display refresh rate \(frameRate) Hz")
    }

    static func reset() {
        guard let manager = displayManager() else { return }
        if manager.preferredDisplayCriteria != nil {
            manager.preferredDisplayCriteria = nil
            Log.debug(.playback, "Display criteria reset")
        }
    }

    private static func displayManager() -> AVDisplayManager? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.avDisplayManager ?? scenes.first?.windows.first?.avDisplayManager
    }
}
