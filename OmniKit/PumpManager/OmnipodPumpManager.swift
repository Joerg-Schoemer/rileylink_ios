//
//  OmnipodPumpManager.swift
//  OmniKit
//
//  Created by Pete Schwamb on 8/4/18.
//  Copyright © 2018 Pete Schwamb. All rights reserved.
//

import HealthKit
import LoopKit
import RileyLinkKit
import RileyLinkBLEKit
import UserNotifications
import os.log


public enum ReservoirAlertState {
    case ok
    case lowReservoir
    case empty
}

public protocol PodStateObserver: AnyObject {
    func podStateDidUpdate(_ state: PodState?)
}

public enum PodCommState: Equatable {
    case noPod
    case activating
    case active
    case fault(DetailedStatus)
    case deactivating
}

public enum ReservoirLevelHighlightState: String, Equatable {
    case normal
    case warning
    case critical
}

public enum OmnipodPumpManagerError: Error {
    case noPodPaired
    case podAlreadyPaired
    case insulinTypeNotConfigured
    case notReadyForCannulaInsertion
    case invalidSetting
    case communication(Error)
    case state(Error)
}

extension OmnipodPumpManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("No pod paired", comment: "Error message shown when no pod is paired")
        case .podAlreadyPaired:
            return LocalizedString("Pod already paired", comment: "Error message shown when user cannot pair because pod is already paired")
        case .insulinTypeNotConfigured:
            return LocalizedString("Insulin type not configured", comment: "Error description for OmniBLEPumpManagerError.insulinTypeNotConfigured")
        case .notReadyForCannulaInsertion:
            return LocalizedString("Pod is not in a state ready for cannula insertion.", comment: "Error message when cannula insertion fails because the pod is in an unexpected state")
        case .communication(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        case .state(let error):
            if let error = error as? LocalizedError {
                return error.errorDescription
            } else {
                return String(describing: error)
            }
        case .invalidSetting:
            return LocalizedString("Invalid Setting", comment: "Error description for OmniBLEPumpManagerError.invalidSetting")
        }
    }

    public var failureReason: String? {
        return nil
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noPodPaired:
            return LocalizedString("Please pair a new pod", comment: "Recovery suggestion shown when no pod is paired")
        default:
            return nil
        }
    }
}

public class OmnipodPumpManager: RileyLinkPumpManager {
    
    public let managerIdentifier: String = "Omnipod"
    
    public let localizedTitle = LocalizedString("Omnipod", comment: "Generic title of the omnipod pump manager")
    
    public init(state: OmnipodPumpManagerState, rileyLinkDeviceProvider: RileyLinkDeviceProvider, rileyLinkConnectionManager: RileyLinkConnectionManager? = nil, dateGenerator: @escaping () -> Date = Date.init) {
        self.lockedState = Locked(state)
        self.lockedPodComms = Locked(PodComms(podState: state.podState))
        self.dateGenerator = dateGenerator
        super.init(rileyLinkDeviceProvider: rileyLinkDeviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)

        self.podComms.delegate = self
        self.podComms.messageLogger = self
    }

    public required convenience init?(rawState: PumpManager.RawStateValue) {
        guard let state = OmnipodPumpManagerState(rawValue: rawState),
            let connectionManagerState = state.rileyLinkConnectionManagerState else
        {
            return nil
        }

        let rileyLinkConnectionManager = RileyLinkConnectionManager(state: connectionManagerState)

        self.init(state: state, rileyLinkDeviceProvider: rileyLinkConnectionManager.deviceProvider, rileyLinkConnectionManager: rileyLinkConnectionManager)

        rileyLinkConnectionManager.delegate = self
    }

    private var podComms: PodComms {
        get {
            return lockedPodComms.value
        }
        set {
            lockedPodComms.value = newValue
        }
    }
    private let lockedPodComms: Locked<PodComms>

    private let podStateObservers = WeakSynchronizedSet<PodStateObserver>()

    // Primarily used for testing
    public let dateGenerator: () -> Date

    public var state: OmnipodPumpManagerState {
        return lockedState.value
    }

    private func setState(_ changes: (_ state: inout OmnipodPumpManagerState) -> Void) -> Void {
        return setStateWithResult(changes)
    }

    @discardableResult
    private func mutateState(_ changes: (_ state: inout OmnipodPumpManagerState) -> Void) -> OmnipodPumpManagerState {
        return setStateWithResult({ (state) -> OmnipodPumpManagerState in
            changes(&state)
            return state
        })
    }

    private func setStateWithResult<ReturnType>(_ changes: (_ state: inout OmnipodPumpManagerState) -> ReturnType) -> ReturnType {
        var oldValue: OmnipodPumpManagerState!
        var returnType: ReturnType!
        let newValue = lockedState.mutate { (state) in
            oldValue = state
            returnType = changes(&state)
        }

        guard oldValue != newValue else {
            return returnType
        }

        if oldValue.podState != newValue.podState {
            podStateObservers.forEach { (observer) in
                observer.podStateDidUpdate(newValue.podState)
            }

            if oldValue.podState?.lastInsulinMeasurements?.reservoirLevel != newValue.podState?.lastInsulinMeasurements?.reservoirLevel {
                if let lastInsulinMeasurements = newValue.podState?.lastInsulinMeasurements, let reservoirLevel = lastInsulinMeasurements.reservoirLevel {
                    self.pumpDelegate.notify({ (delegate) in
                        self.log.info("DU: updating reservoir level %{public}@", String(describing: reservoirLevel))
                        delegate?.pumpManager(self, didReadReservoirValue: reservoirLevel, at: lastInsulinMeasurements.validTime) { _ in }
                    })
                }
            }
        }


        // Ideally we ensure that oldValue.rawValue != newValue.rawValue, but the types aren't
        // defined as equatable
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerDidUpdateState(self)
        }

        let oldStatus = status(for: oldValue)
        let newStatus = status(for: newValue)

        if oldStatus != newStatus {
            notifyStatusObservers(oldStatus: oldStatus)
        }

        return returnType
    }
    private let lockedState: Locked<OmnipodPumpManagerState>

    private let statusObservers = WeakSynchronizedSet<PumpManagerStatusObserver>()

    private func notifyStatusObservers(oldStatus: PumpManagerStatus) {
        let status = self.status
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
        statusObservers.forEach { (observer) in
            observer.pumpManager(self, didUpdate: status, oldStatus: oldStatus)
        }
    }
    
    private func logDeviceCommunication(_ message: String, type: DeviceLogEntryType = .send) {
        var podAddress = "noPod"
        if let podState = self.state.podState {
            podAddress = String(format:"%04X", podState.address)
        }
        self.pumpDelegate.notify { (delegate) in
            delegate?.deviceManager(self, logEventForDeviceIdentifier: podAddress, type: type, message: message, completion: nil)
        }
    }

    private let pumpDelegate = WeakSynchronizedDelegate<PumpManagerDelegate>()

    public let log = OSLog(category: "OmnipodPumpManager")
    
    // MARK: - RileyLink Updates

    override public var rileyLinkConnectionManagerState: RileyLinkConnectionManagerState? {
        get {
            return state.rileyLinkConnectionManagerState
        }
        set {
            setState { (state) in
                state.rileyLinkConnectionManagerState = newValue
            }
        }
    }

    override public func deviceTimerDidTick(_ device: RileyLinkDevice) {
        pumpDelegate.notify { (delegate) in
            delegate?.pumpManagerBLEHeartbeatDidFire(self)
        }
    }
    
    public var rileyLinkBatteryAlertLevel: Int? {
        get {
            return state.rileyLinkBatteryAlertLevel
        }
        set {
            setState { state in
                state.rileyLinkBatteryAlertLevel = newValue
            }
        }
    }
    
    public override func device(_ device: RileyLinkDevice, didUpdateBattery level: Int) {
        let repeatInterval: TimeInterval = .hours(1)
        
        if let alertLevel = state.rileyLinkBatteryAlertLevel,
           level <= alertLevel,
           state.lastRileyLinkBatteryAlertDate.addingTimeInterval(repeatInterval) < Date()
        {
            self.setState { state in
                state.lastRileyLinkBatteryAlertDate = Date()
            }
            self.pumpDelegate.notify { delegate in
                let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: "lowRLBattery")
                let alertBody = String(format: LocalizedString("\"%1$@\" has a low battery", comment: "Format string for low battery alert body for RileyLink. (1: device name)"), device.name ?? "unnamed")
                let content = Alert.Content(title: LocalizedString("Low RileyLink Battery", comment: "Title for RileyLink low battery alert"), body: alertBody, acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Acknowledge button label for RileyLink low battery alert"))
                delegate?.issueAlert(Alert(identifier: identifier, foregroundContent: content, backgroundContent: content, trigger: .immediate))
            }
        }
    }

    // MARK: - CustomDebugStringConvertible

    override public var debugDescription: String {
        let lines = [
            "## OmnipodPumpManager",
            "podComms: \(String(reflecting: podComms))",
            "state: \(String(reflecting: state))",
            "status: \(String(describing: status))",
            "podStateObservers.count: \(podStateObservers.cleanupDeallocatedElements().count)",
            "statusObservers.count: \(statusObservers.cleanupDeallocatedElements().count)",
            super.debugDescription,
        ]
        return lines.joined(separator: "\n")
    }
}

extension OmnipodPumpManager {
    // MARK: - PodStateObserver
    
    public func addPodStateObserver(_ observer: PodStateObserver, queue: DispatchQueue) {
        podStateObservers.insert(observer, queue: queue)
    }
    
    public func removePodStateObserver(_ observer: PodStateObserver) {
        podStateObservers.removeElement(observer)
    }

    private func updateBLEHeartbeatPreference() {
        dispatchPrecondition(condition: .notOnQueue(delegateQueue))

        rileyLinkDeviceProvider.timerTickEnabled = self.state.isPumpDataStale || pumpDelegate.call({ (delegate) -> Bool in
            return delegate?.pumpManagerMustProvideBLEHeartbeat(self) == true
        })
    }

    public var expiresAt: Date? {
        return state.podState?.expiresAt
    }
    
    public func buildPumpStatusHighlight(for state: OmnipodPumpManagerState, andDate date: Date = Date()) -> PumpStatusHighlight? {
        if state.podState?.pendingCommand != nil {
            return PumpStatusHighlight(localizedMessage: NSLocalizedString("Comms Issue", comment: "Status highlight that delivery is uncertain."),
                                                         imageName: "exclamationmark.circle.fill",
                                                         state: .critical)
        }

        switch podCommState(for: state) {
        case .activating:
            return PumpStatusHighlight(
                localizedMessage: NSLocalizedString("Finish Pairing", comment: "Status highlight that when pod is activating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .deactivating:
            return PumpStatusHighlight(
                localizedMessage: NSLocalizedString("Finish Deactivation", comment: "Status highlight that when pod is deactivating."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .noPod:
            return PumpStatusHighlight(
                localizedMessage: NSLocalizedString("No Pod", comment: "Status highlight that when no pod is paired."),
                imageName: "exclamationmark.circle.fill",
                state: .warning)
        case .fault(let detail):
            var message: String
            switch detail.faultEventCode.faultType {
            case .reservoirEmpty:
                message = LocalizedString("No Insulin", comment: "Status highlight message for emptyReservoir alarm.")
            case .exceededMaximumPodLife80Hrs:
                message = LocalizedString("Pod Expired", comment: "Status highlight message for podExpired alarm.")
            case .occluded:
                message = LocalizedString("Pod Occlusion", comment: "Status highlight message for occlusion alarm.")
            default:
                message = LocalizedString("Pod Error", comment: "Status highlight message for other alarm.")
            }
            return PumpStatusHighlight(
                localizedMessage: message,
                imageName: "exclamationmark.circle.fill",
                state: .critical)
        case .active:
            if let reservoirPercent = state.reservoirLevel?.percentage, reservoirPercent == 0 {
                return PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("No Insulin", comment: "Status highlight that a pump is out of insulin."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            } else if state.podState?.isSuspended == true {
                return PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("Insulin Suspended", comment: "Status highlight that insulin delivery was suspended."),
                    imageName: "pause.circle.fill",
                    state: .warning)
            } else if date.timeIntervalSince(state.lastPumpDataReportDate ?? .distantPast) > .minutes(12) {
                return PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("No Data", comment: "Status highlight when communications with the pod haven't happened recently."),
                    imageName: "exclamationmark.circle.fill",
                    state: .critical)
            } else if isRunningManualTempBasal(for: state) {
                return PumpStatusHighlight(
                    localizedMessage: NSLocalizedString("Manual Basal", comment: "Status highlight when manual temp basal is running."),
                    imageName: "exclamationmark.circle.fill",
                    state: .warning)
            }
            return nil
        }
    }

    public func isRunningManualTempBasal(for state: OmnipodPumpManagerState) -> Bool {
        if let tempBasal = state.podState?.unfinalizedTempBasal, !tempBasal.automatic {
            return true
        }
        return false
    }

    public var reservoirLevelHighlightState: ReservoirLevelHighlightState? {
        guard let reservoirLevel = reservoirLevel else {
            return nil
        }

        switch reservoirLevel {
        case .aboveThreshold:
            return .normal
        case .valid(let value):
            if value > state.lowReservoirReminderValue {
                return .normal
            } else if value > 0 {
                return .warning
            } else {
                return .critical
            }
        }
    }

    public func buildPumpLifecycleProgress(for state: OmnipodPumpManagerState) -> PumpLifecycleProgress? {
        switch podCommState {
        case .active:
            if shouldWarnPodEOL,
               let podTimeRemaining = podTimeRemaining
            {
                let percentCompleted = max(0, min(1, (1 - (podTimeRemaining / Pod.nominalPodLife))))
                return PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .warning)
            } else if let podTimeRemaining = podTimeRemaining, podTimeRemaining <= 0 {
                // Pod is expired
                return PumpLifecycleProgress(percentComplete: 1, progressState: .critical)
            }
            return nil
        case .fault(let detail):
            if detail.faultEventCode.faultType == .exceededMaximumPodLife80Hrs {
                return PumpLifecycleProgress(percentComplete: 100, progressState: .critical)
            } else {
                if shouldWarnPodEOL,
                   let durationBetweenLastPodCommAndActivation = durationBetweenLastPodCommAndActivation
                {
                    let percentCompleted = max(0, min(1, durationBetweenLastPodCommAndActivation / Pod.nominalPodLife))
                    return PumpLifecycleProgress(percentComplete: percentCompleted, progressState: .dimmed)
                }
            }
            return nil
        case .noPod, .activating, .deactivating:
            return nil
        }
    }

    private func status(for state: OmnipodPumpManagerState) -> PumpManagerStatus {
        return PumpManagerStatus(
            timeZone: state.timeZone,
            device: device(for: state),
            pumpBatteryChargeRemaining: nil,
            basalDeliveryState: basalDeliveryState(for: state),
            bolusState: bolusState(for: state),
            insulinType: state.insulinType
        )
    }

    private func device(for state: OmnipodPumpManagerState) -> HKDevice {
        if let podState = state.podState {
            return HKDevice(
                name: managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: podState.piVersion,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: String(format:"%04X", podState.address),
                udiDeviceIdentifier: nil
            )
        } else {
            return HKDevice(
                name: managerIdentifier,
                manufacturer: "Insulet",
                model: "Eros",
                hardwareVersion: nil,
                firmwareVersion: nil,
                softwareVersion: String(OmniKitVersionNumber),
                localIdentifier: nil,
                udiDeviceIdentifier: nil
            )
        }
    }

    private func basalDeliveryState(for state: OmnipodPumpManagerState) -> PumpManagerStatus.BasalDeliveryState {
        guard let podState = state.podState else {
            return .suspended(state.lastPumpDataReportDate ?? .distantPast)
        }

        switch state.suspendEngageState {
        case .engaging:
            return .suspending
        case .disengaging:
            return .resuming
        case .stable:
            break
        }

        switch state.tempBasalEngageState {
        case .engaging:
            return .initiatingTempBasal
        case .disengaging:
            return .cancelingTempBasal
        case .stable:
            if let tempBasal = podState.unfinalizedTempBasal, !tempBasal.isFinished() {
                return .tempBasal(DoseEntry(tempBasal))
            }
            switch podState.suspendState {
            case .resumed(let date):
                return .active(date)
            case .suspended(let date):
                return .suspended(date)
            }
        }
    }

    private func bolusState(for state: OmnipodPumpManagerState) -> PumpManagerStatus.BolusState {
        guard let podState = state.podState else {
            return .noBolus
        }

        switch state.bolusEngageState {
        case .engaging:
            return .initiating
        case .disengaging:
            return .canceling
        case .stable:
            if let bolus = podState.unfinalizedBolus, !bolus.isFinished() {
                return .inProgress(DoseEntry(bolus))
            }
        }
        return .noBolus
    }

    private func podCommState(for state: OmnipodPumpManagerState) -> PodCommState {
        guard let podState = state.podState else {
            return .noPod
        }
        guard podState.fault == nil else {
            return .fault(podState.fault!)
        }

        if podState.isActive {
            return .active
        } else if !podState.isSetupComplete {
            return .activating
        }
        return .deactivating
    }

    public var podCommState: PodCommState {
        return podCommState(for: state)
    }

    public var podActivatedAt: Date? {
        return state.podState?.activatedAt
    }

    public var podExpiresAt: Date? {
        return state.podState?.expiresAt
    }

    public var hasActivePod: Bool {
        return state.hasActivePod
    }

    public var hasSetupPod: Bool {
        return state.hasSetupPod
    }

    // If time remaining is negative, the pod has been expired for that amount of time.
    public var podTimeRemaining: TimeInterval? {
        guard let expiresAt = state.podState?.expiresAt else { return nil }
        return expiresAt.timeIntervalSince(dateGenerator())
    }

    private var shouldWarnPodEOL: Bool {
        guard let podTimeRemaining = podTimeRemaining,
              podTimeRemaining > 0 && podTimeRemaining <= Pod.timeRemainingWarningThreshold else
        {
            return false
        }

        return true
    }

    public var durationBetweenLastPodCommAndActivation: TimeInterval? {
        guard let lastPodCommDate = state.podState?.lastInsulinMeasurements?.validTime,
              let activationTime = podActivatedAt else
        {
            return nil
        }

        return lastPodCommDate.timeIntervalSince(activationTime)
    }
    
    // Thread-safe
    public var beepPreference: BeepPreference {
        get {
            return state.confirmationBeeps
        }
    }

    // From last status response
    public var reservoirLevel: ReservoirLevel? {
        return state.reservoirLevel
    }

    public var podTotalDelivery: HKQuantity? {
        guard let delivery = state.podState?.lastInsulinMeasurements?.delivered else {
            return nil
        }
        return HKQuantity(unit: .internationalUnit(), doubleValue: delivery)
    }

    public var lastStatusDate: Date? {
        guard let date = state.podState?.lastInsulinMeasurements?.validTime else {
            return nil
        }
        return date
    }


    // MARK: - Pod comms

    // Does not support concurrent callers. Not thread-safe.
    public func forgetPod(completion: @escaping () -> Void) {

        let resetPodState = { (_ state: inout OmnipodPumpManagerState) in
            self.podComms = PodComms(podState: nil)
            self.podComms.delegate = self
            self.podComms.messageLogger = self

            state.updatePodStateFromPodComms(nil)
        }

        podComms.forgetPod()

        if let dosesToStore = self.state.podState?.dosesToStore {
            self.store(doses: dosesToStore, completion: { error in
                self.setState({ (state) in
                    if error != nil {
                        state.unstoredDoses.append(contentsOf: dosesToStore)
                    }

                    resetPodState(&state)
                })
                completion()
            })
        } else {
            self.setState { (state) in
                resetPodState(&state)
            }

            completion()
        }
    }
    
    // MARK: Testing
    #if targetEnvironment(simulator)
    private func jumpStartPod(address: UInt32, lot: UInt32, tid: UInt32, fault: DetailedStatus? = nil, startDate: Date? = nil, mockFault: Bool) {
        let start = startDate ?? Date()
        var podState = PodState(address: address, piVersion: "jumpstarted", pmVersion: "jumpstarted", lot: lot, tid: tid, insulinType: .novolog)
        podState.setupProgress = .podPaired
        podState.activatedAt = start
        podState.expiresAt = start + .hours(72)
        
        let fault = mockFault ? try? DetailedStatus(encodedData: Data(hexadecimalString: "020f0000000900345c000103ff0001000005ae056029")!) : nil
        podState.fault = fault

        podComms = PodComms(podState: podState)

        setState({ (state) in
            state.updatePodStateFromPodComms(podState)
        })
    }
    #endif
    
    // MARK: - Pairing

    // Called on the main thread
    public func pairAndPrime(completion: @escaping (PumpManagerResult<TimeInterval>) -> Void) {
        
        guard let insulinType = insulinType else {
            completion(.failure(.configuration(nil)))
            return
        }
        
        #if targetEnvironment(simulator)
        // If we're in the simulator, create a mock PodState
        let mockFaultDuringPairing = false
        let mockCommsErrorDuringPairing = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {
            self.jumpStartPod(address: 0x1f0b3557, lot: 40505, tid: 6439, mockFault: mockFaultDuringPairing)
            self.podComms.mockPodStateChanges { podState in
                podState.setupProgress = .priming
            }
            let fault: DetailedStatus? = self.state.podState?.fault

            if mockFaultDuringPairing {
                completion(.failure(PumpManagerError.deviceState(PodCommsError.podFault(fault: fault!))))
            } else if mockCommsErrorDuringPairing {
                completion(.failure(PumpManagerError.communication(PodCommsError.noResponse)))
            } else {
                let mockPrimeDuration = TimeInterval(.seconds(3))
                completion(.success(mockPrimeDuration))
            }
        }
        #else
        let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        let primeSession = { (result: PodComms.SessionRunResult) in
            switch result {
            case .success(let session):
                // We're on the session queue
                session.assertOnSessionQueue()

                self.log.default("Beginning pod prime")

                // Clean up any previously un-stored doses if needed
                let unstoredDoses = self.state.unstoredDoses
                if self.store(doses: unstoredDoses, in: session) {
                    self.setState({ (state) in
                        state.unstoredDoses.removeAll()
                    })
                }

                do {
                    let primeFinishedAt = try session.prime()
                    completion(.success(primeFinishedAt))
                } catch let error {
                    completion(.failure(PumpManagerError.communication(error as? LocalizedError)))
                }
            case .failure(let error):
                completion(.failure(PumpManagerError.communication(error)))
            }
        }

        let needsPairing = setStateWithResult({ (state) -> Bool in
            guard let podState = state.podState else {
                return true // Needs pairing
            }

            // Return true if not yet paired
            return podState.setupProgress.isPaired == false
        })

        if needsPairing {
            self.log.default("Pairing pod before priming")
            
            // Create random address with 20 bits to match PDM, could easily use 24 bits instead
            if self.state.pairingAttemptAddress == nil {
                self.lockedState.mutate { (state) in
                    state.pairingAttemptAddress = 0x1f000000 | (arc4random() & 0x000fffff)
                }
            }

            self.podComms.assignAddressAndSetupPod(
                address: self.state.pairingAttemptAddress!,
                using: deviceSelector,
                timeZone: .currentFixed,
                messageLogger: self,
                insulinType: insulinType)
            { (result) in
                
                if case .success = result {
                    self.lockedState.mutate { (state) in
                        state.pairingAttemptAddress = nil
                    }
                }
                
                // Calls completion
                primeSession(result)
            }
        } else {
            self.log.default("Pod already paired. Continuing.")

            self.podComms.runSession(withName: "Prime pod", using: deviceSelector) { (result) in
                // Calls completion
                primeSession(result)
            }
        }
        #endif
    }

    // Called on the main thread
    public func insertCannula(completion: @escaping (Result<TimeInterval,OmnipodPumpManagerError>) -> Void) {

        #if targetEnvironment(simulator)
        let mockDelay = TimeInterval(seconds: 3)
        let mockFaultDuringInsertCannula = false
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + mockDelay) {
            let result = self.setStateWithResult({ (state) -> Result<TimeInterval,OmnipodPumpManagerError> in
                if mockFaultDuringInsertCannula {
                    let fault = try! DetailedStatus(encodedData: Data(hexadecimalString: "020d0000000e00c36a020703ff020900002899080082")!)
                    var podState = state.podState
                    podState?.fault = fault
                    state.updatePodStateFromPodComms(podState)
                    return .failure(OmnipodPumpManagerError.communication(PodCommsError.podFault(fault: fault)))
                }

                // Mock success
                var podState = state.podState
                podState?.setupProgress = .completed
                state.updatePodStateFromPodComms(podState)
                return .success(mockDelay)
            })

            completion(result)
        }
        #else
        let preError = setStateWithResult({ (state) -> OmnipodPumpManagerError? in
            guard let podState = state.podState, podState.readyForCannulaInsertion else
            {
                return .notReadyForCannulaInsertion
            }

            state.scheduledExpirationReminderOffset = state.defaultExpirationReminderOffset

            guard podState.setupProgress.needsCannulaInsertion else {
                return .podAlreadyPaired
            }

            return nil
        })

        if let error = preError {
            completion(.failure(.state(error)))
            return
        }

        let timeZone = self.state.timeZone

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName:  "Insert cannula", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    if self.state.podState?.setupProgress.needsInitialBasalSchedule == true {
                        let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                        try session.programInitialBasalSchedule(self.state.basalSchedule, scheduleOffset: scheduleOffset)

                        session.dosesForStorage() { (doses) -> Bool in
                            return self.store(doses: doses, in: session)
                        }
                    }

                    let expiration = self.podExpiresAt ?? Date().addingTimeInterval(Pod.nominalPodLife)
                    let timeUntilExpirationReminder = expiration.addingTimeInterval(-self.state.defaultExpirationReminderOffset).timeIntervalSince(self.dateGenerator())

                    let alerts: [PodAlert] = [
                        .expirationReminder(self.state.defaultExpirationReminderOffset > 0 ? timeUntilExpirationReminder : 0),
                        .lowReservoir(self.state.lowReservoirReminderValue)
                    ]

                    let finishWait = try session.insertCannula(optionalAlerts: alerts)
                    completion(.success(finishWait))
                } catch let error {
                    completion(.failure(.communication(error)))
                }
            case .failure(let error):
                completion(.failure(.communication(error)))
            }
        }
        #endif
    }

    public func checkCannulaInsertionFinished(completion: @escaping (OmnipodPumpManagerError?) -> Void) {
        let deviceSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Check cannula insertion finished", using: deviceSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.checkInsertionCompleted()
                    completion(nil)
                } catch let error {
                    self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                    completion(.communication(error))
                }
            case .failure(let error):
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                completion(.communication(error))
            }
        }
    }

    public func refreshStatus(emitConfirmationBeep: Bool, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        guard self.hasActivePod else {
            completion?(.failure(.deviceState(OmnipodPumpManagerError.noPodPaired)))
            return
        }

        self.getPodStatus(storeDosesOnSuccess: false, emitConfirmationBeep: emitConfirmationBeep, completion: completion)
    }

    // MARK: - Pump Commands

    public func getPodStatus(storeDosesOnSuccess: Bool = true, emitConfirmationBeep: Bool = false, completion: ((_ result: PumpManagerResult<StatusResponse>) -> Void)? = nil) {
        guard state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else {
            self.log.info("Skipping status request due to unfinalized bolus in progress.")
            completion?(.failure(PumpManagerError.deviceState(PodCommsError.unfinalizedBolus)))
            return
        }
        
        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        podComms.runSession(withName: "Get pod status", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    let status = try session.getStatus(confirmationBeepType: nil)
                    if storeDosesOnSuccess {
                        session.dosesForStorage({ (doses) -> Bool in
                            self.store(doses: doses, in: session)
                        })
                    }
                    completion?(.success(status))
                } catch let error {
                    completion?(.failure(PumpManagerError.communication(error as? LocalizedError)))
                }
            case .failure(let error):
                self.log.error("Failed to fetch pod status: %{public}@", String(describing: error))
                completion?(.failure(PumpManagerError.communication(error)))
            }
        }
    }

    public func setTime(completion: @escaping (OmnipodPumpManagerError?) -> Void) {
        
        guard state.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        guard state.podState?.unfinalizedBolus?.isFinished() != false else {
            completion(.state(PodCommsError.unfinalizedBolus))
            return
        }

        let timeZone = TimeZone.currentFixed
        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Set time zone", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    let beep = self.beepPreference.shouldBeepForManualCommand
                    let _ = try session.setTime(timeZone: timeZone, basalSchedule: self.state.basalSchedule, date: Date(), acknowledgementBeep: beep, completionBeep: beep)
                    self.setState { (state) in
                        state.timeZone = timeZone
                    }
                    completion(nil)
                } catch let error {
                    completion(.communication(error))
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
    }

    public func setBasalSchedule(_ schedule: BasalSchedule, completion: @escaping (Error?) -> Void) {
        let shouldContinue = setStateWithResult({ (state) -> PumpManagerResult<Bool> in
            guard state.hasActivePod else {
                // If there's no active pod yet, save the basal schedule anyway
                state.basalSchedule = schedule
                return .success(false)
            }

            guard state.podState?.unfinalizedBolus?.isFinished() != false else {
                return .failure(PumpManagerError.deviceState(PodCommsError.unfinalizedBolus))
            }

            return .success(true)
        })

        switch shouldContinue {
        case .success(true):
            break
        case .success(false):
            completion(nil)
            return
        case .failure(let error):
            completion(error)
            return
        }

        let timeZone = self.state.timeZone

        self.podComms.runSession(withName: "Save Basal Profile", using: self.rileyLinkDeviceProvider.firstConnectedDevice) { (result) in
            do {
                switch result {
                case .success(let session):
                    let scheduleOffset = timeZone.scheduleOffset(forDate: Date())
                    let result = session.cancelDelivery(deliveryType: .all)
                    switch result {
                    case .certainFailure(let error):
                        throw error
                    case .unacknowledged(let error):
                        throw error
                    case .success:
                        break
                    }
                    let beep = self.beepPreference.shouldBeepForManualCommand
                    let _ = try session.setBasalSchedule(schedule: schedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)

                    self.setState { (state) in
                        state.basalSchedule = schedule
                    }
                    completion(nil)
                case .failure(let error):
                    throw error
                }
            } catch let error {
                self.log.error("Save basal profile failed: %{public}@", String(describing: error))
                completion(error)
            }
        }
    }

    // Called on the main thread.
    // The UI is responsible for serializing calls to this method;
    // it does not handle concurrent calls.
    public func deactivatePod(completion: @escaping (OmnipodPumpManagerError?) -> Void) {
        #if targetEnvironment(simulator)
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .seconds(2)) {

            self.forgetPod(completion: {
                completion(nil)
            })
        }
        #else
        guard self.state.podState != nil else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Deactivate pod", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    try session.deactivatePod()

                    self.forgetPod(completion: {
                        completion(nil)
                    })
                } catch let error {
                    completion(OmnipodPumpManagerError.communication(error))
                }
            case .failure(let error):
                completion(OmnipodPumpManagerError.communication(error))
            }
        }
        #endif
    }

    public func playTestBeeps(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }
        guard state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else {
            self.log.info("Skipping Play Test Beeps due to bolus still in progress.")
            completion(PodCommsError.unfinalizedBolus)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Play Test Beeps", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                let beep = self.beepPreference.shouldBeepForManualCommand
                let result = session.beepConfig(beepConfigType: .bipBeepBipBeepBipBeepBipBeep, basalCompletionBeep: beep, tempBasalCompletionBeep: false, bolusCompletionBeep: beep)
                
                switch result {
                case .success:
                    completion(nil)
                case .failure(let error):
                    completion(error)
                }
            case .failure(let error):
                completion(error)
            }
        }
    }

    public func readPulseLog(completion: @escaping (Result<String, Error>) -> Void) {
        // use hasSetupPod to be able to read the pulse log from a faulted Pod
        guard self.hasSetupPod else {
            completion(.failure(OmnipodPumpManagerError.noPodPaired))
            return
        }
        guard state.podState?.isFaulted == true || state.podState?.unfinalizedBolus?.scheduledCertainty == .uncertain || state.podState?.unfinalizedBolus?.isFinished() != false else
        {
            self.log.info("Skipping Read Pulse Log due to bolus still in progress.")
            completion(.failure(PodCommsError.unfinalizedBolus))
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Read Pulse Log", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                do {
                    // read the most recent 50 entries from the pulse log
                    let podInfoResponse = try session.readPodInfo(podInfoResponseSubType: .pulseLogRecent, confirmationBeepType: nil)
                    guard let podInfoPulseLogRecent = podInfoResponse.podInfo as? PodInfoPulseLogRecent else {
                        self.log.error("Unable to decode PulseLogRecent: %s", String(describing: podInfoResponse))
                        completion(.failure(PodCommsError.unexpectedResponse(response: .podInfoResponse)))
                        return
                    }
                    let lastPulseNumber = Int(podInfoPulseLogRecent.indexLastEntry)
                    let str = pulseLogString(pulseLogEntries: podInfoPulseLogRecent.pulseLog, lastPulseNumber: lastPulseNumber)
                    completion(.success(str))
                } catch let error {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func setConfirmationBeeps(newPreference: BeepPreference, completion: @escaping (OmnipodPumpManagerError?) -> Void) {
        self.log.default("Set Confirmation Beeps to %s", String(describing: newPreference))
        guard self.hasActivePod else {
            self.setState { state in
                state.confirmationBeeps = newPreference // set here to allow changes on a faulted Pod
            }
            completion(nil)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Set Confirmation Beeps Preference", using: rileyLinkSelector) { (result) in
            switch result {
            case .success(let session):
                let beepConfigType: BeepConfigType = newPreference.shouldBeepForManualCommand ? .bipBip : .noBeep
                let basalCompletionBeep = newPreference.shouldBeepForManualCommand
                let tempBasalCompletionBeep = false
                let bolusCompletionBeep = newPreference.shouldBeepForManualCommand

                // enable/disable Pod completion beeps for any in-progress insulin delivery
                let result = session.beepConfig(beepConfigType: beepConfigType, basalCompletionBeep: basalCompletionBeep, tempBasalCompletionBeep: tempBasalCompletionBeep, bolusCompletionBeep: bolusCompletionBeep)

                switch result {
                case .success:
                    self.setState { state in
                        state.confirmationBeeps = newPreference
                    }
                    completion(nil)
                case .failure(let error):
                    completion(.communication(error))
                }
            case .failure(let error):
                completion(.communication(error))
            }
        }
    }
}

// MARK: - PumpManager
extension OmnipodPumpManager: PumpManager {
    public static var onboardingMaximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public static var onboardingSupportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported scheduled basal rate
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public static var onboardingSupportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public static var onboardingSupportedMaximumBolusVolumes: [Double] {
        return onboardingSupportedBolusVolumes
    }

    public var supportedBolusVolumes: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported bolus volume
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public var supportedMaximumBolusVolumes: [Double] {
        supportedBolusVolumes
    }

    public var supportedBasalRates: [Double] {
        // 0.05 units for rates between 0.05-30U/hr
        // 0 is not a supported scheduled basal rate
        return (1...600).map { Double($0) / Double(Pod.pulsesPerUnit) }
    }

    public func roundToSupportedBolusVolume(units: Double) -> Double {
        // We do support rounding a 0 U volume to 0
        return supportedBolusVolumes.last(where: { $0 <= units }) ?? 0
    }

    public func roundToSupportedBasalRate(unitsPerHour: Double) -> Double {
        // We do support rounding a 0 U/hr rate to 0
        return supportedBasalRates.last(where: { $0 <= unitsPerHour }) ?? 0
    }

    public var maximumBasalScheduleEntryCount: Int {
        return Pod.maximumBasalScheduleEntryCount
    }

    public var minimumBasalScheduleEntryDuration: TimeInterval {
        return Pod.minimumBasalScheduleEntryDuration
    }

    public var pumpRecordsBasalProfileStartEvents: Bool {
        return false
    }

    public var pumpReservoirCapacity: Double {
        return Pod.reservoirCapacity
    }

    public var isOnboarded: Bool { state.isOnboarded }

    public var lastSync: Date? {
        return self.state.podState?.lastInsulinMeasurements?.validTime
    }
    
    public var insulinType: InsulinType? {
        get {
            return self.state.insulinType
        }
        set {
            if let insulinType = newValue {
                self.setState { (state) in
                    state.insulinType = insulinType
                }
                //self.podComms.insulinType = insulinType
            }
        }
    }

    public var defaultExpirationReminderOffset: TimeInterval {
        set {
            mutateState { (state) in
                state.defaultExpirationReminderOffset = newValue
            }
        }
        get {
            state.defaultExpirationReminderOffset
        }
    }

    public var lowReservoirReminderValue: Double {
        set {
            mutateState { (state) in
                state.lowReservoirReminderValue = newValue
            }
        }
        get {
            state.lowReservoirReminderValue
        }
    }

    public var podAttachmentConfirmed: Bool {
        set {
            mutateState { (state) in
                state.podAttachmentConfirmed = newValue
            }
        }
        get {
            state.podAttachmentConfirmed
        }
    }

    public var initialConfigurationCompleted: Bool {
        set {
            mutateState { (state) in
                state.initialConfigurationCompleted = newValue
            }
        }
        get {
            state.initialConfigurationCompleted
        }
    }

    public var status: PumpManagerStatus {
        // Acquire the lock just once
        let state = self.state

        return status(for: state)
    }

    public var rawState: PumpManager.RawStateValue {
        return state.rawValue
    }

    public var pumpManagerDelegate: PumpManagerDelegate? {
        get {
            return pumpDelegate.delegate
        }
        set {
            pumpDelegate.delegate = newValue

            // TODO: is there still a scenario where this is required?
            // self.schedulePodExpirationNotification()
        }
    }

    public var delegateQueue: DispatchQueue! {
        get {
            return pumpDelegate.queue
        }
        set {
            pumpDelegate.queue = newValue
        }
    }

    // MARK: Methods

    public func completeOnboard() {
        setState({ (state) in
            state.isOnboarded = true
        })
    }

    public func suspendDelivery(completion: @escaping (Error?) -> Void) {
        let suspendTime: TimeInterval = .minutes(0) // untimed suspend with reminder beeps
        suspendDelivery(withSuspendReminders: suspendTime, completion: completion)
    }

    // A nil suspendReminder is untimed with no reminders beeps, a suspendReminder of 0 is untimed using reminders beeps, otherwise it
    // specifies a suspend duration implemented using an appropriate combination of suspended reminder and suspend time expired beeps.
    public func suspendDelivery(withSuspendReminders suspendReminder: TimeInterval? = nil, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Suspend", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .engaging
            })

            let beepType: BeepConfigType? = self.beepPreference.shouldBeepForManualCommand ? .beeeeeep : nil
            let result = session.suspendDelivery(suspendReminder: suspendReminder, confirmationBeepType: beepType)
            switch result {
            case .certainFailure(let error):
                completion(error)
            case .unacknowledged(let error):
                completion(error)
            case .success:
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            }
        }
    }

    public func resumeDelivery(completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Resume", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(error)
                return
            }

            defer {
                self.setState({ (state) in
                    state.suspendEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.suspendEngageState = .disengaging
            })

            do {
                let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                let beep = self.beepPreference.shouldBeepForManualCommand
                let _ = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } catch (let error) {
                completion(error)
            }
        }
    }

    public func addStatusObserver(_ observer: PumpManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: PumpManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    public func setMustProvideBLEHeartbeat(_ mustProvideBLEHeartbeat: Bool) {
        rileyLinkDeviceProvider.timerTickEnabled = self.state.isPumpDataStale || mustProvideBLEHeartbeat
    }
    
    public func ensureCurrentPumpData(completion: ((Date?) -> Void)?) {
        let shouldFetchStatus = setStateWithResult { (state) -> Bool? in
            guard state.hasActivePod else {
                return nil // No active pod
            }
            return state.isPumpDataStale
        }
        
        checkRileyLinkBattery()

        switch shouldFetchStatus {
        case .none:
            completion?(lastSync)
            return // No active pod
        case true?:
            log.default("Fetching status because pumpData is too old")
            getPodStatus(storeDosesOnSuccess: true, emitConfirmationBeep: false) { (response) in
                self.pumpDelegate.notify({ (delegate) in
                    switch response {
                    case .failure(let error):
                        delegate?.pumpManager(self, didError: error)
                    default:
                        break
                    }
                    completion?(self.lastSync)
                })
            }
        case false?:
            log.default("Skipping status update because pumpData is fresh")
            completion?(lastSync)
        }
    }
    
    private func checkRileyLinkBattery() {
        rileyLinkDeviceProvider.getDevices { devices in
            for device in devices {
                device.updateBatteryLevel()
            }
        }
    }

    public func enactBolus(units: Double, automatic: Bool, completion: @escaping (PumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(.configuration(OmnipodPumpManagerError.noPodPaired))
            return
        }

        // Round to nearest supported volume
        let enactUnits = roundToSupportedBolusVolume(units: units)

        let beep = automatic ? beepPreference.shouldBeepForAutomaticBolus : beepPreference.shouldBeepForManualCommand

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Bolus", using: rileyLinkSelector) { (result) in
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }
            
            defer {
                self.setState({ (state) in
                    state.bolusEngageState = .stable
                })
            }
            self.setState({ (state) in
                state.bolusEngageState = .engaging
            })

            // Initialize to true to match existing Medtronic PumpManager behavior for any
            // manual boluses or to false to never auto resume a suspended pod for any bolus.
            let autoResumeOnManualBolus = true

            if case .some(.suspended) = self.state.podState?.suspendState {
                // Pod suspended, only auto resume for a manual bolus if autoResumeOnManualBolus is true
                if automatic || autoResumeOnManualBolus == false {
                    self.log.error("enactBolus: returning pod suspended error for %@ bolus", automatic ? "automatic" : "manual")
                    completion(.deviceState(PodCommsError.podSuspended))
                    return
                }
                do {
                    let scheduleOffset = self.state.timeZone.scheduleOffset(forDate: Date())
                    let podStatus = try session.resumeBasal(schedule: self.state.basalSchedule, scheduleOffset: scheduleOffset, acknowledgementBeep: beep, completionBeep: beep)
                    guard podStatus.deliveryStatus.bolusing == false else {
                        completion(.deviceState(PodCommsError.unfinalizedBolus))
                        return
                    }
                } catch let error {
                    self.log.error("enactBolus: error resuming suspended pod: %@", String(describing: error))
                    completion(.communication(error as? LocalizedError))
                    return
                }
            }

            var getStatusNeeded = false // initializing to true effectively disables the bolus comms getStatus optimization
            var finalizeFinishedDosesNeeded = false

            // Skip the getStatus comms optimization for a manual bolus,
            // if there was a comms issue on the last message sent, or
            // if the last delivery status hasn't been verified
            if automatic == false || self.state.podState?.lastCommsOK == false ||
                self.state.podState?.deliveryStatusVerified == false
            {
                self.log.info("enactBolus: skipping getStatus comms optimization")
                getStatusNeeded = true
            } else if let unfinalizedBolus = self.state.podState?.unfinalizedBolus {
                if unfinalizedBolus.scheduledCertainty == .uncertain {
                    self.log.info("enactBolus: doing getStatus with uncertain bolus scheduled certainty")
                    getStatusNeeded = true
                } else if unfinalizedBolus.isFinished() == false {
                    self.log.info("enactBolus: not enacting bolus because podState indicates unfinalized bolus in progress")
                    completion(.deviceState(PodCommsError.unfinalizedBolus))
                    return
                } else if unfinalizedBolus.isBolusPositivelyFinished == false {
                    self.log.info("enactBolus: doing getStatus to verify bolus completion")
                    getStatusNeeded = true
                } else {
                    finalizeFinishedDosesNeeded = true // call finalizeFinishDoses() to clean up the certain & positively finalized bolus
                }
            }

            if getStatusNeeded {
                do {
                    let podStatus = try session.getStatus()
                    guard podStatus.deliveryStatus.bolusing == false else {
                        completion(.deviceState(PodCommsError.unfinalizedBolus))
                        return
                    }
                } catch let error {
                    completion(.communication(error as? LocalizedError))
                    return
                }
            } else if finalizeFinishedDosesNeeded {
                session.finalizeFinishedDoses()
            }

            // Use a maximum programReminderInterval value of 0x3F to denote an automatic bolus in the communication log
            let programReminderInterval: TimeInterval = automatic ? TimeInterval(minutes: 0x3F) : 0

            let result = session.bolus(units: enactUnits, automatic: automatic, acknowledgementBeep: beep, completionBeep: beep && !automatic, programReminderInterval: programReminderInterval)
            session.dosesForStorage() { (doses) -> Bool in
                return self.store(doses: doses, in: session)
            }

            switch result {
            case .success:
                completion(nil)
            case .certainFailure(let error):
                completion(.communication(error))
            case .unacknowledged(let error):
                // TODO: Return PumpManagerError.uncertainDelivery and implement recovery
                completion(.communication(error))
            }
        }
    }

    public func cancelBolus(completion: @escaping (PumpManagerResult<DoseEntry?>) -> Void) {
        guard self.hasActivePod else {
            completion(.failure(PumpManagerError.communication(OmnipodPumpManagerError.noPodPaired)))
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Cancel Bolus", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.failure(PumpManagerError.communication(error)))
                return
            }

            do {
                defer {
                    self.setState({ (state) in
                        state.bolusEngageState = .stable
                    })
                }
                self.setState({ (state) in
                    state.bolusEngageState = .disengaging
                })
                
                if let bolus = self.state.podState?.unfinalizedBolus, !bolus.isFinished(), bolus.scheduledCertainty == .uncertain {
                    let status = try session.getStatus()
                    
                    if !status.deliveryStatus.bolusing {
                        completion(.success(nil))
                        return
                    }
                }

                // when cancelling a bolus use the built-in type 6 beeeeeep to match PDM if confirmation beeps are enabled
                let beepType: BeepType = self.beepPreference.shouldBeepForManualCommand ? .beeeeeep : .noBeep
                let result = session.cancelDelivery(deliveryType: .bolus, beepType: beepType)
                switch result {
                case .certainFailure(let error):
                    throw error
                case .unacknowledged(let error):
                    throw error
                case .success(_, let canceledBolus):
                    session.dosesForStorage() { (doses) -> Bool in
                        return self.store(doses: doses, in: session)
                    }

                    let canceledDoseEntry: DoseEntry? = canceledBolus != nil ? DoseEntry(canceledBolus!) : nil
                    completion(.success(canceledDoseEntry))
                }
            } catch {
                // TODO: Return PumpManagerError.uncertainDelivery and implement recovery
                completion(.failure(PumpManagerError.communication(error as? LocalizedError)))
            }
        }
    }

    public func enactTempBasal(unitsPerHour: Double, for duration: TimeInterval, completion: @escaping (PumpManagerError?) -> Void) {
        runTemporaryBasalProgram(unitsPerHour: unitsPerHour, for: duration, automatic: true, completion: completion)
    }

    public func runTemporaryBasalProgram(unitsPerHour: Double, for duration: TimeInterval, automatic: Bool, completion: @escaping (PumpManagerError?) -> Void) {

        guard self.hasActivePod else {
            completion(.configuration(OmnipodPumpManagerError.noPodPaired))
            return
        }

        // Round to nearest supported rate
        let rate = roundToSupportedBasalRate(unitsPerHour: unitsPerHour)

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Enact Temp Basal", using: rileyLinkSelector) { (result) in
            self.log.info("Enact temp basal %.03fU/hr for %ds", rate, Int(duration))
            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            if case .some(.suspended) = self.state.podState?.suspendState {
                self.log.info("Not enacting temp basal because podState indicates pod is suspended.")
                completion(.deviceState(PodCommsError.podSuspended))
                return
            }

            // A resume scheduled basal delivery request is denoted by a 0 duration that cancels any existing temp basal.
            let resumingScheduledBasal = duration < .ulpOfOne

            // If a bolus is not finished, fail if not resuming the scheduled basal
            guard self.state.podState?.unfinalizedBolus?.isFinished() != false || resumingScheduledBasal else {
                self.log.info("Not enacting temp basal because podState indicates unfinalized bolus in progress.")
                completion(.deviceState(PodCommsError.unfinalizedBolus))
                return
            }

            // Did the last message have comms issues or is the last delivery status not yet verified?
            let uncertainDeliveryStatus = self.state.podState?.lastCommsOK == false ||
                self.state.podState?.deliveryStatusVerified == false

            // Do the cancel temp basal command if currently running a temp basal OR
            // if resuming scheduled basal delivery OR if the delivery status is uncertain.
            if self.state.podState?.unfinalizedTempBasal != nil || resumingScheduledBasal || uncertainDeliveryStatus {
                let status: StatusResponse

                let result = session.cancelDelivery(deliveryType: .tempBasal)
                switch result {
                case .certainFailure(let error):
                    completion(.communication(error))
                    return
                case .unacknowledged(let error):
                    // TODO: Return PumpManagerError.uncertainDelivery and implement recovery
                    completion(.communication(error))
                    return
                case .success(let cancelTempStatus, _):
                    status = cancelTempStatus
                }

                // If pod is bolusing, fail if not resuming the scheduled basal
                guard !status.deliveryStatus.bolusing || resumingScheduledBasal else {
                    self.log.info("Canceling temp basal because status return indicates bolus in progress.")
                    completion(.communication(PodCommsError.unfinalizedBolus))
                    return
                }

                guard status.deliveryStatus != .suspended else {
                    self.log.info("Canceling temp basal because status return indicates pod is suspended!")
                    completion(.communication(PodCommsError.podSuspended))
                    return
                }
            } else {
                self.log.info("Skipped Cancel TB command before enacting temp basal")
            }

            defer {
                self.setState({ (state) in
                    state.tempBasalEngageState = .stable
                })
            }

            if resumingScheduledBasal {
                self.setState({ (state) in
                    state.tempBasalEngageState = .disengaging
                })
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                completion(nil)
            } else {
                self.setState({ (state) in
                    state.tempBasalEngageState = .engaging
                })

                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = self.state.timeZone
                let scheduledRate = self.state.basalSchedule.currentRate(using: calendar, at: self.dateGenerator())
                let isHighTemp = rate > scheduledRate

                let beep = !automatic && self.beepPreference.shouldBeepForManualCommand

                let result = session.setTempBasal(rate: rate, duration: duration, isHighTemp: isHighTemp, automatic: automatic, acknowledgementBeep: beep, completionBeep: false)
                session.dosesForStorage() { (doses) -> Bool in
                    return self.store(doses: doses, in: session)
                }
                switch result {
                case .success:
                    completion(nil)
                case .unacknowledged(let error):
                    self.log.error("Temp basal uncertain error: %@", String(describing: error))
                    completion(nil)
                case .certainFailure(let error):
                    completion(.communication(error))
                }
            }
        }
    }

    /// Returns a dose estimator for the current bolus, if one is in progress
    public func createBolusProgressReporter(reportingOn dispatchQueue: DispatchQueue) -> DoseProgressReporter? {
        if case .inProgress(let dose) = bolusState(for: self.state) {
            return PodDoseProgressEstimator(dose: dose, pumpManager: self, reportingQueue: dispatchQueue)
        }
        return nil
    }
    
    public func setMaximumTempBasalRate(_ rate: Double) {}

    public func syncBasalRateSchedule(items scheduleItems: [RepeatingScheduleValue<Double>], completion: @escaping (Result<BasalRateSchedule, Error>) -> Void) {
        let newSchedule = BasalSchedule(repeatingScheduleValues: scheduleItems)
        setBasalSchedule(newSchedule) { (error) in
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(BasalRateSchedule(dailyItems: scheduleItems, timeZone: self.state.timeZone)!))
            }
        }
    }

    public func syncDeliveryLimits(limits deliveryLimits: DeliveryLimits, completion: @escaping (Result<DeliveryLimits, Error>) -> Void) {
        completion(.success(deliveryLimits))
    }

    // MARK: - Alerts

    public var isClockOffset: Bool {
        let now = dateGenerator()
        return TimeZone.current.secondsFromGMT(for: now) != state.timeZone.secondsFromGMT(for: now)
    }

    func checkForTimeOffsetChange() {
        let isAlertActive = state.activeAlerts.contains(.timeOffsetChangeDetected)

        if !isAlertActive && isClockOffset && !state.acknowledgedTimeOffsetAlert {
            issueAlert(alert: .timeOffsetChangeDetected)
        } else if isAlertActive && !isClockOffset {
            retractAlert(alert: .timeOffsetChangeDetected)
        }
    }

    public func updateExpirationReminder(_ intervalBeforeExpiration: TimeInterval?, completion: @escaping (OmnipodPumpManagerError?) -> Void) {

        guard self.hasActivePod, let podState = state.podState, let expiresAt = podState.expiresAt else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Update Expiration Reminder", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            var timeUntilReminder : TimeInterval = 0
            if let intervalBeforeExpiration = intervalBeforeExpiration, intervalBeforeExpiration > 0 {
                timeUntilReminder = expiresAt.addingTimeInterval(-intervalBeforeExpiration).timeIntervalSince(self.dateGenerator())
            }

            let expirationReminder = PodAlert.expirationReminder(timeUntilReminder)
            do {
                try session.configureAlerts([expirationReminder], confirmationBeepType: self.beepPreference.shouldBeepForManualCommand ? .beep : .noBeep)
                self.mutateState({ (state) in
                    state.scheduledExpirationReminderOffset = intervalBeforeExpiration
                })
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }

    public var allowedExpirationReminderDates: [Date]? {
        guard let expiration = state.podState?.expiresAt else {
            return nil
        }

        let allDates = Array(stride(
            from: -Pod.expirationReminderAlertMaxHoursBeforeExpiration,
            through: -Pod.expirationReminderAlertMinHoursBeforeExpiration,
            by: 1)).map
        { (i: Int) -> Date in
            expiration.addingTimeInterval(.hours(Double(i)))
        }
        let now = dateGenerator()
        return allDates.filter { $0.timeIntervalSince(now) > 0 }
    }

    public var scheduledExpirationReminder: Date? {
        guard let expiration = state.podState?.expiresAt, let offset = state.scheduledExpirationReminderOffset, offset > 0 else {
            return nil
        }

        // It is possible the scheduledExpirationReminderOffset does not fall on the hour, but instead be a few seconds off
        // since the allowedExpirationReminderDates are by the hour, force the offset to be on the hour
        return expiration.addingTimeInterval(-.hours(round(offset.hours)))
    }

    public func updateLowReservoirReminder(_ value: Int, completion: @escaping (OmnipodPumpManagerError?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
        self.podComms.runSession(withName: "Program Low Reservoir Reminder", using: rileyLinkSelector) { (result) in

            let session: PodCommsSession
            switch result {
            case .success(let s):
                session = s
            case .failure(let error):
                completion(.communication(error))
                return
            }

            let lowReservoirReminder = PodAlert.lowReservoir(Double(value))
            do {
                try session.configureAlerts([lowReservoirReminder], confirmationBeepType: self.beepPreference.shouldBeepForManualCommand ? .beep : .noBeep)
                self.mutateState({ (state) in
                    state.lowReservoirReminderValue = Double(value)
                })
                completion(nil)
            } catch {
                completion(.communication(error))
                return
            }
        }
    }

    func issueAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.alertIdentifier)
        let loopAlert = Alert(identifier: identifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .immediate)
        pumpDelegate.notify { (delegate) in
            delegate?.issueAlert(loopAlert)
        }

        if let repeatInterval = alert.repeatInterval {
            // Schedule an additional repeating 15 minute reminder for suspend period ended.
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            let loopAlert = Alert(identifier: repeatingIdentifier, foregroundContent: alert.foregroundContent, backgroundContent: alert.backgroundContent, trigger: .repeating(repeatInterval: repeatInterval))
            pumpDelegate.notify { (delegate) in
                delegate?.issueAlert(loopAlert)
            }
        }

        self.mutateState { (state) in
            state.activeAlerts.insert(alert)
        }
    }

    func retractAlert(alert: PumpManagerAlert) {
        let identifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.alertIdentifier)
        pumpDelegate.notify { (delegate) in
            delegate?.retractAlert(identifier: identifier)
        }
        if alert.isRepeating {
            let repeatingIdentifier = Alert.Identifier(managerIdentifier: self.managerIdentifier, alertIdentifier: alert.repeatingAlertIdentifier)
            pumpDelegate.notify { (delegate) in
                delegate?.retractAlert(identifier: repeatingIdentifier)
            }
        }
        self.mutateState { (state) in
            state.activeAlerts.remove(alert)
        }
    }

    private func alertsChanged(oldAlerts: AlertSet, newAlerts: AlertSet) {
        guard let podState = state.podState else {
            preconditionFailure("trying to manage alerts without podState")
        }

        let (added, removed) = oldAlerts.compare(to: newAlerts)
        for slot in added {
            if let podAlert = podState.configuredAlerts[slot] {
                log.default("Alert slot triggered: %{public}@", String(describing: slot))
                if let pumpManagerAlert = getPumpManagerAlert(for: podAlert, slot: slot) {
                    issueAlert(alert: pumpManagerAlert)
                } else {
                    log.default("Ignoring alert: %{public}@", String(describing: podAlert))
                }
            } else {
                log.error("Unconfigured alert slot triggered: %{public}@", String(describing: slot))
            }
        }
        for alert in removed {
            log.default("Alert slot cleared: %{public}@", String(describing: alert))
        }
    }

    private func getPumpManagerAlert(for podAlert: PodAlert, slot: AlertSlot) -> PumpManagerAlert? {
        guard let podState = state.podState, let expiresAt = podState.expiresAt else {
            preconditionFailure("trying to lookup alert info without podState")
        }

        guard !podAlert.isIgnored else {
            return nil
        }

        switch podAlert {
        case .podSuspendedReminder:
            return PumpManagerAlert.suspendInProgress(triggeringSlot: slot)
        case .expirationReminder:
            guard let offset = state.scheduledExpirationReminderOffset, offset > 0 else {
                return nil
            }
            let timeToExpiry = TimeInterval(hours: expiresAt.timeIntervalSince(dateGenerator()).hours.rounded())
            return PumpManagerAlert.userPodExpiration(triggeringSlot: slot, scheduledExpirationReminderOffset: timeToExpiry)
        case .expired:
            return PumpManagerAlert.podExpiring(triggeringSlot: slot)
        case .shutdownImminent:
            return PumpManagerAlert.podExpireImminent(triggeringSlot: slot)
        case .lowReservoir(let units):
            return PumpManagerAlert.lowReservoir(triggeringSlot: slot, lowReservoirReminderValue: units)
        case .finishSetupReminder, .waitingForPairingReminder:
            return PumpManagerAlert.finishSetupReminder(triggeringSlot: slot)
        case .suspendTimeExpired:
            return PumpManagerAlert.suspendEnded(triggeringSlot: slot)
        default:
            return nil
        }
    }

    private func silenceAcknowledgedAlerts() {
        // Only attempt to clear one per cycle (more than one should be rare)
        if let alert = state.alertsWithPendingAcknowledgment.first {
            if let slot = alert.triggeringSlot {
                let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
                self.podComms.runSession(withName: "Silence already acknowledged alert", using: rileyLinkSelector) { (result) in
                    switch result {
                    case .success(let session):
                        do {
                            let _ = try session.acknowledgeAlerts(alerts: AlertSet(slots: [slot]), confirmationBeepType: self.beepPreference.shouldBeepForManualCommand ? .beep : .noBeep)
                        } catch {
                            return
                        }
                        self.mutateState { state in
                            state.activeAlerts.remove(alert)
                            state.alertsWithPendingAcknowledgment.remove(alert)
                        }
                    case .failure:
                        return
                    }
                }
            }
        }
    }

    static let podAlarmNotificationIdentifier = "Omnipod:\(LoopNotificationCategory.pumpFault.rawValue)"

    private func notifyPodFault(fault: DetailedStatus) {
        pumpDelegate.notify { delegate in
            let content = Alert.Content(title: fault.faultEventCode.notificationTitle,
                                        body: fault.faultEventCode.notificationBody,
                                        acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledgment OK button"))
            delegate?.issueAlert(Alert(identifier: Alert.Identifier(managerIdentifier: OmnipodPumpManager.podAlarmNotificationIdentifier,
                                                                    alertIdentifier: fault.faultEventCode.description),
                                       foregroundContent: content, backgroundContent: content,
                                       trigger: .immediate))
        }
    }

    // MARK: - Reporting Doses

    // This cannot be called from within the lockedState lock!
    func store(doses: [UnfinalizedDose], in session: PodCommsSession) -> Bool {
        session.assertOnSessionQueue()

        // We block the session until the data's confirmed stored by the delegate
        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        store(doses: doses) { (error) in
            success = (error == nil)
            semaphore.signal()
        }

        semaphore.wait()

        if success {
            setState { (state) in
                state.lastPumpDataReportDate = Date()
            }
        }
        return success
    }

    func store(doses: [UnfinalizedDose], completion: @escaping (_ error: Error?) -> Void) {
        let lastSync = lastSync

        pumpDelegate.notify { (delegate) in
            guard let delegate = delegate else {
                preconditionFailure("pumpManagerDelegate cannot be nil")
            }

            delegate.pumpManager(self, hasNewPumpEvents: doses.map { NewPumpEvent($0) }, lastSync: lastSync, completion: { (error) in
                if let error = error {
                    self.log.error("Error storing pod events: %@", String(describing: error))
                } else {
                    self.log.info("DU: Stored pod events: %@", String(describing: doses))
                }

                completion(error)
            })
        }
    }
}

extension OmnipodPumpManager: MessageLogger {
    func didSend(_ message: Data) {
        log.default("didSend: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .send)
    }
    
    func didReceive(_ message: Data) {
        log.default("didReceive: %{public}@", message.hexadecimalString)
        self.logDeviceCommunication(message.hexadecimalString, type: .receive)
    }
}

extension OmnipodPumpManager: PodCommsDelegate {
    func podComms(_ podComms: PodComms, didChange podState: PodState?) {
        setState { (state) in
            // Check for any updates to bolus certainty, and log them
            if let podState = state.podState, let bolus = podState.unfinalizedBolus, bolus.scheduledCertainty == .uncertain, !bolus.isFinished() {
                if bolus.scheduledCertainty == .certain {
                    self.log.default("Resolved bolus uncertainty: did bolus")
                } else if podState.unfinalizedBolus == nil {
                    self.log.default("Resolved bolus uncertainty: did not bolus")
                }
            }
            state.updatePodStateFromPodComms(podState)
        }
    }
}

// MARK: - AlertResponder implementation
extension OmnipodPumpManager {
    public func acknowledgeAlert(alertIdentifier: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        guard self.hasActivePod else {
            completion(OmnipodPumpManagerError.noPodPaired)
            return
        }

        for alert in state.activeAlerts {
            if alert.alertIdentifier == alertIdentifier {
                // If this alert was triggered by the pod find the slot to clear it.
                if let slot = alert.triggeringSlot {
                    let rileyLinkSelector = self.rileyLinkDeviceProvider.firstConnectedDevice
                    self.podComms.runSession(withName: "Acknowledge Alert", using: rileyLinkSelector) { (result) in
                        switch result {
                        case .success(let session):
                            do {
                                let _ = try session.acknowledgeAlerts(alerts: AlertSet(slots: [slot]), confirmationBeepType: self.beepPreference.shouldBeepForManualCommand ? .beep : .noBeep)
                            } catch {
                                self.mutateState { state in
                                    state.alertsWithPendingAcknowledgment.insert(alert)
                                }
                                completion(error)
                                return
                            }
                            self.mutateState { state in
                                state.activeAlerts.remove(alert)
                            }
                            completion(nil)
                        case .failure(let error):
                            self.mutateState { state in
                                state.alertsWithPendingAcknowledgment.insert(alert)
                            }
                            completion(error)
                            return
                        }
                    }
                } else {
                    // Non-pod alert
                    self.mutateState { state in
                        state.activeAlerts.remove(alert)
                        if alert == .timeOffsetChangeDetected {
                            state.acknowledgedTimeOffsetAlert = true
                        }
                    }
                    completion(nil)
                }
            }
        }
    }
}

// MARK: - AlertSoundVendor implementation
extension OmnipodPumpManager {
    public func getSoundBaseURL() -> URL? { return nil }
    public func getSounds() -> [Alert.Sound] { return [] }
}

extension FaultEventCode {
    public var notificationTitle: String {
        switch self.faultType {
        case .reservoirEmpty:
            return LocalizedString("Empty Reservoir", comment: "The title for Empty Reservoir alarm notification")
        case .occluded, .occlusionCheckStartup1, .occlusionCheckStartup2, .occlusionCheckTimeouts1, .occlusionCheckTimeouts2, .occlusionCheckTimeouts3, .occlusionCheckPulseIssue, .occlusionCheckBolusProblem:
            return LocalizedString("Occlusion Detected", comment: "The title for Occlusion alarm notification")
        case .exceededMaximumPodLife80Hrs:
            return LocalizedString("Pod Expired", comment: "The title for Pod Expired alarm notification")
        default:
            return LocalizedString("Critical Pod Error", comment: "The title for AlarmCode.other notification")
        }
    }

    public var notificationBody: String {
        return LocalizedString("Insulin delivery stopped. Change Pod now.", comment: "The default notification body for AlarmCodes")
    }
}
