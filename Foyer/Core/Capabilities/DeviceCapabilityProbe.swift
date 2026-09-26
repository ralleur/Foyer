import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import FoyerFoundation
import PlaybackDecision

/// Detects what this Apple TV and the connected display/audio chain support.
enum DeviceCapabilityProbe {
    @MainActor
    static func probe(advancedEngineAvailable: Bool) -> DeviceCapabilities {
        var caps = DeviceCapabilities()
        caps.modelName = DeviceInfo.modelIdentifier
        caps.supportsHEVCHardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        caps.supportsAV1Hardware = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)

        let hdrModes = AVPlayer.availableHDRModes
        caps.supportsHDR10 = hdrModes.contains(.hdr10)
        caps.supportsHLG = hdrModes.contains(.hlg)
        caps.supportsDolbyVision = hdrModes.contains(.dolbyVision)

        if DeviceInfo.isAppleTVHD {
            caps.supportsHEVC10Bit = false
            caps.maxVideoWidth = 1920
            caps.maxVideoHeight = 1080
            caps.advancedEngineMaxSoftwareDecodeHeight = 720
        } else {
            caps.supportsHEVC10Bit = caps.supportsHEVCHardware
            caps.maxVideoWidth = 4096
            caps.maxVideoHeight = 2160
            caps.advancedEngineMaxSoftwareDecodeHeight = 1080
        }

        let session = AVAudioSession.sharedInstance()
        caps.maxOutputChannels = max(2, session.maximumOutputNumberOfChannels)
        caps.supportsDolbyPassthrough = true
        caps.advancedEngineAvailable = advancedEngineAvailable
        caps.advancedEngineSupportsHDROutput = false
        return caps
    }
}

/// Central AVAudioSession configuration: movie playback, multichannel where the route allows it.
enum AudioSessionController {
    static func configure() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            let maxChannels = session.maximumOutputNumberOfChannels
            if maxChannels > 2 {
                try session.setPreferredOutputNumberOfChannels(maxChannels)
            }
            Log.info(.audio, "Audio session ready: \(session.outputNumberOfChannels)/\(maxChannels) channels, route \(session.currentRoute.outputs.map(\.portType.rawValue))")
        } catch {
            Log.error(.audio, "Audio session configuration failed: \(error)")
        }
    }
}
