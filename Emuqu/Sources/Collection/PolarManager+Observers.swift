// `@preconcurrency`: CBUUID is an immutable value the SDK has not marked Sendable.
@preconcurrency import CoreBluetooth
import Foundation

#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

// The Polar SDK's observer callbacks arrive on its own queue. None of them
// touches manager state here: each is reduced to a `StrapEvent` and sent into
// `StrapEventPump`, which applies them on the main actor in the order the SDK
// raised them. What each event does lives on `StrapLinkCoordinator`.

#if canImport(PolarBleSdk)

    // MARK: - PolarBleApiObserver

    extension PolarManager: PolarBleApiObserver {
        nonisolated func deviceConnecting(_ polarDeviceInfo: PolarDeviceInfo) {
            linkRuntimePump.send(.connecting(deviceId: polarDeviceInfo.deviceId))
        }

        nonisolated func deviceConnected(_ polarDeviceInfo: PolarDeviceInfo) {
            linkRuntimePump.send(.connected(
                deviceId: polarDeviceInfo.deviceId, name: polarDeviceInfo.name, peripheralId: polarDeviceInfo.address
            ))
        }

        /// 8.3's disconnect callback, carrying why the link dropped and what
        /// recovery the SDK expects. The deprecated `pairingError:` variant is
        /// still raised alongside it and is deliberately not implemented, so
        /// each drop is handled once.
        nonisolated func deviceDisconnected(_ polarDeviceInfo: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
            linkRuntimePump.send(.disconnected(
                deviceId: polarDeviceInfo.deviceId,
                loss: Self.linkLoss(from: info)
            ))
        }

        nonisolated static func linkLoss(from info: PolarBleDisconnectInfo) -> StrapLinkLoss {
            switch info.recoveryAction {
            case .removePairingAndPairAgain, .retryPairing:
                return .pairingLost(reason: "\(info.reason)")
            case .none, .retryOperation, .retryConnection:
                return info.reason == .deviceCommand ? .deviceCommand : .connectionLost
            }
        }
    }

    // MARK: - PolarBleApiDeviceInfoObserver

    extension PolarManager: PolarBleApiDeviceInfoObserver {
        nonisolated func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
            linkRuntimePump.send(.battery(deviceId: identifier, level: batteryLevel))
        }

        nonisolated func batteryChargingStatusReceived(_: String, chargingStatus _: BleBasClient.ChargeState) {}

        nonisolated func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
            linkRuntimePump.send(.deviceInformation(deviceId: identifier, uuid: uuid.uuidString, value: value))
        }

        nonisolated func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
            linkRuntimePump.send(.deviceInformationKey(deviceId: identifier, key: key, value: value))
        }
    }

    // MARK: - PolarBleApiDeviceFeaturesObserver

    extension PolarManager: PolarBleApiDeviceFeaturesObserver {
        nonisolated func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
            guard let strapFeature = Self.strapFeature(feature) else {
                PolarSDKLogBridge.noteFeatureReady("\(feature)")
                return
            }
            linkRuntimePump.send(.featureReady(deviceId: identifier, feature: strapFeature))
        }

        /// The SDK's summary once its readiness check ends. Features in neither
        /// list timed out; see `StrapFeatureWait.unconfirmed`.
        nonisolated func bleSdkFeaturesReadiness(
            _ identifier: String, ready: [PolarBleSdkFeature], unavailable: [PolarBleSdkFeature]
        ) {
            linkRuntimePump.send(.readinessSummary(
                deviceId: identifier,
                ready: Set(ready.compactMap(Self.strapFeature)),
                unavailable: Set(unavailable.compactMap(Self.strapFeature))
            ))
        }

        nonisolated static func strapFeature(_ feature: PolarBleSdkFeature) -> StrapFeature? {
            switch feature {
            case .feature_hr: .heartRate
            case .feature_polar_h10_exercise_recording: .h10Recording
            case .feature_polar_offline_recording: .offlineRecording
            case .feature_polar_online_streaming: .onlineStreaming
            default: nil
            }
        }
    }

    // MARK: - PolarBleApiPowerStateObserver

    extension PolarManager: PolarBleApiPowerStateObserver {
        nonisolated func blePowerOn() { linkRuntimePump.send(.powerOn) }
        nonisolated func blePowerOff() { linkRuntimePump.send(.powerOff) }
    }

    // MARK: - PolarBleApiLogger

    extension PolarManager: PolarBleApiLogger {
        /// The filter and the sinks live on `PolarSDKLogBridge`; only the
        /// conformance has to be here.
        nonisolated func message(_ str: String) { PolarSDKLogBridge.message(str) }
    }

#endif
