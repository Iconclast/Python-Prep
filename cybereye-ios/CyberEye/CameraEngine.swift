//
//  CameraEngine.swift
//  CyberEye
//
//  V3:
//  · Zoom continuo + cambio de lente (ultra gran angular / gran angular /
//    teleobjetivo) usando la cámara virtual del iPhone.
//  · Reconocimiento continuo en el dispositivo: personas con
//    VNDetectHumanRectanglesRequest y objetos (carros, animales, etc.)
//    clasificando recortes con VNClassifyImageRequest.
//  · El objetivo fijado se sigue con VNTrackObjectRequest.
//  Todo 100% en el dispositivo; el video nunca sale del iPhone.
//

import AVFoundation
import CoreImage
import CoreML
import SwiftUI
import UIKit
import Vision

// MARK: - Modelos

struct TrackBox: Identifiable {
    let id: Int
    var pos: CGPoint        // píxeles del buffer (portrait)
    var size: CGSize
    var area: Int
    var age: Int
    var label: String?
    var labelConf: Double
}

struct LockInfo {
    var pos: CGPoint
    var size: CGSize
    var conf: Double
    var label: String?
}

struct TrackEvent: Identifiable {
    let id = UUID()
    let time: String
    let text: String
    let highlight: Bool
}

struct HUDState {
    var tracks: [TrackBox] = []
    var speckles: [CGPoint] = []
    var lock: LockInfo? = nil
    var status: String = "SCANNING"
    var fps: Int = 0
    var frames: Int = 0
    var motionSamples: Int = 0
    var uniqueTracks: Int = 0
    var bufferSize: CGSize = CGSize(width: 720, height: 1280)
}

private final class Track {
    let id: Int
    var x: CGFloat, y: CGFloat
    var vx: CGFloat = 0, vy: CGFloat = 0
    var w: CGFloat, h: CGFloat
    var area: Int
    var age = 1
    var miss = 0
    var matched = true
    var label: String?
    var labelConf: Double = 0
    var labelAt: CFTimeInterval = 0

    init(id: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int) {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h; self.area = area
    }
}

// MARK: - Motor

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    @Published var hud = HUDState()
    @Published var events: [TrackEvent] = []
    @Published var cameraDenied = false
    @Published var running = false
    @Published var magImages: [String: UIImage] = [:]

    // Zoom / lentes
    @Published var displayZoom: CGFloat = 1
    @Published var lensOptions: [CGFloat] = [1]
    @Published var maxDisplayZoom: CGFloat = 8

    // Ajustes
    @Published var autolock = true
    @Published var showSpeckle = false
    @Published var showUnlabeled = false
    @Published var extraWindows = 1
    @Published var ufoMode = false
    @Published var sensitivity: Double = 26
    @Published var minArea: Double = 10
    @Published var maxPoints: Double = 10

    private let procQueue = DispatchQueue(label: "cybereye.proc")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private var device: AVCaptureDevice?
    private var wideFactor: CGFloat = 1     // factor crudo que equivale a "1x"

    // Estado interno (solo en procQueue)
    private var bg: [Float] = []
    private var heat: [Float] = []
    private var procW = 0, procH = 0
    private var tracks: [Track] = []
    private var nextId = 1
    private var frameCount = 0
    private var motionTotal = 0
    private var frameToggle = false
    private var visionTick = 0
    private var fpsCounter = 0
    private var fpsStamp = CACurrentMediaTime()
    private var fpsValue = 0
    private var statusText = "SCANNING"
    private var statusUntil: CFTimeInterval = 0
    private var snapBusy = false
    private var bufW: CGFloat = 720, bufH: CGFloat = 1280

    // Rastreo del objetivo con Vision
    private var seqHandler = VNSequenceRequestHandler()
    private var lockObservation: VNDetectedObjectObservation?
    private var lockLabel: String?
    private var lockConf: Double = 0
    private var lockMiss = 0
    private var lockFrames = 0

    // Detector YOLO empaquetado en la app (sin red; corre en el Neural Engine)
    private var yolo: VNCoreMLModel?
    @Published var yoloActive = false

    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var magTimer: Timer?

    // Etiquetas de contexto que no aportan (se ignoran al clasificar)
    private let labelBlocklist: Set<String> = [
        "outdoor", "indoor", "structure", "sky", "cloud", "plant", "tree", "grass",
        "road", "street", "building", "wall", "floor", "ground", "daytime", "night",
        "landscape", "field", "urban", "city", "light", "dark", "blur", "texture",
        "pattern", "material", "surface", "document", "art", "graphic", "screen",
        "land", "water_body", "snow", "sand", "rock", "fog", "sun", "machine",
    ]

    // MARK: Ciclo de vida

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted {
                DispatchQueue.main.async { self.cameraDenied = true }
                return
            }
            self.procQueue.async {
                self.loadYOLO()
                self.configureSession()
                self.session.startRunning()
                self.applyZoom(display: 1, ramp: false)
                DispatchQueue.main.async {
                    self.running = true
                    self.magTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
                        self?.refreshMagImages()
                    }
                }
                self.log("SENSOR ONLINE", highlight: true)
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.inputs.forEach { session.removeInput($0) }

        // cámara virtual: permite pasar de ultra gran angular a tele con el zoom
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        var chosen: AVCaptureDevice?
        for type in preferred {
            if let d = AVCaptureDevice.default(type, for: .video, position: .back) {
                chosen = d; break
            }
        }
        if let dev = chosen, let input = try? AVCaptureDeviceInput(device: dev),
           session.canAddInput(input) {
            session.addInput(input)
            device = dev
            let switchovers = dev.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
            let hasUltraWide = dev.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
            var options: [CGFloat] = []
            if hasUltraWide, let first = switchovers.first {
                wideFactor = first
                options = [0.5, 1]
                if switchovers.count > 1 {
                    options.append((switchovers[1] / first * 10).rounded() / 10)  // tele real
                }
            } else {
                wideFactor = 1
                options = [1, 2]
            }
            let maxZ = min(10, dev.activeFormat.videoMaxZoomFactor / wideFactor)
            DispatchQueue.main.async {
                self.lensOptions = options
                self.maxDisplayZoom = maxZ
            }
        }

        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: procQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        session.commitConfiguration()
    }

    // MARK: Zoom

    /// display: zoom "de usuario" (0.5x, 1x, 2x…). ramp: transición suave.
    func setZoom(display: CGFloat, ramp: Bool) {
        procQueue.async { self.applyZoom(display: display, ramp: ramp) }
    }

    /// Solo en procQueue.
    private func applyZoom(display: CGFloat, ramp: Bool) {
        guard let dev = device else { return }
        let clampedDisplay = max(0.5, min(maxDisplayZoom, display))
        let factor = max(1, min(dev.activeFormat.videoMaxZoomFactor, clampedDisplay * wideFactor))
        do {
            try dev.lockForConfiguration()
            if ramp {
                dev.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                dev.videoZoomFactor = factor
            }
            dev.unlockForConfiguration()
            let shown = factor / wideFactor
            DispatchQueue.main.async { self.displayZoom = shown }
        } catch {}
    }

    // MARK: Fijar / soltar objetivo

    func lockAt(bufferPoint p: CGPoint) {
        procQueue.async {
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in self.tracks {
                let dd = (t.x - p.x) * (t.x - p.x) + (t.y - p.y) * (t.y - p.y)
                if dd < bd { bd = dd; best = t }
            }
            if let t = best, bd < 180 * 180 {
                self.seedLock(x: t.x, y: t.y, w: t.w, h: t.h, label: t.label, source: "TAP LOCK")
            } else {
                self.seedLock(x: p.x, y: p.y, w: 150, h: 150, label: nil, source: "TAP LOCK")
            }
        }
    }

    func unlock() {
        procQueue.async {
            self.lockObservation = nil
            self.lockLabel = nil
            self.lockConf = 0
            self.setStatus("TARGET RELEASED")
            self.log("OPERATOR UNLOCK")
        }
    }

    /// Solo en procQueue.
    private func seedLock(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, label: String?, source: String) {
        let bw = max(bufW, 1), bh = max(bufH, 1)
        let nw = min(0.4, max(0.07, w * 1.4 / bw))
        let nh = min(0.4, max(0.07, h * 1.4 / bh))
        var rect = CGRect(x: x / bw - nw / 2, y: (1 - y / bh) - nh / 2, width: nw, height: nh)
        rect.origin.x = max(0, min(1 - nw, rect.origin.x))
        rect.origin.y = max(0, min(1 - nh, rect.origin.y))
        lockObservation = VNDetectedObjectObservation(boundingBox: rect)
        seqHandler = VNSequenceRequestHandler()
        lockLabel = label
        lockMiss = 0
        lockFrames = 0
        lockConf = 1
        setStatus("\(source)\(label.map { " · \($0)" } ?? "") X\(Int(x)) Y\(Int(y))")
        log("\(source)\(label.map { " · \($0)" } ?? "") X\(Int(x)) Y\(Int(y))", highlight: true)
    }

    /// Etiquetado neuronal del objetivo bajo demanda.
    func snapClassify() {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer, !snapBusy else { return }
        snapBusy = true
        setStatus("NEURAL SNAP…")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.snapBusy = false }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let top = request.results?.first(where: {
                      $0.confidence > 0.3 && !self.labelBlocklist.contains($0.identifier)
                  }) else {
                self.procQueue.async { self.setStatus("SNAP: UNKNOWN") }
                return
            }
            let label = top.identifier.uppercased()
            let conf = Double(top.confidence)
            self.procQueue.async {
                self.lockLabel = label
                self.setStatus("SNAP: \(label) \(String(format: "%.2f", conf))")
                self.log("SNAP TAG: \(label) \(String(format: "%.2f", conf))", highlight: true)
            }
        }
    }

    // MARK: Recortes MAG

    private func refreshMagImages() {
        var result = magImages
        let state = hud
        if let lock = state.lock {
            if let img = magCrop(center: lock.pos, boxSize: lock.size) { result["lock"] = img }
        }
        let tops = state.tracks
            .filter { $0.age >= 10 }
            .sorted { $0.area > $1.area }
            .prefix(extraWindows)
        for (i, t) in tops.enumerated() {
            if let img = magCrop(center: t.pos, boxSize: t.size) { result["t\(i)"] = img }
        }
        magImages = result
    }

    private func magCrop(center: CGPoint, boxSize: CGSize) -> UIImage? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        let bw = CGFloat(CVPixelBufferGetWidth(buffer))
        let bh = CGFloat(CVPixelBufferGetHeight(buffer))
        let aspect: CGFloat = 1.5
        var cw = max(160, max(boxSize.width, boxSize.height) * 2.2)
        var ch = cw / aspect
        cw = min(cw, bw); ch = min(ch, bh)
        var ox = center.x - cw / 2, oy = center.y - ch / 2
        ox = max(0, min(bw - cw, ox))
        oy = max(0, min(bh - ch, oy))
        let ciRect = CGRect(x: ox, y: bh - oy - ch, width: cw, height: ch)
        let ci = CIImage(cvPixelBuffer: buffer).cropped(to: ciRect)
        guard let cg = ciContext.createCGImage(ci, from: ciRect) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Captura

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = pb
        bufferLock.unlock()

        bufW = CGFloat(CVPixelBufferGetWidth(pb))
        bufH = CGFloat(CVPixelBufferGetHeight(pb))
        frameCount += 1
        fpsCounter += 1
        let now = CACurrentMediaTime()
        if now - fpsStamp > 1 {
            fpsValue = fpsCounter; fpsCounter = 0; fpsStamp = now
        }

        trackLockWithVision(pb)

        frameToggle.toggle()
        if frameToggle {
            visionTick += 1
            let (boxes, specks) = detectMotion(in: pb)
            updateTracks(with: boxes)
            if yolo != nil {
                if visionTick % 3 == 0 { runYOLO(pb) }         // ~5 veces/s
            } else {
                if visionTick % 4 == 0 { detectHumans(pb) }    // respaldo
                if visionTick % 8 == 0 { classifyTracks(pb) }
            }
            publishHUD(speckles: specks)
        }
    }

    // MARK: YOLO empaquetado (detección de 80 clases, en el dispositivo)

    /// Solo en procQueue. El modelo viaja dentro de la app: cero descargas.
    private func loadYOLO() {
        guard let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc"),
              let ml = try? MLModel(contentsOf: url),
              let vn = try? VNCoreMLModel(for: ml) else {
            log("YOLO NO DISPONIBLE · MODO CLASIFICADOR")
            return
        }
        yolo = vn
        DispatchQueue.main.async { self.yoloActive = true }
        log("YOLO CORE ONLINE · 80 CLASSES · ON-DEVICE", highlight: true)
    }

    /// Solo en procQueue. Detecta y etiqueta objetos; alimenta los tracks.
    private func runYOLO(_ pb: CVPixelBuffer) {
        guard let yolo else { return }
        let request = VNCoreMLRequest(model: yolo)
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results as? [VNRecognizedObjectObservation] else { return }
        let now = CACurrentMediaTime()
        for o in results where o.confidence > 0.35 {
            guard let top = o.labels.first else { continue }
            let b = o.boundingBox
            let x = b.midX * bufW, y = (1 - b.midY) * bufH
            let w = b.width * bufW, h = b.height * bufH
            let label = top.identifier.uppercased()
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in tracks {
                let dd = (t.x - x) * (t.x - x) + (t.y - y) * (t.y - y)
                if dd < bd { bd = dd; best = t }
            }
            if let t = best, bd < 220 * 220 {
                t.x = t.x * 0.4 + x * 0.6
                t.y = t.y * 0.4 + y * 0.6
                t.w = w; t.h = h
                t.miss = 0
                t.age = max(t.age, 10)
                t.label = label
                t.labelConf = Double(top.confidence)
                t.labelAt = now
            } else if tracks.count < Int(maxPoints) {
                let t = Track(id: nextId, x: x, y: y, w: w, h: h, area: Int(w * h / 100))
                t.age = 10
                t.label = label
                t.labelConf = Double(top.confidence)
                t.labelAt = now
                tracks.append(t)
                nextId += 1
                log("\(label) DETECTED X\(Int(x)) Y\(Int(y))", highlight: true)
            }
        }
    }

    // MARK: Reconocimiento de personas (respaldo sin YOLO)

    private func detectHumans(_ pb: CVPixelBuffer) {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return }
        let now = CACurrentMediaTime()
        for o in results where o.confidence > 0.3 {
            let b = o.boundingBox
            let x = b.midX * bufW, y = (1 - b.midY) * bufH
            let w = b.width * bufW, h = b.height * bufH
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in tracks {
                let dd = (t.x - x) * (t.x - x) + (t.y - y) * (t.y - y)
                if dd < bd { bd = dd; best = t }
            }
            if let t = best, bd < 220 * 220 {
                // refresca el track con la detección (aunque no se mueva)
                t.x = t.x * 0.4 + x * 0.6
                t.y = t.y * 0.4 + y * 0.6
                t.w = w; t.h = h
                t.miss = 0
                t.age = max(t.age, 10)
                t.label = "PERSON"
                t.labelConf = Double(o.confidence)
                t.labelAt = now
            } else if tracks.count < Int(maxPoints) {
                let t = Track(id: nextId, x: x, y: y, w: w, h: h, area: Int(w * h / 100))
                t.age = 10
                t.label = "PERSON"
                t.labelConf = Double(o.confidence)
                t.labelAt = now
                tracks.append(t)
                nextId += 1
                log("PERSON DETECTED X\(Int(x)) Y\(Int(y))", highlight: true)
            }
        }
    }

    // MARK: Clasificación de objetos (carros, animales, etc.)

    private func classifyTracks(_ pb: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let candidates = tracks
            .filter { $0.age >= 10 && $0.label != "PERSON" && (now - $0.labelAt) > 4 }
            .sorted { $0.area > $1.area }
            .prefix(2)
        guard !candidates.isEmpty else { return }
        let full = CIImage(cvPixelBuffer: pb)
        for t in candidates {
            var cw = max(180, max(t.w, t.h) * 1.6)
            var ch = cw
            cw = min(cw, bufW); ch = min(ch, bufH)
            var ox = t.x - cw / 2, oy = t.y - ch / 2
            ox = max(0, min(bufW - cw, ox))
            oy = max(0, min(bufH - ch, oy))
            let ciRect = CGRect(x: ox, y: bufH - oy - ch, width: cw, height: ch)
            let crop = full.cropped(to: ciRect)
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(ciImage: crop, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let top = request.results?.first(where: {
                      $0.confidence > 0.3 && !labelBlocklist.contains($0.identifier)
                  }) else {
                t.labelAt = now      // no insistir de inmediato
                continue
            }
            let wasNil = t.label == nil
            t.label = top.identifier.uppercased()
            t.labelConf = Double(top.confidence)
            t.labelAt = now
            if wasNil {
                log("TAG \(t.label ?? "") \(String(format: "%.2f", t.labelConf)) · TRK-\(Self.pad(t.id))")
            }
        }
    }

    // MARK: Rastreo del objetivo (Vision)

    private func trackLockWithVision(_ pb: CVPixelBuffer) {
        guard let obs = lockObservation else { return }
        lockFrames += 1
        if lockFrames % 240 == 0 {
            seqHandler = VNSequenceRequestHandler()
        }
        let request = VNTrackObjectRequest(detectedObjectObservation: obs)
        request.trackingLevel = .accurate
        do {
            try seqHandler.perform([request], on: pb)
        } catch {
            lockMiss += 1
        }
        if let r = request.results?.first as? VNDetectedObjectObservation,
           r.confidence > 0.2 {
            lockObservation = r
            lockConf = Double(r.confidence)
            lockMiss = 0
        } else {
            lockMiss += 1
        }
        if lockMiss > 25 {
            lockObservation = nil
            lockConf = 0
            setStatus("TARGET LOST")
            log("TARGET LOST · TRACKER DROPPED")
        }
    }

    private func currentLockInfo() -> LockInfo? {
        guard let obs = lockObservation else { return nil }
        let b = obs.boundingBox
        return LockInfo(
            pos: CGPoint(x: b.midX * bufW, y: (1 - b.midY) * bufH),
            size: CGSize(width: b.width * bufW, height: b.height * bufH),
            conf: lockConf,
            label: lockLabel)
    }

    // MARK: Detección de movimiento (fondo adaptativo + suavizado)

    private func detectMotion(in pb: CVPixelBuffer)
        -> ([(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int)], [CGPoint]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ([], []) }
        let bw = CVPixelBufferGetWidth(pb)
        let bh = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        let pw = 96
        let ph = max(60, pw * bh / bw)
        let n = pw * ph
        let cell = 3
        let cw = (pw + cell - 1) / cell
        let chh = (ph + cell - 1) / cell
        if pw != procW || ph != procH {
            procW = pw; procH = ph
            bg = []; heat = [Float](repeating: 0, count: cw * chh)
        }

        var gray = [Float](repeating: 0, count: n)
        for y in 0..<ph {
            let sy = y * bh / ph
            let row = sy * stride
            for x in 0..<pw {
                let sx = x * bw / pw
                let o = row + sx * 4
                gray[y * pw + x] = Float(Int(ptr[o]) * 3 + Int(ptr[o + 1]) * 6 + Int(ptr[o + 2])) / 10
            }
        }
        if bg.count != n {
            bg = gray
            return ([], [])
        }

        let thr = Float(ufoMode ? max(6, sensitivity * 0.55) : sensitivity)
        var cells = [Int](repeating: 0, count: cw * chh)
        var total = 0
        for i in 0..<n {
            let d = abs(gray[i] - bg[i])
            bg[i] += (gray[i] - bg[i]) * 0.08
            if d > thr {
                cells[((i / pw) / cell) * cw + ((i % pw) / cell)] += 1
                total += 1
            }
        }
        motionTotal += total

        let minCell = ufoMode ? 1 : 2
        var active = [Bool](repeating: false, count: cw * chh)
        for i in 0..<(cw * chh) {
            heat[i] = heat[i] * 0.55 + (cells[i] >= minCell ? 1 : 0)
            active[i] = heat[i] > 0.75
        }

        var specks: [CGPoint] = []
        let sxScale = CGFloat(bw) / CGFloat(pw) * CGFloat(cell)
        let syScale = CGFloat(bh) / CGFloat(ph) * CGFloat(cell)
        outer: for cy in 0..<chh {
            for cx in 0..<cw where active[cy * cw + cx] {
                specks.append(CGPoint(x: (CGFloat(cx) + 0.5) * sxScale,
                                      y: (CGFloat(cy) + 0.5) * syScale))
                if specks.count >= 300 { break outer }
            }
        }

        var seen = [Bool](repeating: false, count: cw * chh)
        var boxes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int)] = []
        var stack: [Int] = []
        for cy in 0..<chh {
            for cx in 0..<cw {
                let idx = cy * cw + cx
                if !active[idx] || seen[idx] { continue }
                var minx = cx, maxx = cx, miny = cy, maxy = cy, mass = 0
                stack.removeAll(keepingCapacity: true)
                stack.append(idx); seen[idx] = true
                while let c = stack.popLast() {
                    let x = c % cw, y = c / cw
                    mass += cells[c]
                    minx = min(minx, x); maxx = max(maxx, x)
                    miny = min(miny, y); maxy = max(maxy, y)
                    for dy in -1...1 {
                        for dx in -1...1 {
                            let nx = x + dx, ny = y + dy
                            if nx < 0 || ny < 0 || nx >= cw || ny >= chh { continue }
                            let ni = ny * cw + nx
                            if active[ni] && !seen[ni] { seen[ni] = true; stack.append(ni) }
                        }
                    }
                }
                if mass < Int(minArea) { continue }
                let bx = CGFloat(minx) * sxScale
                let by = CGFloat(miny) * syScale
                let bwid = CGFloat(maxx - minx + 1) * sxScale
                let bhei = CGFloat(maxy - miny + 1) * syScale
                boxes.append((x: bx + bwid / 2, y: by + bhei / 2, w: bwid, h: bhei, area: mass))
            }
        }
        boxes.sort { $0.area > $1.area }
        if boxes.count > Int(maxPoints) + 4 { boxes.removeLast(boxes.count - Int(maxPoints) - 4) }
        return (boxes, specks)
    }

    // MARK: Asociación de tracks

    private func updateTracks(with boxes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int)]) {
        for t in tracks { t.x += t.vx; t.y += t.vy; t.matched = false }

        for b in boxes {
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in tracks where !t.matched {
                let dd = (t.x - b.x) * (t.x - b.x) + (t.y - b.y) * (t.y - b.y)
                if dd < bd { bd = dd; best = t }
            }
            if let t = best, bd < 160 * 160 {
                let a: CGFloat = 0.4, g: CGFloat = 0.1
                let rx = b.x - t.x, ry = b.y - t.y
                t.x += a * rx; t.y += a * ry
                t.vx = (t.vx + g * rx) * 0.9
                t.vy = (t.vy + g * ry) * 0.9
                t.area = b.area
                t.w = t.w * 0.7 + b.w * 0.3
                t.h = t.h * 0.7 + b.h * 0.3
                t.age += 1; t.miss = 0; t.matched = true
            } else if tracks.count < Int(maxPoints) {
                tracks.append(Track(id: nextId, x: b.x, y: b.y, w: b.w, h: b.h, area: b.area))
                nextId += 1
            }
        }

        var idx = tracks.count - 1
        while idx >= 0 {
            let t = tracks[idx]
            if !t.matched { t.miss += 1 }
            // las personas detectadas viven más (el detector las refresca)
            let limit = t.label == "PERSON" ? 60 : 25
            if t.miss > limit || t.x < -100 || t.x > bufW + 100 || t.y < -100 || t.y > bufH + 100 {
                if t.age > 40 { log("TRK-\(Self.pad(t.id)) end · life \(t.age)f") }
                tracks.remove(at: idx)
            }
            idx -= 1
        }

        if autolock && lockObservation == nil {
            var best: Track?; var score = -1
            for t in tracks where t.age >= 12 {
                var s = t.area * min(t.age, 60)
                if t.label != nil { s *= 3 }    // prioriza objetivos identificados
                if s > score { score = s; best = t }
            }
            if let b = best {
                seedLock(x: b.x, y: b.y, w: b.w, h: b.h, label: b.label, source: "AUTOLOCK")
            }
        }
    }

    private func publishHUD(speckles: [CGPoint]) {
        var state = HUDState()
        state.tracks = tracks
            .filter { $0.age >= 5 }
            .map {
                TrackBox(id: $0.id,
                         pos: CGPoint(x: $0.x, y: $0.y),
                         size: CGSize(width: max(56, $0.w), height: max(56, $0.h)),
                         area: $0.area, age: $0.age,
                         label: $0.label, labelConf: $0.labelConf)
            }
        state.speckles = showSpeckle ? speckles : []
        state.lock = currentLockInfo()
        let now = CACurrentMediaTime()
        if now < statusUntil {
            state.status = statusText
        } else if let lock = state.lock {
            state.status = "LOCK\(lock.label.map { " \($0)" } ?? "") C\(String(format: "%.2f", lock.conf))"
        } else {
            state.status = autolock ? "SCANNING" : "TAP TO LOCK"
        }
        state.fps = fpsValue
        state.frames = frameCount
        state.motionSamples = motionTotal
        state.uniqueTracks = nextId - 1
        state.bufferSize = CGSize(width: bufW, height: bufH)
        DispatchQueue.main.async { self.hud = state }
    }

    // MARK: Utilidades

    private func setStatus(_ msg: String) {
        statusText = msg
        statusUntil = CACurrentMediaTime() + 2.5
    }

    private func log(_ text: String, highlight: Bool = false) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let ev = TrackEvent(time: f.string(from: Date()), text: text, highlight: highlight)
        DispatchQueue.main.async {
            self.events.append(ev)
            if self.events.count > 200 { self.events.removeFirst() }
        }
    }

    static func pad(_ n: Int) -> String { String(format: "%03d", n) }
}
