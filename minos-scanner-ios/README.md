# PANOPTICORE — app nativa de iPhone (Xcode)

Tu propia app nativa estilo PANOPTICORE / MINOS SIGINT: detección de
movimiento en tiempo real, rastreo tipo Kalman con autolock, ventanas
AUTO MAG-TRACK, telemetría con brújula y giroscopio reales, radar,
reporte de tracks únicos y etiquetado de objetos con la IA integrada de
Apple (Vision) — **todo 100% en el dispositivo, sin internet**.

## Cómo instalarla en tu iPhone (desde tu Mac)

1. **Instala Xcode** (gratis) desde el App Store de la Mac. Es grande
   (~15 GB), tarda un rato la primera vez.
2. **Descarga este proyecto**: en el repositorio, botón verde
   **Code → Download ZIP** (rama `claude/iphone-app-dev-sdltc6`), o clónalo.
3. Abre `minos-scanner-ios/Panopticore.xcodeproj` (doble clic).
4. **Conecta tu iPhone a la Mac con el cable.** En el iPhone toca
   "Confiar en esta computadora" si te lo pide.
5. En Xcode, arriba en el centro, selecciona **tu iPhone** como destino
   (donde dice "Any iOS Device").
6. **Firma la app con tu Apple ID**:
   - Xcode → Settings → Accounts → `+` → agrega tu Apple ID.
   - En el proyecto: clic en "Panopticore" (raíz del navegador
     izquierdo) → pestaña **Signing & Capabilities** → marca
     "Automatically manage signing" → en **Team** elige tu nombre
     (Personal Team).
   - Si el "Bundle Identifier" da conflicto, cámbialo a algo único,
     p. ej. `com.tunombre.panopticore`.
7. Pulsa **▶ (Run)**. Xcode compila e instala la app en tu iPhone.
8. La primera vez, en el iPhone: **Ajustes → General → VPN y gestión de
   dispositivos → tu Apple ID → Confiar**. Vuelve a abrir la app.

## Importante (cuenta gratis de Apple)

- Con Apple ID **gratis**, la firma caduca a los **7 días**: la app deja
  de abrir y basta reconectar el iPhone y pulsar ▶ en Xcode de nuevo
  (30 segundos). Tus ajustes no se pierden.
- Con la cuenta de desarrollador de pago ($99/año) dura 1 año y puedes
  subirla al App Store.

## Privacidad y seguridad

- El video de la cámara se procesa **solo dentro del iPhone**; la app no
  tiene ninguna conexión a internet (ni siquiera para la IA: usa Vision,
  el modelo que ya viene en iOS).
- GPS apagado por defecto; solo se activa con el botón GEOLOG y se libera
  al desactivarlo.
- No guarda video, no tiene cuentas, no tiene analítica.

## Estructura

- `Panopticore/CameraEngine.swift` — cámara, detección de movimiento,
  rastreo alfa-beta, autolock, memoria de objetivo, snap con Vision
- `Panopticore/ContentView.swift` — HUD, telemetría, MAG-TRACK, radar,
  reporte y panel avanzado
- `Panopticore/Managers.swift` — GPS opcional y giroscopio/brújula

Si Xcode muestra algún error al compilar, copia el mensaje y pégamelo:
lo corrijo al momento.
