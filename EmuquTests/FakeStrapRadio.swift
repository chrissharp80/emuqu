@testable import Emuqu
import Foundation
import PolarBleSdk

/// A strap that isn't there.
///
/// Answers the sixteen calls the app makes on the Polar SDK (`StrapRadio`) from
/// a script, so the sequences that only ever ran on a chest — arming the H10's
/// overnight recording, the morning fetch, a Verity night — can be driven in a
/// test. It records what was asked of it, in order, so a test can assert the
/// app did not, say, clear a recording before reading it.
///
/// Every stored property is behind one lock: the app calls these from the main
/// actor, from detached tasks, and from stream consumers, and a fake that races
/// would fail for reasons that have nothing to do with the code under test.
final class FakeStrapRadio: StrapRadio, @unchecked Sendable {
    /// One call the app made.
    enum Call: Equatable {
        case connect(String)
        case disconnect(String)
        case startHrStreaming
        case startPpiStreaming
        case startRecording(exerciseId: String)
        case stopRecording
        case requestRecordingStatus
        case listExercises
        case fetchExercise(entryId: String)
        case removeExercise(entryId: String)
        case startOfflineRecording
        case stopOfflineRecording
        case offlineRecordingStatus
        case listOfflineRecordings
        case getOfflineRecord(path: String)
        case removeOfflineRecord(path: String)
    }

    /// A listing row, in Sendable pieces. `PolarOfflineRecordingEntry` is not
    /// Sendable, so the entry is built where it is handed over.
    private struct OfflineRow: Sendable {
        let path: String
        let date: Date
    }

    private struct State {
        var calls: [Call] = []
        var recordingOngoing = false
        var recordingEntryId = ""
        var exercises: [PolarExerciseEntry] = []
        var exerciseData: [String: PolarExerciseData] = [:]
        var offlineEntries: [OfflineRow] = []
        var offlineData: [String: PolarOfflineRecordingData] = [:]
        var offlineOngoing: [PolarDeviceDataType: Bool] = [:]
        var hrSamples: [[StrapHRSample]] = []
        var hrPeripheralIds: [UUID?] = []
        var ppiSamples: [PolarPpiData] = []
        /// Refusals to serve before each call type starts succeeding — the
        /// SDK's "not ready yet" answer while the strap finishes its setup.
        var refusalsLeft: [String: Int] = [:]
    }

    private let state = NSLock()
    private var value = State()

    private func withState<T>(_ body: (inout State) -> T) -> T {
        state.lock()
        defer { state.unlock() }
        return body(&value)
    }

    // MARK: - Scripting

    var calls: [Call] { withState { $0.calls } }
    /// The peripheral each heart-rate subscription was asked to attach to.
    var hrPeripheralIds: [UUID?] { withState { $0.hrPeripheralIds } }

    func setRecording(ongoing: Bool, entryId: String = "") {
        withState { $0.recordingOngoing = ongoing; $0.recordingEntryId = entryId }
    }

    /// An exercise sitting on the strap, with the beats it holds.
    func addExercise(entryId: String, path: String = "/U/0/E", date: Date = Date(), rrMs: [UInt32]) {
        withState {
            $0.exercises.append((path: path, date: date, entryId: entryId))
            $0.exerciseData[entryId] = (interval: 1, samples: rrMs)
        }
    }

    /// A Verity offline recording. `path` decides how the SDK's listing groups
    /// it: a night split into sub-files lists once per file.
    func addOfflineRecording(path: String, date: Date, ppiMs: [Int]) {
        let samples = ppiMs.map {
            (
                timeStamp: UInt64(0), hr: 60, ppInMs: UInt16($0), ppErrorEstimate: UInt16(0),
                blockerBit: 0, skinContactStatus: 1, skinContactSupported: 1
            )
        }
        withState {
            $0.offlineEntries.append(OfflineRow(path: path, date: date))
            $0.offlineData[path] = .ppiOfflineRecordingData((timeStamp: 0, samples: samples), startTime: date)
        }
    }

    func setOfflineRecordingOngoing(_ ongoing: Bool, feature: PolarDeviceDataType = .ppi) {
        withState { $0.offlineOngoing[feature] = ongoing }
    }

    func queueHeartRate(bpm: Int, rrsMs: [Int]) {
        withState {
            $0.hrSamples.append([StrapHRSample(hr: bpm, rrsMs: rrsMs, rrAvailable: !rrsMs.isEmpty)])
        }
    }

    /// Make `call` refuse `times` times before it starts working, the way the
    /// SDK refuses locally until the strap's services are up.
    func refuse(_ call: String, times: Int, with error: Error = PolarErrors.notificationNotEnabled) {
        withState { $0.refusalsLeft[call] = times }
        refusalError = error
    }

    private var refusalError: Error = PolarErrors.notificationNotEnabled

    private func refusalIfDue(_ call: String) -> Error? {
        withState {
            guard let left = $0.refusalsLeft[call], left > 0 else { return nil }
            $0.refusalsLeft[call] = left - 1
            return refusalError
        }
    }

    private func record(_ call: Call) { withState { $0.calls.append(call) } }

    // MARK: - StrapRadio

    func connectToDevice(_ identifier: String) throws { record(.connect(identifier)) }
    func disconnectFromDevice(_ identifier: String) throws { record(.disconnect(identifier)) }

    func searchForDevice() -> AsyncThrowingStream<PolarDeviceInfo, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func startHrStreaming(_: String, peripheralId: UUID?) -> AsyncThrowingStream<[StrapHRSample], Error> {
        record(.startHrStreaming)
        withState { $0.hrPeripheralIds.append(peripheralId) }
        if let error = refusalIfDue("startHrStreaming") {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let queued = withState { $0.hrSamples }
        return AsyncThrowingStream { continuation in
            queued.forEach { continuation.yield($0) }
            // Stays open, like the real subscription: the feed treats a stream
            // that ends as something to re-open.
        }
    }

    func startPpiStreaming(_: String) -> AsyncThrowingStream<PolarPpiData, Error> {
        record(.startPpiStreaming)
        if let error = refusalIfDue("startPpiStreaming") {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let queued = withState { $0.ppiSamples }
        return AsyncThrowingStream { continuation in
            queued.forEach { continuation.yield($0) }
        }
    }

    func startRecording(
        _: String, exerciseId: String, interval _: RecordingInterval, sampleType _: SampleType
    ) async throws {
        record(.startRecording(exerciseId: exerciseId))
        if let error = refusalIfDue("startRecording") { throw error }
        // A real H10 refuses while a recording is already running; overwriting
        // it would be the SDK losing the user's night, which it does not do.
        if withState({ $0.recordingOngoing }) {
            throw PolarErrors.deviceError(description: "recording already running")
        }
        withState { $0.recordingOngoing = true; $0.recordingEntryId = exerciseId }
    }

    func stopRecording(_: String) async throws {
        record(.stopRecording)
        if let error = refusalIfDue("stopRecording") { throw error }
        withState { $0.recordingOngoing = false }
    }

    func requestRecordingStatus(_: String) async throws -> PolarRecordingStatus {
        record(.requestRecordingStatus)
        if let error = refusalIfDue("requestRecordingStatus") { throw error }
        return withState { (ongoing: $0.recordingOngoing, entryId: $0.recordingEntryId) }
    }

    func listExercises(_: String) -> AsyncThrowingStream<PolarExerciseEntry, Error> {
        record(.listExercises)
        if let error = refusalIfDue("listExercises") {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let entries = withState { $0.exercises }
        return AsyncThrowingStream { continuation in
            entries.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    func fetchExercise(_: String, entry: PolarExerciseEntry) async throws -> PolarExerciseData {
        record(.fetchExercise(entryId: entry.entryId))
        if let error = refusalIfDue("fetchExercise") { throw error }
        guard let data = withState({ $0.exerciseData[entry.entryId] }) else {
            throw PolarErrors.deviceError(description: "no such exercise")
        }
        return data
    }

    func removeExercise(_: String, entry: PolarExerciseEntry) async throws {
        record(.removeExercise(entryId: entry.entryId))
        withState {
            $0.exercises.removeAll { $0.entryId == entry.entryId }
            $0.exerciseData[entry.entryId] = nil
        }
    }

    func startOfflineRecording(
        _: String, feature: PolarDeviceDataType, settings _: PolarSensorSetting?, secret _: PolarRecordingSecret?
    ) async throws {
        record(.startOfflineRecording)
        if let error = refusalIfDue("startOfflineRecording") { throw error }
        withState { $0.offlineOngoing[feature] = true }
    }

    func stopOfflineRecording(_: String, feature: PolarDeviceDataType) async throws {
        record(.stopOfflineRecording)
        if let error = refusalIfDue("stopOfflineRecording") { throw error }
        withState { $0.offlineOngoing[feature] = false }
    }

    func getOfflineRecordingStatus(_: String) async throws -> [PolarDeviceDataType: Bool] {
        record(.offlineRecordingStatus)
        if let error = refusalIfDue("getOfflineRecordingStatus") { throw error }
        return withState { $0.offlineOngoing }
    }

    func listOfflineRecordings(_: String) -> AsyncThrowingStream<PolarOfflineRecordingEntry, Error> {
        record(.listOfflineRecordings)
        if let error = refusalIfDue("listOfflineRecordings") {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let rows = withState { $0.offlineEntries }
        return AsyncThrowingStream { continuation in
            for row in rows {
                continuation.yield(PolarOfflineRecordingEntry(
                    path: row.path, size: 1024, date: row.date, type: .ppi
                ))
            }
            continuation.finish()
        }
    }

    func getOfflineRecord(
        _: String, entry: PolarOfflineRecordingEntry, secret _: PolarRecordingSecret?
    ) async throws -> PolarOfflineRecordingData {
        record(.getOfflineRecord(path: entry.path))
        if let error = refusalIfDue("getOfflineRecord") { throw error }
        guard let data = withState({ $0.offlineData[entry.path] }) else {
            throw PolarErrors.deviceError(description: "no such recording")
        }
        return data
    }

    func removeOfflineRecord(_: String, entry: PolarOfflineRecordingEntry) async throws {
        record(.removeOfflineRecord(path: entry.path))
        withState {
            // Removing one sub-file removes the recording's directory, so a
            // second removal for the same recording finds nothing — the real
            // failure behind the duplicated-download bug.
            let key = StrapOfflineRecordingEntries.recordingKey(forPath: entry.path)
            guard $0.offlineEntries.contains(where: {
                StrapOfflineRecordingEntries.recordingKey(forPath: $0.path) == key
            }) else { return }
            $0.offlineEntries.removeAll {
                StrapOfflineRecordingEntries.recordingKey(forPath: $0.path) == key
            }
        }
    }
}
