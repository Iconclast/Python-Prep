//
//  Managers.swift
//  Panopticore
//
//  GPS opcional (GEOLOG, apagado por defecto) y actitud del dispositivo
//  (rumbo/inclinación) para la telemetría. Nada sale del iPhone.
//

import CoreLocation
import CoreMotion
import Foundation

/// GPS estrictamente bajo demanda: solo se activa con el botón GEOLOG
/// y se libera al desactivarlo.
final class GeologManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var active = false
    @Published var fix: CLLocation?
    @Published var denied = false

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func toggle() {
        if active {
            manager.stopUpdatingLocation()
            active = false
            fix = nil
        } else {
            denied = false
            manager.requestWhenInUseAuthorization()
            manager.startUpdatingLocation()
            active = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        fix = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if active { denied = true }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            denied = true
        }
    }
}

/// Rumbo, cabeceo y alabeo desde CoreMotion para el bloque de telemetría.
final class TiltManager: ObservableObject {
    @Published var heading: Double?
    @Published var pitch: Double?
    @Published var roll: Double?

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.25
        motion.startDeviceMotionUpdates(using: .xMagneticNorthZVertical,
                                        to: .main) { [weak self] data, _ in
            guard let self, let d = data else { return }
            self.heading = d.heading >= 0 ? d.heading : nil
            self.pitch = d.attitude.pitch * 180 / .pi
            self.roll = d.attitude.roll * 180 / .pi
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}
