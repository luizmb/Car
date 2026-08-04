import FP
import FPMacros

// MARK: - Audio route

/// One output the system is currently playing through.
///
/// `portType` mirrors `AVAudioSession.Port`'s raw value, kept as a plain string so the domain does
/// not depend on AVFoundation. `uid` is stable per physical device, which is what makes it useful
/// for telling *which* headset came back rather than merely that one did.
public struct AudioOutput: Sendable, Equatable, Hashable {
    public let portType: String
    public let portName: String
    public let uid: String

    public init(portType: String, portName: String, uid: String) {
        self.portType = portType
        self.portName = portName
        self.uid = uid
    }
}

/// The current output route.
///
/// This is how the helmet intercom is detected, and it is markedly more reliable than watching for
/// its BLE advertisements: in the garage capture the Cardo produced a clean route change at every
/// connect and disconnect, but only **8 BLE packets in six minutes** — far too sparse to treat as
/// presence. Note the CarPlay head unit never appears here at all, because it is configured to use
/// iPhone audio, so this says nothing about the bike being on.
public struct AudioRoute: Sendable, Equatable {
    public let outputs: [AudioOutput]

    public init(outputs: [AudioOutput]) {
        self.outputs = outputs
    }

    public static let none = AudioRoute(outputs: [])
}

// MARK: - Headset detection

public extension AudioRoute {
    /// Bluetooth port types that mean "a headset is wearing the audio", as opposed to the phone
    /// speaker or a wired accessory.
    private static let headsetPortTypes: Set<String> = [
        "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE"
    ]

    /// The connected Bluetooth headset, if any. On this bike that is the Cardo — matched by port
    /// *type* rather than by name, so replacing the intercom does not require a code change.
    var bluetoothHeadset: AudioOutput? {
        outputs.first { Self.headsetPortTypes.contains($0.portType) }
    }

    var isHeadsetConnected: Bool { bluetoothHeadset != nil }
}
