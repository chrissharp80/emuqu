import Foundation
#if canImport(PolarBleSdk)
    import PolarBleSdk
#endif

#if canImport(PolarBleSdk)

    /// Everything the app asks the strap's radio to do.
    ///
    /// ## Why this exists
    ///
    /// The Polar SDK is the one part of the recording path that cannot run in a
    /// test: it needs a strap on a chest and a radio. That left the paths this
    /// product exists for — arming the H10's overnight recording, fetching it
    /// in the morning, a Verity Sense night — provable only by wearing the
    /// strap overnight and looking at the result the next day. A night is a
    /// slow unit test, and a wrong answer costs the user the night.
    ///
    /// Seventeen calls is the app's entire surface on the strap. Behind this
    /// protocol, `StrapAPI` forwards live heart rate to the standard Heart Rate
    /// Service and every other call to Polar; in tests a fake strap answers
    /// them, so the sequencing around them — readiness, retries, date
    /// validation, sub-file grouping, the morning fetch — is exercised for
    /// real.
    ///
    /// The protocol deliberately speaks the SDK's own types. Translating them
    /// would mean a second model to keep in step with Polar's, and the bugs
    /// worth catching here live in the sequence, not in the field names. Heart
    /// rate is the exception because it does not come from the SDK.
    protocol StrapRadio: Sendable {
        // MARK: Connection
        func connectToDevice(_ identifier: String) throws
        func disconnectFromDevice(_ identifier: String) throws
        func searchForDevice() -> AsyncThrowingStream<PolarDeviceInfo, Error>

        // MARK: Online streaming
        /// Live heart rate, from the strap's standard Heart Rate Service — not
        /// the SDK's, which delivers only after its full setup of the strap
        /// (`StandardHeartRateLink`). `peripheralId` is the strap's
        /// CoreBluetooth identifier, reported with the SDK's connection.
        @MainActor func startHrStreaming(
            _ identifier: String, peripheralId: UUID?
        ) -> AsyncThrowingStream<[StrapHRSample], Error>
        func startPpiStreaming(_ identifier: String) -> AsyncThrowingStream<PolarPpiData, Error>

        // MARK: H10 exercise recording
        func startRecording(
            _ identifier: String, exerciseId: String, interval: RecordingInterval, sampleType: SampleType
        ) async throws
        func stopRecording(_ identifier: String) async throws
        func requestRecordingStatus(_ identifier: String) async throws -> PolarRecordingStatus
        func listExercises(_ identifier: String) -> AsyncThrowingStream<PolarExerciseEntry, Error>
        func fetchExercise(_ identifier: String, entry: PolarExerciseEntry) async throws -> PolarExerciseData
        func removeExercise(_ identifier: String, entry: PolarExerciseEntry) async throws

        // MARK: Verity Sense offline recording
        func startOfflineRecording(
            _ identifier: String, feature: PolarDeviceDataType,
            settings: PolarSensorSetting?, secret: PolarRecordingSecret?
        ) async throws
        func stopOfflineRecording(_ identifier: String, feature: PolarDeviceDataType) async throws
        func getOfflineRecordingStatus(_ identifier: String) async throws -> [PolarDeviceDataType: Bool]
        func listOfflineRecordings(_ identifier: String) -> AsyncThrowingStream<PolarOfflineRecordingEntry, Error>
        func getOfflineRecord(
            _ identifier: String, entry: PolarOfflineRecordingEntry, secret: PolarRecordingSecret?
        ) async throws -> PolarOfflineRecordingData
        func removeOfflineRecord(_ identifier: String, entry: PolarOfflineRecordingEntry) async throws
    }

    /// The Polar SDK, and the standard Heart Rate Service for live heart rate,
    /// behind the protocol.
    ///
    /// `@unchecked Sendable`: the SDK object is thread-safe by contract (every
    /// call is marshalled onto its own queues) but Polar does not declare it
    /// `Sendable`. This wrapper is the one place that assertion is made, so the
    /// coordinators' async helpers can hold it across suspension points.
    struct StrapAPI: StrapRadio, @unchecked Sendable {
        let sdk: PolarBleApi
        let heartRate: StandardHeartRateLink

        func connectToDevice(_ identifier: String) throws { try sdk.connectToDevice(identifier) }
        func disconnectFromDevice(_ identifier: String) throws { try sdk.disconnectFromDevice(identifier) }
        func searchForDevice() -> AsyncThrowingStream<PolarDeviceInfo, Error> { sdk.searchForDevice() }

        @MainActor func startHrStreaming(
            _ identifier: String, peripheralId: UUID?
        ) -> AsyncThrowingStream<[StrapHRSample], Error> {
            heartRate.samples(peripheralId: peripheralId)
        }

        func startPpiStreaming(_ identifier: String) -> AsyncThrowingStream<PolarPpiData, Error> {
            sdk.startPpiStreaming(identifier)
        }

        func startRecording(
            _ identifier: String, exerciseId: String, interval: RecordingInterval, sampleType: SampleType
        ) async throws {
            try await sdk.startRecording(identifier, exerciseId: exerciseId, interval: interval, sampleType: sampleType)
        }

        func stopRecording(_ identifier: String) async throws { try await sdk.stopRecording(identifier) }

        func requestRecordingStatus(_ identifier: String) async throws -> PolarRecordingStatus {
            try await sdk.requestRecordingStatus(identifier)
        }

        func listExercises(_ identifier: String) -> AsyncThrowingStream<PolarExerciseEntry, Error> {
            sdk.listExercises(identifier)
        }

        func fetchExercise(_ identifier: String, entry: PolarExerciseEntry) async throws -> PolarExerciseData {
            try await sdk.fetchExercise(identifier, entry: entry)
        }

        func removeExercise(_ identifier: String, entry: PolarExerciseEntry) async throws {
            try await sdk.removeExercise(identifier, entry: entry)
        }

        func startOfflineRecording(
            _ identifier: String, feature: PolarDeviceDataType,
            settings: PolarSensorSetting?, secret: PolarRecordingSecret?
        ) async throws {
            try await sdk.startOfflineRecording(identifier, feature: feature, settings: settings, secret: secret)
        }

        func stopOfflineRecording(_ identifier: String, feature: PolarDeviceDataType) async throws {
            try await sdk.stopOfflineRecording(identifier, feature: feature)
        }

        func getOfflineRecordingStatus(_ identifier: String) async throws -> [PolarDeviceDataType: Bool] {
            try await sdk.getOfflineRecordingStatus(identifier)
        }

        func listOfflineRecordings(_ identifier: String) -> AsyncThrowingStream<PolarOfflineRecordingEntry, Error> {
            sdk.listOfflineRecordings(identifier)
        }

        func getOfflineRecord(
            _ identifier: String, entry: PolarOfflineRecordingEntry, secret: PolarRecordingSecret?
        ) async throws -> PolarOfflineRecordingData {
            try await sdk.getOfflineRecord(identifier, entry: entry, secret: secret)
        }

        func removeOfflineRecord(_ identifier: String, entry: PolarOfflineRecordingEntry) async throws {
            try await sdk.removeOfflineRecord(identifier, entry: entry)
        }
    }

#endif
