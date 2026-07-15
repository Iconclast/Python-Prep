//
//  ContentView.swift
//  CyberEye
//
//  HUD estilo CYBEREYE: telemetría, cajas de rastreo, puntos de
//  movimiento, ventanas AUTO MAG-TRACK con líneas conectoras, radar,
//  reporte de tracks únicos y panel avanzado.
//

import AVFoundation
import SwiftUI

// MARK: - Colores del tema

extension Color {
    static let sigGreen = Color(red: 0, green: 1, blue: 110 / 255)
    static let sigAmber = Color(red: 1, green: 180 / 255, blue: 40 / 255)
    static let sigRed = Color(red: 1, green: 50 / 255, blue: 50 / 255)
    static let sigCyan = Color(red: 40 / 255, green: 220 / 255, blue: 1)
}

// MARK: - Vista previa de cámara

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Mapeo buffer → pantalla (aspect fill)

struct CoverMap {
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    init(buffer: CGSize, view: CGSize) {
        scale = max(view.width / max(buffer.width, 1), view.height / max(buffer.height, 1))
        ox = (view.width - buffer.width * scale) / 2
        oy = (view.height - buffer.height * scale) / 2
    }

    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ox + p.x * scale, y: oy + p.y * scale)
    }
}

// MARK: - Vista raíz

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var geolog = GeologManager()
    @StateObject private var tilt = TiltManager()

    @State private var booted = false
    @State private var showReport = false
    @State private var showAdv = false
    @State private var showRadar = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if booted {
                    CameraPreview(session: engine.session).ignoresSafeArea()
                    HUDCanvas(hud: engine.hud, viewSize: geo.size)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    overlayUI(size: geo.size)
                } else {
                    BootView(denied: engine.cameraDenied) {
                        engine.start()
                        tilt.start()
                        booted = true
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .sheet(isPresented: $showReport) {
            ReportView(engine: engine, geolog: geolog)
        }
        .sheet(isPresented: $showAdv) {
            AdvPanel(engine: engine)
        }
    }

    // MARK: superposición de UI

    @ViewBuilder
    private func overlayUI(size: CGSize) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                TelemetryBlock(engine: engine, geolog: geolog, tilt: tilt)
                Spacer()
                if engine.showMags {
                    MagWindow(engine: engine,
                              track: lockedTrack,
                              title: "LOCK-STABLE // RGB CROP [BIG]",
                              placeholder: engine.autolock ? "AUTOLOCK: SEARCHING" : "AIM + CAPTURE",
                              width: 158)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            if engine.showMags {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(sideTracks.prefix(2))) { t in
                            MagWindow(engine: engine, track: t,
                                      title: "AUTO MAG-TRACK // TRACK-\(CameraEngine.pad(t.id))",
                                      placeholder: nil, width: 118)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 10) {
                        ForEach(Array(sideTracks.dropFirst(2).prefix(1))) { t in
                            MagWindow(engine: engine, track: t,
                                      title: "AUTO MAG-TRACK // TRACK-\(CameraEngine.pad(t.id))",
                                      placeholder: nil, width: 118)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 12)
            }

            Spacer()

            HStack(alignment: .bottom) {
                if geolog.active { GeologBox(geolog: geolog) }
                Spacer()
                if showRadar { RadarView(hud: engine.hud) }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            HStack(spacing: 6) {
                BigButton(title: "MAKE\nREPORT") { showReport = true }
                BigButton(title: "TELEMETRY\nMINIMAP", active: showRadar) { showRadar.toggle() }
                BigButton(title: "GEOLOG\nPANEL", active: geolog.active) { geolog.toggle() }
                BigButton(title: "ADV", tint: .sigAmber) { showAdv = true }
                    .frame(width: 64)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    private var lockedTrack: TrackBox? {
        guard let id = engine.hud.lockId else { return nil }
        return engine.hud.tracks.first { $0.id == id }
    }

    private var sideTracks: [TrackBox] {
        engine.hud.tracks
            .filter { $0.id != engine.hud.lockId && $0.age >= 8 }
            .sorted { $0.area > $1.area }
    }
}

// MARK: - Pantalla de arranque

struct BootView: View {
    let denied: Bool
    let onStart: () -> Void

    private let lines = [
        "CYBEREYE // EXPERIMENTAL SENSOR SUITE",
        "native iOS build V1.0",
        "",
        "[ OK ] micro-motion detector ...... armed",
        "[ OK ] kalman track core .......... armed",
        "[ OK ] auto mag-track windows ..... armed",
        "[ OK ] autolock engine ............ armed",
        "[ OK ] neural snap-tagger ......... on-device",
        "",
        "SEGURIDAD: todo se procesa en este iPhone.",
        "El video nunca sale del dispositivo.",
        "Sin cuentas, sin rastreo, sin servidores.",
        "GPS apagado por defecto (botón GEOLOG).",
    ]

    @State private var visible = 0
    private let bootTimer = Timer.publish(every: 0.09, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(lines.prefix(visible).joined(separator: "\n"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.sigGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
            if visible >= lines.count {
                Button(action: onStart) {
                    Text("▸ INITIALIZE SENSOR")
                        .font(.system(size: 14, design: .monospaced))
                        .tracking(2)
                        .foregroundStyle(Color.sigGreen)
                        .padding(.vertical, 14)
                        .padding(.horizontal, 26)
                        .overlay(Rectangle().stroke(Color.sigGreen, lineWidth: 1))
                }
            }
            if denied {
                Text("SENSOR FAULT: permiso de cámara denegado.\nAjustes > CyberEye > Cámara > Permitir")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.sigRed)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(Color.black)
        .onReceive(bootTimer) { _ in
            if visible < lines.count { visible += 1 }
        }
    }
}

// MARK: - Lienzo del HUD

struct HUDCanvas: View {
    let hud: HUDState
    let viewSize: CGSize

    var body: some View {
        Canvas { ctx, size in
            let map = CoverMap(buffer: hud.bufferSize, view: size)
            let green = Color.sigGreen

            // puntos de movimiento
            for s in hud.speckles {
                let p = map.point(s)
                ctx.fill(Path(CGRect(x: p.x - 1, y: p.y - 1, width: 2.4, height: 2.4)),
                         with: .color(green.opacity(0.55)))
            }

            // retícula central
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let locked = hud.lockId != nil
            var ret = Path()
            ret.addArc(center: c, radius: 44, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            ctx.stroke(ret, with: .color(locked ? green : green.opacity(0.6)),
                       style: StrokeStyle(lineWidth: 1, dash: locked ? [] : [5, 5]))
            var cross = Path()
            cross.move(to: CGPoint(x: c.x - 62, y: c.y)); cross.addLine(to: CGPoint(x: c.x - 26, y: c.y))
            cross.move(to: CGPoint(x: c.x + 26, y: c.y)); cross.addLine(to: CGPoint(x: c.x + 62, y: c.y))
            cross.move(to: CGPoint(x: c.x, y: c.y - 62)); cross.addLine(to: CGPoint(x: c.x, y: c.y - 26))
            cross.move(to: CGPoint(x: c.x, y: c.y + 26)); cross.addLine(to: CGPoint(x: c.x, y: c.y + 62))
            ctx.stroke(cross, with: .color(green.opacity(0.7)), lineWidth: 1)

            // cajas de rastreo
            for t in hud.tracks {
                let p = map.point(t.pos)
                let w = max(30, t.size.width * map.scale)
                let h = max(30, t.size.height * map.scale)
                let isLock = t.id == hud.lockId
                let col: Color = isLock ? .sigCyan : (t.age < 4 ? green.opacity(0.4) : green.opacity(0.85))
                let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                ctx.stroke(cornerPath(rect), with: .color(col), lineWidth: isLock ? 2 : 1)

                if t.trail.count > 2 {
                    var trail = Path()
                    trail.move(to: map.point(t.trail[0]))
                    for q in t.trail.dropFirst() { trail.addLine(to: map.point(q)) }
                    ctx.stroke(trail, with: .color(Color.sigCyan.opacity(0.5)), lineWidth: 1)
                }

                let tag = t.label.map { "\($0) \(Int(t.conf * 100))%" } ?? "TRACK-\(CameraEngine.pad(t.id))"
                ctx.draw(Text(isLock ? "LOCK \(tag)" : tag)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(col),
                         at: CGPoint(x: rect.minX, y: rect.minY - 8), anchor: .leading)
            }

            // fantasma de memoria
            if let m = hud.memory {
                let p = map.point(m.pos)
                let rect = CGRect(x: p.x - 20, y: p.y - 20, width: 40, height: 40)
                ctx.stroke(Path(rect), with: .color(.sigAmber),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                ctx.draw(Text("MEMORY").font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.sigAmber),
                         at: CGPoint(x: rect.minX, y: rect.minY - 8), anchor: .leading)
            }

            // líneas conectoras amarillas hacia las ventanas MAG (esquinas)
            let anchors = [
                CGPoint(x: size.width - 90, y: 110),   // lock, arriba derecha
                CGPoint(x: 70, y: 230),                // track 1, arriba izquierda
                CGPoint(x: 70, y: 340),                // track 2
                CGPoint(x: size.width - 70, y: 340),   // track 3, derecha
            ]
            var lineIdx = 0
            if let id = hud.lockId, let t = hud.tracks.first(where: { $0.id == id }) {
                connector(ctx, from: map.point(t.pos), to: anchors[0])
                lineIdx = 1
            }
            let side = hud.tracks
                .filter { $0.id != hud.lockId && $0.age >= 8 }
                .sorted { $0.area > $1.area }
                .prefix(3)
            for t in side {
                if lineIdx >= anchors.count { break }
                connector(ctx, from: map.point(t.pos), to: anchors[lineIdx])
                lineIdx += 1
            }
        }
    }

    private func connector(_ ctx: GraphicsContext, from: CGPoint, to: CGPoint) {
        var p = Path()
        p.move(to: from); p.addLine(to: to)
        ctx.stroke(p, with: .color(Color.yellow.opacity(0.5)), lineWidth: 1)
    }

    private func cornerPath(_ r: CGRect) -> Path {
        let l = min(14, r.width * 0.3)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

// MARK: - Bloque de telemetría

struct TelemetryBlock: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var geolog: GeologManager
    @ObservedObject var tilt: TiltManager

    private func deg(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "--" }

    var body: some View {
        let hud = engine.hud
        let lockLine: String = {
            if let id = hud.lockId, let t = hud.tracks.first(where: { $0.id == id }) {
                return "X\(Int(t.pos.x)) Y\(Int(t.pos.y)) A\(t.area)"
            }
            return "NONE"
        }()
        let gpsLine = geolog.fix.map {
            String(format: "GPS: %.5f, %.5f", $0.coordinate.latitude, $0.coordinate.longitude)
        } ?? "GPS: OFF"

        VStack(alignment: .leading, spacing: 1) {
            Text("CYBEREYE // EXPERIMENTAL SENSOR SUITE")
            Text("THRESH: \(Int(engine.sensitivity))  MIN AREA: \(Int(engine.minArea))  POINTS: \(hud.tracks.count)/\(Int(engine.maxPoints))")
            Text("LOCK: \(lockLine)")
            Text("HDG:\(deg(tilt.heading)) PITCH:\(deg(tilt.pitch)) ROLL:\(deg(tilt.roll))")
            Text("FPS:\(hud.fps)  FRM:\(hud.frames)  AUTOLOCK:\(engine.autolock ? "ON" : "OFF")")
            Text("\(gpsLine)  TAG: \(hud.tag)")
            Text("UPLINK: NONE · ON-DEVICE ONLY")
            Text(hud.status)
                .foregroundStyle(hud.statusIsAlert ? Color.sigAmber : Color.sigGreen)
                .padding(.top, 3)
        }
        .font(.system(size: 8.5, design: .monospaced))
        .foregroundStyle(Color.sigGreen)
        .padding(6)
        .background(Color(red: 0, green: 0.05, blue: 0.02).opacity(0.55))
        .overlay(Rectangle().stroke(Color.sigGreen.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Ventana MAG-TRACK

struct MagWindow: View {
    @ObservedObject var engine: CameraEngine
    let track: TrackBox?
    let title: String
    let placeholder: String?
    let width: CGFloat

    private var height: CGFloat { width * 0.67 }

    private var image: UIImage? {
        track.flatMap { engine.magImages[$0.id] }
    }

    var body: some View {
        if track != nil || placeholder != nil {
            VStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 7, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color(red: 0, green: 0.1, blue: 0.04).opacity(0.92))
                ZStack {
                    Color(red: 0, green: 0.06, blue: 0.02)
                    if let img = image, track != nil {
                        Image(uiImage: img).resizable().scaledToFill()
                            .frame(width: width, height: height).clipped()
                        MagReticle()
                    } else if let ph = placeholder {
                        Text(ph)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(Color.sigGreen.opacity(0.6))
                    }
                }
                .frame(width: width, height: height)
                Text(footer)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color(red: 0, green: 0.1, blue: 0.04).opacity(0.92))
            }
            .frame(width: width)
            .foregroundStyle(Color.sigGreen)
            .overlay(Rectangle().stroke(Color.sigGreen, lineWidth: 1))
        }
    }

    private var footer: String {
        guard let t = track else { return "SEARCHING…" }
        let tag = t.label.map { "  \($0)" } ?? ""
        return "X\(Int(t.pos.x)) Y\(Int(t.pos.y)) A\(t.area)  Z:2.0x\(tag)"
    }
}

struct MagReticle: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.18
            var p = Path()
            p.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            p.move(to: CGPoint(x: c.x - r * 1.6, y: c.y)); p.addLine(to: CGPoint(x: c.x - r * 0.6, y: c.y))
            p.move(to: CGPoint(x: c.x + r * 0.6, y: c.y)); p.addLine(to: CGPoint(x: c.x + r * 1.6, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - r * 1.6)); p.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.6))
            p.move(to: CGPoint(x: c.x, y: c.y + r * 0.6)); p.addLine(to: CGPoint(x: c.x, y: c.y + r * 1.6))
            ctx.stroke(p, with: .color(Color.sigGreen.opacity(0.85)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Radar

struct RadarView: View {
    let hud: HUDState

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.animation) { timeline in
                Canvas { ctx, size in
                    let r = min(size.width, size.height) / 2
                    let c = CGPoint(x: r, y: r)
                    for rr in [r - 1, r * 0.66, r * 0.33] {
                        var p = Path()
                        p.addArc(center: c, radius: rr, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                        ctx.stroke(p, with: .color(Color.sigGreen.opacity(0.5)), lineWidth: 1)
                    }
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    let ang = CGFloat(t.truncatingRemainder(dividingBy: 4) / 4 * 2 * Double.pi)
                    var sweep = Path()
                    sweep.move(to: c)
                    sweep.addLine(to: CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r))
                    ctx.stroke(sweep, with: .color(Color.sigGreen.opacity(0.35)), lineWidth: 2)
                    for tr in hud.tracks {
                        let bx = c.x + (tr.pos.x / max(hud.bufferSize.width, 1) - 0.5) * 2 * r * 0.9
                        let by = c.y + (tr.pos.y / max(hud.bufferSize.height, 1) - 0.5) * 2 * r * 0.9
                        let isLock = tr.id == hud.lockId
                        ctx.fill(Path(ellipseIn: CGRect(x: bx - 2, y: by - 2, width: isLock ? 6 : 4, height: isLock ? 6 : 4)),
                                 with: .color(isLock ? Color.sigAmber : Color.sigGreen))
                    }
                }
            }
            .frame(width: 108, height: 108)
            .background(Color(red: 0, green: 0.06, blue: 0.02).opacity(0.8))
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.sigGreen.opacity(0.35), lineWidth: 1))
            Text("RADAR · BLIPS \(hud.tracks.count)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - Panel GEOLOG

struct GeologBox: View {
    @ObservedObject var geolog: GeologManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GEOLOG PANEL").foregroundStyle(Color.sigGreen)
            if geolog.denied {
                Text("GPS: DENEGADO").foregroundStyle(Color.sigRed)
            } else if let f = geolog.fix {
                Text(String(format: "LAT %.5f", f.coordinate.latitude))
                Text(String(format: "LON %.5f", f.coordinate.longitude))
                Text(String(format: "ALT %.0fm  ACC ±%.0fm", f.altitude, f.horizontalAccuracy))
            } else {
                Text("ESPERANDO FIX…")
            }
        }
        .font(.system(size: 8.5, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(6)
        .background(Color(red: 0, green: 0.08, blue: 0.03).opacity(0.82))
        .overlay(Rectangle().stroke(Color.sigGreen.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Botones

struct BigButton: View {
    let title: String
    var active = false
    var tint: Color = .sigGreen
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, design: .monospaced))
                .tracking(0.8)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(tint)
                .background(active ? tint.opacity(0.16) : Color(red: 0, green: 0.16, blue: 0.06).opacity(0.8))
                .overlay(Rectangle().stroke(active ? tint : tint.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - Panel avanzado

struct AdvPanel: View {
    @ObservedObject var engine: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("OBJETIVO") {
                    Button("CAPTURE RETICLE — fijar lo que esté en la mira") { engine.captureFromReticle(); dismiss() }
                    Button("SNAP — etiquetar objetivo con IA (en el iPhone)") { engine.snapClassify(); dismiss() }
                    Button("UNLOCK TARGET", role: .destructive) { engine.unlock(); dismiss() }
                    Toggle("AUTOLOCK (rastreo automático)", isOn: $engine.autolock)
                }
                Section("VISUAL") {
                    Toggle("Puntos de movimiento (speckle)", isOn: $engine.showSpeckle)
                    Toggle("Ventanas MAG-TRACK", isOn: $engine.showMags)
                    Toggle("UFO SCAN (alta sensibilidad cielo)", isOn: $engine.ufoMode)
                }
                Section("SENSOR") {
                    VStack(alignment: .leading) {
                        Text("THRESH / SENS: \(Int(engine.sensitivity))")
                        Slider(value: $engine.sensitivity, in: 8...80, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("MIN MOTION AREA: \(Int(engine.minArea))")
                        Slider(value: $engine.minArea, in: 1...120, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("MAX POINTS: \(Int(engine.maxPoints))")
                        Slider(value: $engine.maxPoints, in: 1...24, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("LOCK SEARCH RADIUS: \(Int(engine.lockRadius))")
                        Slider(value: $engine.lockRadius, in: 60...400, step: 10)
                    }
                }
                Section {
                    Text("Todo el procesamiento ocurre en tu iPhone. El video nunca sale del dispositivo.")
                        .font(.footnote)
                }
            }
            .font(.system(.body, design: .monospaced))
            .navigationTitle("ADV PANEL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("CERRAR") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Reporte

struct ReportView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var geolog: GeologManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    let hud = engine.hud
                    Group {
                        Text("OP REPORT  GENERATED \(Date().formatted(date: .abbreviated, time: .standard))")
                        Text("CYBEREYE-CLASS OPERATION SURVEILLANCE REPORT")
                        Text("────────────────────────────")
                        Text("FRAME SAMPLES: \(hud.frames)")
                        Text("MOTION SAMPLES TOTAL: \(hud.motionSamples)")
                        Text("ACTIVE TRACKS: \(hud.tracks.count)")
                        Text("UNIQUE TRACKS ISSUED: \(hud.uniqueTracks)")
                        Text("LOCK STATE: \(hud.lockId.map { "ENGAGED · TRK-\(CameraEngine.pad($0))" } ?? "NONE")")
                        Text("SNAP TAG: \(hud.tag)")
                        Text(geolog.fix.map { String(format: "GPS: %.5f, %.5f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "GPS: OFF (privacidad)")
                        Text("DATA RETENTION: NONE · ALL ON-DEVICE")
                    }
                    Text("────────────────────────────")
                    Text("UNIQUE-TRACK EVENT LOG (latest first):").padding(.bottom, 4)
                    ForEach(engine.events.reversed()) { ev in
                        Text("\(ev.time)  \(ev.text)")
                            .foregroundStyle(ev.highlight ? Color.sigCyan : Color.sigGreen)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.sigGreen)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color.black)
            .navigationTitle("UNIQUE-TRACK REPORT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("CLOSE") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
