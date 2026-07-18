//
//  ContentView.swift
//  CyberEye
//
//  V2 — Interfaz minimalista:
//  · Una línea de estado arriba (tócala para ver la telemetría completa)
//  · Toca cualquier cosa en pantalla para fijarla como objetivo
//  · Ventanas MAG flotantes: arrastra para mover, pellizca para escalar
//  · Color e escala de la interfaz ajustables en Ajustes
//

import AVFoundation
import SwiftUI

// MARK: - Tema

enum ThemeChoice: String, CaseIterable, Identifiable {
    case verde, cian, ambar, rojo, blanco, rosa
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .verde: return Color(red: 0, green: 1, blue: 110 / 255)
        case .cian: return Color(red: 40 / 255, green: 220 / 255, blue: 1)
        case .ambar: return Color(red: 1, green: 180 / 255, blue: 40 / 255)
        case .rojo: return Color(red: 1, green: 70 / 255, blue: 70 / 255)
        case .blanco: return Color(red: 0.92, green: 0.96, blue: 0.94)
        case .rosa: return Color(red: 1, green: 90 / 255, blue: 170 / 255)
        }
    }
}

// MARK: - Vista previa de cámara

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onCaptureButton: (() -> Void)? = nil

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        // Botones físicos (Control de Cámara del iPhone 16 Pro o volumen):
        // alternan la grabación sin ocupar espacio en la interfaz.
        if #available(iOS 17.2, *), let onCaptureButton {
            let interaction = AVCaptureEventInteraction { event in
                if event.phase == .began { onCaptureButton() }
            }
            interaction.isEnabled = true
            v.addInteraction(interaction)
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Mapeo buffer ↔ pantalla (aspect fill)

struct CoverMap {
    let scale: CGFloat
    let ox: CGFloat
    let oy: CGFloat

    init(buffer: CGSize, view: CGSize) {
        scale = max(view.width / max(buffer.width, 1), view.height / max(buffer.height, 1))
        ox = (view.width - buffer.width * scale) / 2
        oy = (view.height - buffer.height * scale) / 2
    }

    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: ox + p.x * scale, y: oy + p.y * scale)
    }

    func toBuffer(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - ox) / scale, y: (p.y - oy) / scale)
    }
}

// MARK: - Vista raíz

struct ContentView: View {
    @StateObject private var engine = CameraEngine()
    @StateObject private var geolog = GeologManager()
    @StateObject private var tilt = TiltManager()
    @StateObject private var recorder = ScreenRecorder()

    @AppStorage("theme") private var themeRaw = ThemeChoice.verde.rawValue
    @AppStorage("uiScale") private var uiScale = 1.0

    @State private var booted = false
    @State private var showReport = false
    @State private var showSettings = false
    @State private var showTelemetry = false
    @State private var showRadar = false
    @State private var pinchStartZoom: CGFloat? = nil

    private var theme: Color { (ThemeChoice(rawValue: themeRaw) ?? .verde).color }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if booted {
                    CameraPreview(session: engine.session,
                                  onCaptureButton: { recorder.toggle() })
                        .ignoresSafeArea()

                    HUDCanvas(hud: engine.hud, viewSize: geo.size,
                              theme: theme, scale: uiScale,
                              showUnlabeled: engine.showUnlabeled)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { v in
                            let map = CoverMap(buffer: engine.hud.bufferSize, view: geo.size)
                            engine.lockAt(bufferPoint: map.toBuffer(v.location))
                        })
                        .simultaneousGesture(
                            MagnificationGesture()
                                .onChanged { m in
                                    if pinchStartZoom == nil { pinchStartZoom = engine.displayZoom }
                                    engine.setZoom(display: (pinchStartZoom ?? 1) * m, ramp: false)
                                }
                                .onEnded { _ in pinchStartZoom = nil }
                        )

                    overlayUI(size: geo.size)

                    // ventanas MAG flotantes (arrastrables, escalables)
                    if let lock = engine.hud.lock {
                        FloatingPanel(initial: CGPoint(x: geo.size.width - 105, y: 150)) {
                            MagWindow(title: "LOCK",
                                      image: engine.magImages["lock"],
                                      footer: "X\(Int(lock.pos.x)) Y\(Int(lock.pos.y)) C\(String(format: "%.2f", lock.conf))\(lock.label.map { " · \($0)" } ?? "")",
                                      width: 165 * uiScale, theme: theme, scale: uiScale)
                        }
                    }
                    ForEach(0..<engine.extraWindows, id: \.self) { i in
                        if let img = engine.magImages["t\(i)"] {
                            FloatingPanel(initial: CGPoint(x: 80, y: 180 + CGFloat(i) * 130)) {
                                MagWindow(title: "MAG-\(i + 1)", image: img, footer: nil,
                                          width: 120 * uiScale, theme: theme, scale: uiScale)
                            }
                        }
                    }
                } else {
                    BootView(denied: engine.cameraDenied, theme: theme) {
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
            ReportView(engine: engine, geolog: geolog, theme: theme)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(engine: engine, geolog: geolog, showRadar: $showRadar,
                         themeRaw: $themeRaw, uiScale: $uiScale)
        }
    }

    // MARK: superposición mínima

    @ViewBuilder
    private func overlayUI(size: CGSize) -> some View {
        VStack(spacing: 0) {
            // línea de estado — tócala para expandir telemetría
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showTelemetry.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(engine.hud.lock != nil ? theme : .clear)
                            .stroke(theme, lineWidth: 1)
                            .frame(width: 7, height: 7)
                        Text(statusLine)
                            .lineLimit(1)
                        if recorder.isRecording {
                            Circle().fill(.red).frame(width: 7, height: 7)
                                .opacity(0.9)
                            Text("REC").foregroundStyle(.red)
                        } else if let note = recorder.note {
                            Text(note).foregroundStyle(.red)
                        }
                    }
                    if showTelemetry { telemetryDetail }
                }
                .font(.system(size: 10 * uiScale, design: .monospaced))
                .foregroundStyle(theme)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(.top, 6)

            Spacer()

            HStack(alignment: .bottom) {
                if geolog.active { GeologBox(geolog: geolog, theme: theme, scale: uiScale) }
                Spacer()
                if showRadar { RadarView(hud: engine.hud, theme: theme) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // selector de lente / zoom (como la app de cámara)
            HStack(spacing: 10) {
                ForEach(engine.lensOptions, id: \.self) { lens in
                    Button {
                        engine.setZoom(display: lens, ramp: true)
                    } label: {
                        Text(lensLabel(lens))
                            .font(.system(size: 10 * uiScale, design: .monospaced))
                            .frame(width: 38 * uiScale, height: 38 * uiScale)
                            .foregroundStyle(isCurrentLens(lens) ? .black : theme)
                            .background(isCurrentLens(lens) ? theme : .black.opacity(0.45),
                                        in: Circle())
                            .overlay(Circle().stroke(theme.opacity(0.5), lineWidth: 1))
                    }
                }
                Text(String(format: "%.1fx", Double(engine.displayZoom)))
                    .font(.system(size: 10 * uiScale, design: .monospaced))
                    .foregroundStyle(theme.opacity(0.8))
            }
            .padding(.bottom, 8)

            // barra mínima
            HStack(spacing: 8) {
                GhostButton(title: "REPORT", theme: theme, scale: uiScale) { showReport = true }
                GhostButton(title: "SNAP", theme: theme, scale: uiScale) { engine.snapClassify() }
                GhostButton(title: "UNLOCK", theme: theme, scale: uiScale) { engine.unlock() }
                GhostButton(title: "⚙", theme: theme, scale: uiScale) { showSettings = true }
                    .frame(width: 46 * uiScale)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }

    private var statusLine: String {
        let h = engine.hud
        return "CYBEREYE · \(h.status) · TRK \(h.tracks.count) · \(h.fps)FPS"
    }

    private func lensLabel(_ lens: CGFloat) -> String {
        if lens < 1 { return ".5" }
        let v = Double(lens)
        return v.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", v)
            : String(format: "%.1f", v)
    }

    private func isCurrentLens(_ lens: CGFloat) -> Bool {
        // marca la lente cuyo valor está más cerca del zoom actual
        guard let nearest = engine.lensOptions.min(by: {
            abs($0 - engine.displayZoom) < abs($1 - engine.displayZoom)
        }) else { return false }
        return nearest == lens
    }

    private var telemetryDetail: some View {
        let h = engine.hud
        func deg(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "--" }
        let gps = geolog.fix.map {
            String(format: "GPS %.5f, %.5f", $0.coordinate.latitude, $0.coordinate.longitude)
        } ?? "GPS OFF"
        return VStack(alignment: .leading, spacing: 1) {
            Text("FRM \(h.frames)  MOTION \(h.motionSamples)")
            Text("TRACKS ÚNICOS \(h.uniqueTracks)  MAX \(Int(engine.maxPoints))")
            Text("HDG \(deg(tilt.heading))  PITCH \(deg(tilt.pitch))  ROLL \(deg(tilt.roll))")
            Text(gps)
            Text("PROCESAMIENTO 100% EN EL DISPOSITIVO")
        }
        .padding(.top, 3)
        .opacity(0.85)
    }
}

// MARK: - Panel flotante (arrastrar + pellizcar)

struct FloatingPanel<Content: View>: View {
    @State private var position: CGPoint
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @GestureState private var dragDelta: CGSize = .zero
    private let content: () -> Content

    init(initial: CGPoint, @ViewBuilder content: @escaping () -> Content) {
        _position = State(initialValue: initial)
        self.content = content
    }

    var body: some View {
        content()
            .scaleEffect(scale)
            .position(x: position.x + dragDelta.width,
                      y: position.y + dragDelta.height)
            .gesture(
                DragGesture()
                    .updating($dragDelta) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        position.x += v.translation.width
                        position.y += v.translation.height
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { m in scale = min(2.2, max(0.5, baseScale * m)) }
                    .onEnded { _ in baseScale = scale }
            )
    }
}

// MARK: - Ventana MAG

struct MagWindow: View {
    let title: String
    let image: UIImage?
    let footer: String?
    let width: CGFloat
    let theme: Color
    let scale: Double

    private var height: CGFloat { width / 1.5 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text("⣿").opacity(0.5)   // asa de arrastre
            }
            .font(.system(size: 8 * scale, design: .monospaced))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(.black.opacity(0.85))

            ZStack {
                Color.black.opacity(0.75)
                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .clipped()
                }
                MagReticle(theme: theme)
            }
            .frame(width: width, height: height)

            if let f = footer {
                Text(f)
                    .font(.system(size: 7.5 * scale, design: .monospaced))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.85))
            }
        }
        .frame(width: width)
        .foregroundStyle(theme)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.opacity(0.8), lineWidth: 1))
        .animation(nil, value: image)
    }
}

struct MagReticle: View {
    let theme: Color

    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = min(size.width, size.height) * 0.16
            var p = Path()
            p.addArc(center: c, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            p.move(to: CGPoint(x: c.x - r * 1.5, y: c.y)); p.addLine(to: CGPoint(x: c.x - r * 0.6, y: c.y))
            p.move(to: CGPoint(x: c.x + r * 0.6, y: c.y)); p.addLine(to: CGPoint(x: c.x + r * 1.5, y: c.y))
            p.move(to: CGPoint(x: c.x, y: c.y - r * 1.5)); p.addLine(to: CGPoint(x: c.x, y: c.y - r * 0.6))
            p.move(to: CGPoint(x: c.x, y: c.y + r * 0.6)); p.addLine(to: CGPoint(x: c.x, y: c.y + r * 1.5))
            ctx.stroke(p, with: .color(theme.opacity(0.8)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Lienzo del HUD

struct HUDCanvas: View {
    let hud: HUDState
    let viewSize: CGSize
    let theme: Color
    let scale: Double
    let showUnlabeled: Bool

    var body: some View {
        Canvas { ctx, size in
            let map = CoverMap(buffer: hud.bufferSize, view: size)

            // puntos de movimiento — sutiles
            for s in hud.speckles {
                let p = map.toView(s)
                ctx.fill(Path(CGRect(x: p.x - 1, y: p.y - 1, width: 2, height: 2)),
                         with: .color(theme.opacity(0.3)))
            }

            // cajas identificadas — con etiqueta (PERSON 92%, CAR 63%…)
            for t in hud.tracks where t.label != nil {
                let p = map.toView(t.pos)
                let w = max(40, t.size.width * map.scale)
                let h = max(40, t.size.height * map.scale)
                let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                ctx.stroke(cornerPath(rect), with: .color(theme.opacity(0.85)), lineWidth: 1.2)
                ctx.draw(Text("\(t.label ?? "") \(Int(t.labelConf * 100))%")
                            .font(.system(size: 9 * scale, design: .monospaced))
                            .foregroundStyle(theme),
                         at: CGPoint(x: rect.minX, y: rect.minY - 8), anchor: .leading)
            }

            // cajas sin identificar — solo si el usuario las quiere ver
            if showUnlabeled {
                for t in hud.tracks where t.label == nil && t.age >= 20 {
                    let p = map.toView(t.pos)
                    let w = max(34, t.size.width * map.scale)
                    let h = max(34, t.size.height * map.scale)
                    let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                    ctx.stroke(cornerPath(rect), with: .color(theme.opacity(0.35)), lineWidth: 1)
                }
            }

            // objetivo fijado — caja completa + etiqueta
            if let lock = hud.lock {
                let p = map.toView(lock.pos)
                let w = max(46, lock.size.width * map.scale)
                let h = max(46, lock.size.height * map.scale)
                let rect = CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h)
                ctx.stroke(cornerPath(rect), with: .color(theme), lineWidth: 2)
                var cross = Path()
                cross.move(to: CGPoint(x: p.x - 7, y: p.y)); cross.addLine(to: CGPoint(x: p.x + 7, y: p.y))
                cross.move(to: CGPoint(x: p.x, y: p.y - 7)); cross.addLine(to: CGPoint(x: p.x, y: p.y + 7))
                ctx.stroke(cross, with: .color(theme), lineWidth: 1)
                let label = lock.label ?? "LOCK"
                ctx.draw(Text("\(label) \(String(format: "%.0f%%", lock.conf * 100))")
                            .font(.system(size: 9 * scale, design: .monospaced))
                            .foregroundStyle(theme),
                         at: CGPoint(x: rect.minX, y: rect.minY - 9), anchor: .leading)
            }
        }
    }

    private func cornerPath(_ r: CGRect) -> Path {
        let l = min(12, r.width * 0.28)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

// MARK: - Botones fantasma

struct GhostButton: View {
    let title: String
    let theme: Color
    let scale: Double
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10 * scale, design: .monospaced))
                .tracking(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10 * scale)
                .foregroundStyle(theme)
                .background(.black.opacity(0.4), in: Capsule())
                .overlay(Capsule().stroke(theme.opacity(0.5), lineWidth: 1))
        }
    }
}

// MARK: - Radar

struct RadarView: View {
    let hud: HUDState
    let theme: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let r = min(size.width, size.height) / 2
                let c = CGPoint(x: r, y: r)
                for rr in [r - 1, r * 0.6] {
                    var p = Path()
                    p.addArc(center: c, radius: rr, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                    ctx.stroke(p, with: .color(theme.opacity(0.4)), lineWidth: 1)
                }
                let t = timeline.date.timeIntervalSinceReferenceDate
                let ang = CGFloat(t.truncatingRemainder(dividingBy: 4) / 4 * 2 * Double.pi)
                var sweep = Path()
                sweep.move(to: c)
                sweep.addLine(to: CGPoint(x: c.x + cos(ang) * r, y: c.y + sin(ang) * r))
                ctx.stroke(sweep, with: .color(theme.opacity(0.3)), lineWidth: 1.5)
                for tr in hud.tracks {
                    let bx = c.x + (tr.pos.x / max(hud.bufferSize.width, 1) - 0.5) * 2 * r * 0.85
                    let by = c.y + (tr.pos.y / max(hud.bufferSize.height, 1) - 0.5) * 2 * r * 0.85
                    ctx.fill(Path(ellipseIn: CGRect(x: bx - 1.5, y: by - 1.5, width: 3, height: 3)),
                             with: .color(theme))
                }
                if let lock = hud.lock {
                    let bx = c.x + (lock.pos.x / max(hud.bufferSize.width, 1) - 0.5) * 2 * r * 0.85
                    let by = c.y + (lock.pos.y / max(hud.bufferSize.height, 1) - 0.5) * 2 * r * 0.85
                    ctx.fill(Path(ellipseIn: CGRect(x: bx - 2.5, y: by - 2.5, width: 5, height: 5)),
                             with: .color(.white))
                }
            }
        }
        .frame(width: 84, height: 84)
        .background(.black.opacity(0.5))
        .clipShape(Circle())
        .overlay(Circle().stroke(theme.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Panel GEOLOG

struct GeologBox: View {
    @ObservedObject var geolog: GeologManager
    let theme: Color
    let scale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GEOLOG").foregroundStyle(theme)
            if geolog.denied {
                Text("GPS DENEGADO").foregroundStyle(.red)
            } else if let f = geolog.fix {
                Text(String(format: "%.5f, %.5f", f.coordinate.latitude, f.coordinate.longitude))
                Text(String(format: "ALT %.0fm ±%.0fm", f.altitude, f.horizontalAccuracy))
            } else {
                Text("BUSCANDO…")
            }
        }
        .font(.system(size: 8.5 * scale, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(7)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Arranque

struct BootView: View {
    let denied: Bool
    let theme: Color
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("CYBEREYE")
                .font(.system(size: 26, design: .monospaced))
                .tracking(6)
            Text("Rastreo visual en tiempo real.\nTodo se procesa en este iPhone —\nel video nunca sale del dispositivo.\nGPS apagado por defecto.")
                .font(.system(size: 12, design: .monospaced))
                .opacity(0.8)
            Button(action: onStart) {
                Text("▸ INICIAR")
                    .font(.system(size: 14, design: .monospaced))
                    .tracking(3)
                    .padding(.vertical, 13)
                    .padding(.horizontal, 30)
                    .overlay(Capsule().stroke(theme, lineWidth: 1))
            }
            if denied {
                Text("Permiso de cámara denegado.\nAjustes > CyberEye > Cámara > Permitir")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.red)
            }
        }
        .foregroundStyle(theme)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.black)
    }
}

// MARK: - Ajustes

struct SettingsView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var geolog: GeologManager
    @Binding var showRadar: Bool
    @Binding var themeRaw: String
    @Binding var uiScale: Double
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("COLOR DE LA INTERFAZ") {
                    HStack(spacing: 14) {
                        ForEach(ThemeChoice.allCases) { choice in
                            Button {
                                themeRaw = choice.rawValue
                            } label: {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 32, height: 32)
                                    .overlay(
                                        Circle().stroke(.white,
                                                        lineWidth: themeRaw == choice.rawValue ? 2 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("TAMAÑO") {
                    VStack(alignment: .leading) {
                        Text("Escala de la interfaz: \(String(format: "%.1f", uiScale))x")
                        Slider(value: $uiScale, in: 0.8...1.5, step: 0.1)
                    }
                    Text("Las ventanas MAG se mueven arrastrándolas y se escalan pellizcándolas.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("VENTANAS") {
                    Stepper("Ventanas MAG extra: \(engine.extraWindows)",
                            value: $engine.extraWindows, in: 0...3)
                    Toggle("Radar", isOn: $showRadar)
                    Toggle("Puntos de movimiento", isOn: $engine.showSpeckle)
                    Toggle("Cajas sin identificar", isOn: $engine.showUnlabeled)
                }
                Section("ZOOM") {
                    Text("Pellizca la pantalla para hacer zoom. Los botones .5 / 1 / \(engine.lensOptions.count > 2 ? "tele" : "2") cambian de lente, como la app de cámara.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("GRABACIÓN") {
                    Text("Pulsa el botón de Control de Cámara (iPhone 16 Pro) o un botón de volumen para iniciar y detener la grabación de lo que ves (cámara + HUD). El video se guarda en Fotos. Verás un punto rojo REC arriba mientras graba.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("DETECTOR") {
                    Text(engine.yoloActive
                         ? "YOLO integrado activo: 80 clases (personas, carros, motos, animales…) detectadas en el Neural Engine del iPhone. Sin internet: el modelo viaja dentro de la app."
                         : "YOLO no disponible — usando detectores del sistema (personas + clasificador).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("RASTREO") {
                    Toggle("Autolock (fija objetivos solo)", isOn: $engine.autolock)
                    Toggle("Modo cielo / alta sensibilidad", isOn: $engine.ufoMode)
                    VStack(alignment: .leading) {
                        Text("Sensibilidad: \(Int(engine.sensitivity))")
                        Slider(value: $engine.sensitivity, in: 8...80, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Área mínima: \(Int(engine.minArea))")
                        Slider(value: $engine.minArea, in: 1...120, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("Máx. objetivos: \(Int(engine.maxPoints))")
                        Slider(value: $engine.maxPoints, in: 1...20, step: 1)
                    }
                    Text("Consejo: también puedes tocar cualquier cosa en pantalla para fijarla, aunque no se mueva.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("GEOLOG") {
                    Toggle("GPS en telemetría", isOn: Binding(
                        get: { geolog.active },
                        set: { _ in geolog.toggle() }))
                }
                Section {
                    Text("Privacidad: todo el procesamiento ocurre en tu iPhone. El video nunca sale del dispositivo. Sin cuentas, sin rastreo, sin internet.")
                        .font(.footnote)
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Listo") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Reporte

struct ReportView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var geolog: GeologManager
    let theme: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    let hud = engine.hud
                    Group {
                        Text("CYBEREYE // UNIQUE-TRACK REPORT")
                        Text("GENERADO \(Date().formatted(date: .abbreviated, time: .standard))")
                        Text("──────────────────────────")
                        Text("CUADROS: \(hud.frames)")
                        Text("MUESTRAS DE MOVIMIENTO: \(hud.motionSamples)")
                        Text("TRACKS ACTIVOS: \(hud.tracks.count)")
                        Text("TRACKS ÚNICOS: \(hud.uniqueTracks)")
                        Text("LOCK: \(hud.lock != nil ? "ACTIVO" : "NINGUNO")\(hud.lock?.label.map { " · \($0)" } ?? "")")
                        Text(geolog.fix.map { String(format: "GPS: %.5f, %.5f", $0.coordinate.latitude, $0.coordinate.longitude) } ?? "GPS: OFF")
                        Text("RETENCIÓN DE DATOS: NINGUNA · TODO EN EL DISPOSITIVO")
                    }
                    Text("──────────────────────────")
                    Text("EVENTOS (recientes primero):").padding(.bottom, 4)
                    ForEach(engine.events.reversed()) { ev in
                        Text("\(ev.time)  \(ev.text)")
                            .opacity(ev.highlight ? 1 : 0.75)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .background(Color.black)
            .navigationTitle("Reporte")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Cerrar") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

#Preview {
    ContentView()
}
