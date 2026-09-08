import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

/// Builds the Polar SDK handle with the feature set this app actually uses.
///
/// Its own type because `PolarManager` is over the aggregate type-size
/// threshold, and because the feature list is a statement about which straps
/// are supported and how — worth being able to read on its own rather than
/// mid-way through an initializer.
enum PolarSDKFactory {
    #if canImport(PolarBleSdk)
        /// `polarFilter(true)` restricts discovery to Polar devices; without it
        /// a scan returns every BLE peripheral in range.
        static func makeApi(queue: DispatchQueue) -> PolarBleApi {
            let api = PolarBleApiDefaultImpl.polarImplementation(queue, features: [
                .feature_hr,
                .feature_battery_info,
                .feature_device_info,
                .feature_polar_h10_exercise_recording, // H10: internal RR storage
                .feature_polar_offline_recording, // Verity Sense: offline PPI recording
                .feature_polar_online_streaming // Verity Sense: PPI streaming
            ])
            api.polarFilter(true)
            return api
        }
    #endif
}
