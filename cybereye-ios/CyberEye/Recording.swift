//
//  Recording.swift
//  CyberEye
//
//  Grabación de pantalla con ReplayKit, disparada con los botones físicos
//  del iPhone (botón de Control de Cámara del iPhone 16 Pro o botones de
//  volumen) — sin botones en la interfaz. El video (cámara + HUD) se
//  guarda en Fotos. Nada sale del dispositivo.
//

import Photos
import ReplayKit
import UIKit

final class ScreenRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var note: String? = nil

    private let recorder = RPScreenRecorder.shared()

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    private func start() {
        guard recorder.isAvailable, !recorder.isRecording else { return }
        recorder.isMicrophoneEnabled = false   // sin audio: solo lo visual
        recorder.startRecording { [weak self] error in
            DispatchQueue.main.async {
                self?.isRecording = (error == nil)
                self?.note = error == nil ? nil : "REC ERROR"
            }
        }
    }

    private func stop() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cybereye-\(Int(Date().timeIntervalSince1970)).mp4")
        recorder.stopRecording(withOutput: url) { [weak self] error in
            DispatchQueue.main.async { self?.isRecording = false }
            guard error == nil else {
                DispatchQueue.main.async { self?.note = "REC ERROR" }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                guard status == .authorized || status == .limited else {
                    DispatchQueue.main.async { self?.note = "SIN PERMISO DE FOTOS" }
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }) { ok, _ in
                    try? FileManager.default.removeItem(at: url)
                    DispatchQueue.main.async {
                        self?.note = ok ? "GUARDADO EN FOTOS" : "NO SE PUDO GUARDAR"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            self?.note = nil
                        }
                    }
                }
            }
        }
    }
}
