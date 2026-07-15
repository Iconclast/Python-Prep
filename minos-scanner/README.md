# MINOS SIGINT // ADVANCED TARGET LOCK — edición web para iPhone

Réplica web del proyecto [MINOS - SIGINT UFO Scanner](https://github.com/Kruix-art/MINOS---SIGINT-UFO-Scanner)
(el de la app "PANOPTICORE" viral). El original es una app de Python/Kivy para
Android; esta versión corre en Safari en cualquier iPhone, sin instalar nada.

## Cómo usarla en el iPhone

1. Abre la URL de la app en **Safari** (requiere HTTPS).
2. Toca **▸ INITIALIZE SENSOR** y acepta el permiso de cámara.
3. (Opcional) Botón **Compartir → Agregar a pantalla de inicio** para tenerla
   como app a pantalla completa con su ícono.

## Funciones (como el original)

| Función | Descripción |
|---|---|
| Detección de micro-movimiento | Análisis de píxeles cuadro a cuadro, dibuja cajas de rastreo verdes |
| Rastreo tipo Kalman | Filtro alfa-beta con predicción de velocidad y suavizado |
| CAPTURE RETICLE | Apunta con la retícula central y fija el objetivo más cercano |
| Memoria de objetivo | Si el objetivo desaparece, lo busca y lo readquiere (conf decae) |
| SNAP YOLO | Etiquetado neuronal de un solo disparo (COCO-SSD/TensorFlow.js) |
| ADV LOCK VIEWER | Ventana inspectora ampliada del objetivo fijado |
| RADAR | Radar con barrido, blips y nivel de señal |
| MODE | Filtros NORMAL / EDGE / THERMAL / DITHER |
| UFO SCAN | Modo cielo de alta sensibilidad |
| TRACK REPORT | Reporte estilo PANOPTICORE: log de tracks únicos, muestras, GPS |
| FLOW | Estelas de flujo óptico de cada track |
| SCAN LINES / MIRROR / FLIP CAM / ZOOM | Extras de cámara |
| SLIDERS | Sensibilidad, área mínima, máx. puntos, radios de captura/búsqueda |

## Correr localmente

Cualquier servidor estático sirve (la cámara exige HTTPS o `localhost`):

```bash
cd minos-scanner
python3 -m http.server 8000
# abre http://localhost:8000
```

Todo el código está en un solo archivo: `index.html` (sin dependencias;
TensorFlow.js se carga bajo demanda desde CDN solo al usar SNAP YOLO).
