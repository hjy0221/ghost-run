import Combine
import CoreLocation
import Foundation

// GameEngine depends only on this input boundary. The existing UI keeps using
// LocationService; tests can supply locations without creating CLLocationManager.
protocol GameLocationSource: AnyObject {
    var currentLocation: CLLocation? { get }
    var locations: AnyPublisher<CLLocation, Never> { get }
    var errors: AnyPublisher<String, Never> { get }
    var isSimulationEnabled: Bool { get }
    var isAuthorized: Bool { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    func startTracking()
    func stopTracking()
    func setGameplayTrackingProfile(_ active: Bool)
    func refreshStationaryFixIfNeeded()
    func advanceSimulation(by seconds: TimeInterval)
}

final class LocationService: NSObject, ObservableObject, GameLocationSource {
    var locations: AnyPublisher<CLLocation, Never> {
        $currentLocation.compactMap { $0 }.eraseToAnyPublisher()
    }
    var errors: AnyPublisher<String, Never> {
        $lastErrorMessage.compactMap { $0 }.eraseToAnyPublisher()
    }
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var accuracyAuthorization: CLAccuracyAuthorization
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var isTracking = false
    @Published private(set) var isSimulationEnabled = false
    @Published var simulatedSpeed: Double = 0
    @Published var simulatedHeading: Double = 15

    private let manager = CLLocationManager()
    private var wantsTracking = false
    private var usesGameplayProfile = false
    // Debug starts on a MapKit-returned pedestrian path, not inside City Hall.
    private let fallbackCoordinate = CLLocationCoordinate2D(latitude: 37.5670488, longitude: 126.978155)
    private var simulationCoordinate: CLLocationCoordinate2D?
#if DEBUG
    private var simulationCursor: WalkingCursor?
    func followSimulationPath(_ path: WalkingPath) {
        guard isSimulationEnabled, let coordinate = currentLocation?.coordinate else { return }
        let match = path.projection(of: coordinate)
        guard match.separation <= GameConfiguration.standard.routeMatchTolerance else { return }
        var cursor = WalkingCursor(path: path)
        cursor.advance(meters: match.offset)
        simulationCursor = cursor
    }
#endif

    override init() {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        super.init()

        manager.delegate = self
        manager.activityType = .fitness
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false

#if DEBUG
        if ProcessInfo.processInfo.environment["NIGHT_SIGNAL_SIMULATION"] == "1" {
            setSimulationEnabled(true)
        }
#endif
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    var isCurrentLocationUsable: Bool {
        guard let currentLocation else { return false }
        if isSimulationEnabled { return true }
        return currentLocation.horizontalAccuracy >= 0
            && currentLocation.horizontalAccuracy <= GameConfiguration.standard.maximumLocationAccuracy
            && abs(currentLocation.timestamp.timeIntervalSinceNow) <= GameConfiguration.standard.maximumFixAge
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestTemporaryPrecision() {
        guard accuracyAuthorization == .reducedAccuracy else { return }
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "PreciseRunLocation")
    }

    func setSimulationEnabled(_ enabled: Bool) {
#if DEBUG
        guard !wantsTracking else { return }
        guard isSimulationEnabled != enabled else { return }
        isSimulationEnabled = enabled
        lastErrorMessage = nil
        simulationCursor = nil

        if enabled {
            manager.stopUpdatingLocation()
            let origin = currentLocation?.coordinate ?? simulationCoordinate ?? fallbackCoordinate
            publishSimulatedLocation(at: origin)
            isTracking = wantsTracking
        } else {
            // Never reuse an indoor simulated coordinate as a real GPS fix.
            currentLocation = nil
            isTracking = false
        }
#else
        isSimulationEnabled = false
#endif
    }

    func startTracking() {
        wantsTracking = true
        lastErrorMessage = nil

        if isSimulationEnabled {
            if currentLocation == nil {
                publishSimulatedLocation(at: simulationCoordinate ?? fallbackCoordinate)
            }
            isTracking = true
            return
        }

        guard isAuthorized else {
            isTracking = false
            return
        }
        beginHardwareTracking()
    }

    func setGameplayTrackingProfile(_ isGameplayActive: Bool) {
        usesGameplayProfile = isGameplayActive
        manager.pausesLocationUpdatesAutomatically = false
        if isGameplayActive {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            // Stopping is gameplay input too: keep receiving stationary fixes.
            // Tracking still stops when the app backgrounds or the run ends.
            manager.distanceFilter = kCLDistanceFilterNone
        } else {
            // During warm-up, receive stationary fixes as well so an
            // old-but-accurate coordinate does not block the session from starting.
            manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
            manager.distanceFilter = kCLDistanceFilterNone
        }
    }

    func refreshStationaryFixIfNeeded() {
        guard isTracking, !isSimulationEnabled, usesGameplayProfile,
              let currentLocation,
              Date().timeIntervalSince(currentLocation.timestamp) > 6 else { return }
        // Reassert continuous foreground sampling if the system delays a fix.
        manager.distanceFilter = kCLDistanceFilterNone
    }

    func stopTracking() {
        wantsTracking = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        isTracking = false
        currentLocation = nil
#if DEBUG
        simulationCursor = nil
#endif
    }

    func advanceSimulation(by seconds: TimeInterval) {
#if DEBUG
        guard isSimulationEnabled, isTracking, seconds > 0 else { return }
        if var cursor = simulationCursor {
            cursor.advance(meters: max(0, simulatedSpeed) * seconds)
            simulationCursor = cursor
            publishSimulatedLocation(at: cursor.coordinate)
            return
        }
        let origin = currentLocation?.coordinate ?? fallbackCoordinate
        let distance = max(0, simulatedSpeed) * seconds
        let destination = GeoMath.coordinate(
            from: origin,
            distance: distance,
            bearingDegrees: simulatedHeading
        )
        publishSimulatedLocation(at: destination)
#endif
    }

    func rotateSimulation(by degrees: Double) {
#if DEBUG
        simulationCursor = nil
        simulatedHeading = (simulatedHeading + degrees + 360).truncatingRemainder(dividingBy: 360)
#endif
    }

    private func beginHardwareTracking() {
        manager.allowsBackgroundLocationUpdates = false
        manager.showsBackgroundLocationIndicator = false
        manager.startUpdatingLocation()
        isTracking = true
    }

    private func publishSimulatedLocation(at coordinate: CLLocationCoordinate2D) {
        simulationCoordinate = coordinate
        currentLocation = CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: 2,
            verticalAccuracy: 2,
            course: simulatedHeading,
            speed: simulatedSpeed,
            timestamp: Date()
        )
    }
}

extension LocationService: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization

        if wantsTracking, isAuthorized, !isSimulationEnabled {
            beginHardwareTracking()
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            isTracking = false
            lastErrorMessage = "위치 권한이 없어 실제 GPS 모드를 시작할 수 없습니다."
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard !isSimulationEnabled else { return }
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp })
            where location.horizontalAccuracy >= 0 {
            currentLocation = location
        }
        accuracyAuthorization = manager.accuracyAuthorization
        lastErrorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        lastErrorMessage = error.localizedDescription
    }
}
