import Foundation
import CoreAudio
import AVFoundation

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDeviceService {
    static func inputDevices() -> [AudioInputDevice] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize
        )
        guard status == noErr else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize,
            &deviceIDs
        )
        guard status == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize)
            guard streamStatus == noErr, streamSize > 0 else { continue }

            // Get device UID
            guard let uid = getStringProperty(kAudioDevicePropertyDeviceUID, from: deviceID) else { continue }

            // Get device name
            guard let name = getStringProperty(kAudioObjectPropertyName, from: deviceID) else { continue }

            result.append(AudioInputDevice(
                id: deviceID,
                uid: uid,
                name: name
            ))
        }

        return result
    }

    private static func getStringProperty(_ selector: AudioObjectPropertySelector, from deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        guard status == noErr, let cfString = value?.takeRetainedValue() else { return nil }
        return cfString as String
    }

    static func setInputDevice(uid: String, on engine: AVAudioEngine) throws {
        let devices = inputDevices()
        guard let device = devices.first(where: { $0.uid == uid }) else {
            throw AudioDeviceError.deviceNotFound
        }

        let audioUnit = engine.inputNode.audioUnit!
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw AudioDeviceError.failedToSetDevice
        }
    }

    enum AudioDeviceError: LocalizedError {
        case deviceNotFound
        case failedToSetDevice

        var errorDescription: String? {
            switch self {
            case .deviceNotFound: return "Аудиоустройство не найдено"
            case .failedToSetDevice: return "Не удалось установить аудиоустройство"
            }
        }
    }
}
