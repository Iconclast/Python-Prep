//
//  CameraEngine.swift
//  CyberEye
//
//  Captura de cámara + detección de micro-movimiento + rastreo tipo Kalman
//  (filtro alfa-beta) + autolock + memoria de objetivo + etiquetado neuronal
//  con Vision (100% en el dispositivo; el video nunca sale del iPhone).
//

import AVFoundation
import CoreImage
import SwiftUI
import UIKit
import Vision

// MARK: - Modelos

struct TrackBox: Identifiable {
    let id: Int
    var pos: CGPoint        // píxeles del buffer (portrait, p.ej. 720x1280)
    var size: CGSize
    var velocity: CGVector
    var area: Int
    var age: Int
    var label: String?
    var conf: Double
    var trail: [CGPoint]
}

struct MemoryGhost {
    var pos: CGPoint
    var conf: Double
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
    var lockId: Int? = nil
    var memory: MemoryGhost? = nil
    var status: String = "AUTOLOCK: SCANNING FIELD"
    var statusIsAlert: Bool = false
    var fps: Int = 0
    var frames: Int = 0
    var motionSamples: Int = 0
    var uniqueTracks: Int = 0
    var tag: String = "UNSCANNED"
    var tagConf: Double = 0
    var bufferSize: CGSize = CGSize(width: 720, height: 1280)
}

// Tracker interno mutable (solo se toca en la cola de proceso)
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
    var conf: Double = 0
    var trail: [CGPoint]

    init(id: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int) {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h; self.area = area
        self.trail = [CGPoint(x: x, y: y)]
    }
}

// MARK: - Motor

final class CameraEngine: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    @Published var hud = HUDState()
    @Published var events: [TrackEvent] = []
    @Published var cameraDenied = false
    @Published var running = false
    @Published var magImages: [Int: UIImage] = [:]

    // Parámetros ajustables (panel ADV)
    @Published var autolock = true
    @Published var showSpeckle = true
    @Published var showMags = true
    @Published var ufoMode = false
    @Published var sensitivity: Double = 28      // umbral de diferencia de gris
    @Published var minArea: Double = 8           // masa mínima de movimiento
    @Published var maxPoints: Double = 14
    @Published var lockRadius: Double = 190      // px de buffer
    @Published var reticleRadius: Double = 160   // px de buffer

    private let procQueue = DispatchQueue(label: "cybereye.proc")
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    // Estado interno (solo en procQueue)
    private var prevGray: [UInt8]?
    private var procW = 0, procH = 0
    private var tracks: [Track] = []
    private var nextId = 1
    private var lockId: Int? = nil
    private var memory: (x: CGFloat, y: CGFloat, vx: CGFloat, vy: CGFloat,
                         since: CFTimeInterval, label: String?)? = nil
    private var frameCount = 0
    private var motionTotal = 0
    private var frameToggle = false
    private var fpsCounter = 0
    private var fpsStamp = CACurrentMediaTime()
    private var fpsValue = 0
    private var statusText = "AUTOLOCK: SCANNING FIELD"
    private var statusAlert = false
    private var statusUntil: CFTimeInterval = 0
    private var snapTag = "UNSCANNED"
    private var snapConf: Double = 0
    private var snapBusy = false
    private var bufW: CGFloat = 720, bufH: CGFloat = 1280

    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var magTimer: Timer?

    // MARK: Ciclo de vida

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            if !granted {
                DispatchQueue.main.async { self.cameraDenied = true }
                return
            }
            self.procQueue.async {
                self.configureSession()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.running = true
                    // refresco de las ventanas MAG-TRACK a 4 fps
                    self.magTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        self?.refreshMagImages()
                    }
                }
                self.log("SENSOR ONLINE · OPTICAL FEED ACQUIRED", highlight: true)
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.inputs.forEach { session.removeInput($0) }
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }
        if !session.outputs.contains(output) {
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: procQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90   // buffers en vertical
        }
        session.commitConfiguration()
    }

    // MARK: Acciones del operador

    func captureFromReticle() {
        procQueue.async {
            let cx = self.bufW / 2, cy = self.bufH / 2
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in self.tracks {
                let dd = (t.x - cx) * (t.x - cx) + (t.y - cy) * (t.y - cy)
                if dd < bd { bd = dd; best = t }
            }
            let r = CGFloat(self.reticleRadius)
            if let b = best, bd < r * r {
                self.lockId = b.id; self.memory = nil
                self.setStatus("LOCKED FROM RETICLE X\(Int(b.x)) Y\(Int(b.y)) A\(b.area)")
                self.log("TRK-\(Self.pad(b.id)) RETICLE LOCK X\(Int(b.x)) Y\(Int(b.y)) A\(b.area)", highlight: true)
            } else {
                self.setStatus("CAPTURE ARMED: NO MOTION IN RETICLE", alert: true)
            }
        }
    }

    func unlock() {
        procQueue.async {
            self.lockId = nil; self.memory = nil
            self.snapTag = "UNSCANNED"; self.snapConf = 0
            self.setStatus("TARGET LOST - RETICLE READY", alert: true)
            self.log("OPERATOR UNLOCK · TRACK RELEASED")
        }
    }

    /// Etiquetado neuronal de un disparo con Vision (modelo integrado en iOS).
    func snapClassify() {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer, !snapBusy else { return }
        snapBusy = true
        setStatus("NEURAL SNAP QUEUED")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { self.snapBusy = false }
            let request = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
            guard (try? handler.perform([request])) != nil,
                  let results = request.results?.filter({ $0.confidence > 0.35 }),
                  let top = results.first else {
                self.procQueue.async {
                    self.setStatus("NEURAL SNAP: UNKNOWN / IDLE", alert: true)
                    self.log("SNAP RETURNED 0 CLASSIFICATIONS")
                }
                return
            }
            let label = top.identifier.uppercased()
            let conf = Double(top.confidence)
            self.procQueue.async {
                self.snapTag = label; self.snapConf = conf
                if let id = self.lockId, let t = self.tracks.first(where: { $0.id == id }) {
                    t.label = label; t.conf = conf
                }
                self.setStatus("NEURAL SNAP TAGGED: \(label) \(String(format: "%.2f", conf))")
                self.log("SNAP TAG: \(label) \(String(format: "%.2f", conf))", highlight: true)
            }
        }
    }

    /// Regenera los recortes ampliados de las ventanas MAG-TRACK
    /// (objetivo fijado + los 3 tracks más grandes). Corre en main a 4 fps.
    private func refreshMagImages() {
        let state = hud
        var ids: [Int] = []
        if let lock = state.lockId { ids.append(lock) }
        ids.append(contentsOf: state.tracks
            .filter { $0.id != state.lockId && $0.age >= 8 }
            .sorted { $0.area > $1.area }
            .prefix(3)
            .map(\.id))
        var result: [Int: UIImage] = [:]
        for id in ids {
            guard let t = state.tracks.first(where: { $0.id == id }) else { continue }
            if let img = magCrop(center: t.pos, boxSize: t.size, aspect: 1.49) {
                result[id] = img
            }
        }
        magImages = result
    }

    /// Recorte ampliado alrededor de un punto (para las ventanas MAG-TRACK).
    func magCrop(center: CGPoint, boxSize: CGSize, aspect: CGFloat) -> UIImage? {
        bufferLock.lock()
        let buffer = latestBuffer
        bufferLock.unlock()
        guard let buffer else { return nil }
        let bw = CGFloat(CVPixelBufferGetWidth(buffer))
        let bh = CGFloat(CVPixelBufferGetHeight(buffer))
        var cw = max(140, max(boxSize.width, boxSize.height) * 2)
        var ch = cw / aspect
        cw = min(cw, bw); ch = min(ch, bh)
        var ox = center.x - cw / 2, oy = center.y - ch / 2
        ox = max(0, min(bw - cw, ox))
        oy = max(0, min(bh - ch, oy))
        // CIImage tiene origen abajo-izquierda; el buffer arriba-izquierda
        let ciRect = CGRect(x: ox, y: bh - oy - ch, width: cw, height: ch)
        let ci = CIImage(cvPixelBuffer: buffer).cropped(to: ciRect)
        guard let cg = ciContext.createCGImage(ci, from: ciRect) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: Captura y procesamiento

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        latestBuffer = pb
        bufferLock.unlock()

        frameCount += 1
        fpsCounter += 1
        let now = CACurrentMediaTime()
        if now - fpsStamp > 1 {
            fpsValue = fpsCounter; fpsCounter = 0; fpsStamp = now
        }
        frameToggle.toggle()
        if frameToggle {
            let boxes = detectMotion(in: pb)
            updateTracks(with: boxes.0, speckles: boxes.1, now: now)
        }
    }

    /// Diferencia de cuadros a baja resolución + componentes conexos.
    /// Devuelve (cajas, puntos de movimiento) en píxeles del buffer.
    private func detectMotion(in pb: CVPixelBuffer)
        -> ([(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int)], [CGPoint]) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return ([], []) }
        let bw = CVPixelBufferGetWidth(pb)
        let bh = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        bufW = CGFloat(bw); bufH = CGFloat(bh)

        let pw = 96
        let ph = max(60, pw * bh / bw)
        if pw != procW || ph != procH { procW = pw; procH = ph; prevGray = nil }

        var gray = [UInt8](repeating: 0, count: pw * ph)
        for y in 0..<ph {
            let sy = y * bh / ph
            let row = sy * stride
            for x in 0..<pw {
                let sx = x * bw / pw
                let o = row + sx * 4
                let b = Int(ptr[o]), g = Int(ptr[o + 1]), r = Int(ptr[o + 2])
                gray[y * pw + x] = UInt8((r * 3 + g * 6 + b) / 10)
            }
        }
        guard let prev = prevGray else { prevGray = gray; return ([], []) }
        prevGray = gray

        let thr = UInt8(max(4, ufoMode ? sensitivity * 0.55 : sensitivity))
        let cell = 3
        let cw = (pw + cell - 1) / cell
        let chh = (ph + cell - 1) / cell
        var cells = [Int](repeating: 0, count: cw * chh)
        var total = 0
        for y in 0..<ph {
            for x in 0..<pw {
                let i = y * pw + x
                let d = gray[i] > prev[i] ? gray[i] - prev[i] : prev[i] - gray[i]
                if d > thr {
                    cells[(y / cell) * cw + (x / cell)] += 1
                    total += 1
                }
            }
        }
        motionTotal += total

        let minCell = ufoMode ? 1 : 2
        var active = [Bool](repeating: false, count: cw * chh)
        for i in 0..<(cw * chh) { active[i] = cells[i] >= minCell }

        // puntos de movimiento (speckles)
        var specks: [CGPoint] = []
        let sxScale = CGFloat(bw) / CGFloat(pw) * CGFloat(cell)
        let syScale = CGFloat(bh) / CGFloat(ph) * CGFloat(cell)
        outer: for cy in 0..<chh {
            for cx in 0..<cw where active[cy * cw + cx] {
                specks.append(CGPoint(x: (CGFloat(cx) + 0.5) * sxScale,
                                      y: (CGFloat(cy) + 0.5) * syScale))
                if specks.count >= 400 { break outer }
            }
        }

        // componentes conexos sobre celdas activas
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

    /// Asociación por vecino más cercano + filtro alfa-beta + memoria + autolock.
    private func updateTracks(with boxes: [(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, area: Int)],
                              speckles: [CGPoint], now: CFTimeInterval) {
        for t in tracks { t.x += t.vx; t.y += t.vy; t.matched = false }

        for b in boxes {
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in tracks where !t.matched {
                let dd = (t.x - b.x) * (t.x - b.x) + (t.y - b.y) * (t.y - b.y)
                if dd < bd { bd = dd; best = t }
            }
            let radius: CGFloat = (best?.id == lockId) ? CGFloat(lockRadius) : 140
            if let t = best, bd < radius * radius {
                let a: CGFloat = 0.45, g: CGFloat = 0.12
                let rx = b.x - t.x, ry = b.y - t.y
                t.x += a * rx; t.y += a * ry
                t.vx = (t.vx + g * rx) * 0.92
                t.vy = (t.vy + g * ry) * 0.92
                t.area = b.area; t.w = b.w; t.h = b.h
                t.age += 1; t.miss = 0; t.matched = true
                t.trail.append(CGPoint(x: t.x, y: t.y))
                if t.trail.count > 18 { t.trail.removeFirst() }
            } else if tracks.count < Int(maxPoints) {
                tracks.append(Track(id: nextId, x: b.x, y: b.y, w: b.w, h: b.h, area: b.area))
                nextId += 1
            }
        }

        // caducidad y paso a memoria
        var idx = tracks.count - 1
        while idx >= 0 {
            let t = tracks[idx]
            if !t.matched { t.miss += 1 }
            let limit = t.id == lockId ? 45 : 14
            if t.miss > limit || t.x < -100 || t.x > bufW + 100 || t.y < -100 || t.y > bufH + 100 {
                if t.id == lockId {
                    memory = (t.x, t.y, t.vx, t.vy, now, t.label)
                    lockId = nil
                    setStatus("TARGET MEMORY / SEARCHING 0s", alert: true)
                    log("TRK-\(Self.pad(t.id)) SIGNAL LOST · MEMORY HOLD X\(Int(t.x)) Y\(Int(t.y))")
                }
                if t.age > 20 { log("TRK-\(Self.pad(t.id)) track end · life \(t.age)f · a\(t.area)") }
                tracks.remove(at: idx)
            }
            idx -= 1
        }

        // memoria: readquirir o expirar
        if var mem = memory {
            mem.x += mem.vx * 0.5; mem.y += mem.vy * 0.5
            memory = mem
            let ageS = now - mem.since
            var best: Track?; var bd = CGFloat.greatestFiniteMagnitude
            for t in tracks {
                let dd = (t.x - mem.x) * (t.x - mem.x) + (t.y - mem.y) * (t.y - mem.y)
                if dd < bd { bd = dd; best = t }
            }
            let r = CGFloat(lockRadius)
            if let b = best, bd < r * r {
                lockId = b.id
                b.label = mem.label ?? b.label
                memory = nil
                setStatus("ADV LOCK REACQ X\(Int(b.x)) Y\(Int(b.y))")
                log("TRK-\(Self.pad(b.id)) REACQUIRED FROM MEMORY", highlight: true)
            } else if ageS > 6 {
                memory = nil
                setStatus("TARGET LOST - RETICLE READY", alert: true)
                log("MEMORY EXPIRED · TARGET LOST")
            } else {
                setStatus("TARGET MEMORY / SEARCHING \(Int(ageS))s", alert: true)
            }
        }

        // autolock: engancha el track más estable
        if autolock && lockId == nil && memory == nil {
            var best: Track?; var score = -1
            for t in tracks where t.age >= 10 {
                let s = t.area * min(t.age, 60)
                if s > score { score = s; best = t }
            }
            if let b = best {
                lockId = b.id
                setStatus("AUTOLOCK ENGAGED TRK-\(Self.pad(b.id)) X\(Int(b.x)) Y\(Int(b.y))")
                log("TRK-\(Self.pad(b.id)) AUTOLOCK X\(Int(b.x)) Y\(Int(b.y)) A\(b.area)", highlight: true)
            }
        }

        publishHUD(speckles: speckles, now: now)
    }

    private func publishHUD(speckles: [CGPoint], now: CFTimeInterval) {
        var state = HUDState()
        state.tracks = tracks.map {
            TrackBox(id: $0.id,
                     pos: CGPoint(x: $0.x, y: $0.y),
                     size: CGSize(width: max(50, $0.w), height: max(50, $0.h)),
                     velocity: CGVector(dx: $0.vx, dy: $0.vy),
                     area: $0.area, age: $0.age,
                     label: $0.label, conf: $0.conf, trail: $0.trail)
        }
        state.speckles = showSpeckle ? speckles : []
        state.lockId = lockId
        if let m = memory {
            state.memory = MemoryGhost(pos: CGPoint(x: m.x, y: m.y),
                                       conf: max(0, 0.8 - (now - m.since) * 0.13))
        }
        if now < statusUntil {
            state.status = statusText; state.statusIsAlert = statusAlert
        } else if let id = lockId, let t = tracks.first(where: { $0.id == id }) {
            state.status = "ADV LOCK TRK-\(Self.pad(id)) X\(Int(t.x)) Y\(Int(t.y))"
        } else {
            state.status = autolock ? "AUTOLOCK: SCANNING FIELD" : "RETICLE READY"
        }
        state.fps = fpsValue
        state.frames = frameCount
        state.motionSamples = motionTotal
        state.uniqueTracks = nextId - 1
        state.tag = snapTag
        state.tagConf = snapConf
        state.bufferSize = CGSize(width: bufW, height: bufH)
        DispatchQueue.main.async { self.hud = state }
    }

    // MARK: Utilidades

    private func setStatus(_ msg: String, alert: Bool = false) {
        statusText = msg; statusAlert = alert
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
