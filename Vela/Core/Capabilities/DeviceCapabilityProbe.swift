import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import VelaFoundation
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
            let maxChannels = session.maximumOutputNumberOfChannels
            // HDMI reports up to 32 channels on tvOS 26. Asking for more than the 8 PCM channels HDMI carries breaks
            // the system player: every AVPlayer item with audio then fails right after playback starts
            // (CoreMediaErrorDomain 'nope'). Preferences must be set before the session is activated.
            var preferred = min(maxChannels, 8)
            #if DEBUG
            if let override = UserDefaults.standard.string(forKey: "audio-channels").flatMap(Int.init) { preferred = override } // 0 = route default
            #endif
            if preferred > 0 {
                try session.setPreferredOutputNumberOfChannels(preferred)
            }
            try session.setActive(true)
            let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue)(\($0.channels?.count ?? 0)ch)" }
            Log.info(.audio, "Audio session ready: output \(session.outputNumberOfChannels) ch (max \(maxChannels), preferred \(preferred)), \(Int(session.sampleRate)) Hz, route \(outputs)")
        } catch {
            Log.error(.audio, "Audio session configuration failed: \(error)")
        }
    }
}
