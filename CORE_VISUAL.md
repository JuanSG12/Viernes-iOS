# CORE_VISUAL — núcleo 3D y pantalla principal

Estado honesto: **escrito desde Windows, sin haberlo visto en pantalla**. Compila (CI) o no, y su aspecto real solo se juzga en el simulador (capturas del CI) y en el iPhone. Nada de lo que sigue se afirma como «se ve bien» hasta que alguien lo vea.

## 1. Tecnología: evaluación y decisión

| Opción | Fidelidad | Rendimiento | Mantenimiento | iOS 18+ | Veredicto |
|---|---|---|---|---|---|
| **SceneKit** + geometría por código | Alta para metal: PBR (metalness/roughness), mapa de entorno, luces, cámara HDR con compresión tonal | Muy buena en un 14 Pro Max (≈6 000 vértices por anillo) | API estable y conocida; la geometría son arrays de vértices, independientes del motor | Sí | **Elegida** |
| RealityKit (`RealityView`) | Alta (PBR, IBL) | Buena | Moderno y respaldado por Apple, pero el postproceso (bloom) es limitado y exige recursos de entorno asíncronos; más difícil de verificar sin dispositivo | `RealityView` en iOS 18 | Descartada por ahora |
| Metal propio (ray-marching de SDF) | Potencialmente la mejor (reflejos y volumetría reales) | Costosa en batería | Ingeniería pesada, imposible de verificar desde Windows | Sí | Descartada: riesgo desproporcionado |
| Modelo creado en Blender | El modelado puede ser excelente | — | Necesita Blender y un activo binario; igualmente hay que **renderizarlo** con SceneKit o RealityKit, así que no es una alternativa de motor | — | No viable aquí; la malla procedural cumple la misma función |

**Aviso sobre SceneKit**: Apple lo marcó como obsoleto en 2025 en favor de RealityKit. Sigue funcionando en iOS 18 y en el SDK actual (el compilador mostrará avisos de obsolescencia, no errores). Si Apple lo retira, la migración es acotada: `BandRingMesh` solo genera vértices, normales e índices; habría que reescribir `CoreScene.swift` y `ViernesCoreVisual.swift`.

## 2. Qué se construyó

- **`ViernesCoreVisual`** (componente independiente): recibe solo `CoreVisualState` (`idle, listening, thinking, speaking, executing, error, offline`), el nivel de audio y el pulso del habla. **No conoce al cerebro, las herramientas ni la voz**: `MainView` traduce los estados reales (`CoreVisualState(core:executing:)`) en un único punto.
- **Geometría** (`BandRingMesh`): bandas de sección elíptica con torsión y ondulación del radio; **dos eslabones entrelazados** (radio R, centros separados R/2, planos perpendiculares: se enlazan sin atravesarse) y un anillo orbital exterior más fino.
- **Materiales**: PBR metálico (diffuse oscuro, `metalness = 1`, `roughness` 0,12–0,24) y tiras emisivas naranja («metal incandescente») dentro de cada anillo.
- **Iluminación**: mapa de entorno **procedural** de estudio (`CoreEnvironment.studioMap`: negro con cajas de luz blancas y una franja naranja, es lo que refleja el cromo), luz clave fría, contraluz cálido y una **luz omni naranja en la chispa central** que ilumina el metal desde dentro.
- **Resplandor**: destello en cruz (plano que mira a la cámara, mezcla aditiva) + halo 2D (`CoreGlow`) + viñeta. **Sin bloom**: con el bloom HDR de SceneKit aparecían cuadrados negros (simulador e iPhone real) cuando el núcleo se movía; sin bloom las capturas salen limpias. La causa exacta no está demostrada.
- **Animación por estado real** (parámetros suavizados, sin saltos): reposo (casi quieto, 20 fps), escucha (deformación y energía con el nivel del micrófono), pensamiento (anillo exterior se cierra y entran partículas en espiral), habla (pulso y escala con cada palabra), **ejecución** (nodos que orbitan unidos al centro por líneas que pulsan; solo mientras una herramienta se ejecuta de verdad), error (rojo con parpadeo), sin cerebro (apagado).
- **Rendimiento**: 20 fps en reposo y 60 activo; se pausa con la app en segundo plano; respeta «Reducir movimiento».
- **Respaldo 2D** (`ChromeCoreView`): si no hay Metal, si el usuario activa «efectos reducidos» y en las pruebas de UI.

## 3. Pantalla principal frente a la referencia

Reproducido: fondo negro con barridos de cromo y vetas naranja (`ChromeBackdrop`), marca arriba a la izquierda + «VIERNES / Tu asistente personal», engranaje arriba a la derecha, núcleo central grande, pastilla «En línea» (verde, como en la referencia), «¿En qué puedo ayudarte?» / «Tu inteligencia, en tus manos», cuatro mosaicos (**Mi día, Tareas, Clima, Más**; «Más» es un menú con Memoria, Historial, Nueva conversación y Preguntar a Claude), cápsula de voz con ondas naranjas a los lados y «Toca para hablar».

**No se reproduce exactamente (y por qué)**:
- **Los anillos de la referencia** son una ilustración con reflejos trazados con rayos y una geometría concreta; aquí son bandas procedurales con reflejos de mapa de entorno. Será parecido en espíritu, no idéntico.
- **Iluminación volumétrica real** (haces de luz en el aire): se aproxima con bloom y el destello; un volumen real exigiría ray-marching propio.
- **Emblema** de la esquina: es la marca de dos órbitas de la app, no el diamante facetado de la referencia.
- **Tipografía**: San Francisco en versión ancha; la referencia usa otra fuente.
- **Fondo**: los «barridos» son trazos curvos borrosos, no formas 3D pulidas.
- **Foto de la ciudad** de la tarjeta de clima: no hay imágenes; la tarjeta usa símbolos del sistema y degradados.
- **Controles de teclado y altavoz**: la referencia no los muestra; se mantienen, pequeños, a los lados de la cápsula porque son funciones reales.
- **Núcleo con fondo opaco**: la cámara HDR de SceneKit no admite fondo transparente, así que la escena se pinta opaca (gris casi negro) y su borde se difumina con una máscara radial; puede notarse un leve cambio de tono con el fondo de la app.

## 4. Verificación

- El CI compila y pasa las pruebas (el núcleo 3D se desactiva en las pruebas de UI con `--uitest`; `--uitest-3d` lo fuerza).
- Flujo **«Capturas del simulador»** (`screenshots.yml`): lanza la app en cada estado y publica PNG en la rama `ci-screenshots`. Los estados se fijan con `--uitest-core-state=…` y la tarjeta de clima con `--uitest-demo-weather` (una conversación de ejemplo marcada «Vista de prueba»): **solo existen con `--uitest`**.
- Un simulador de CI **no** mide rendimiento ni brillo reales.

## 5. Por probar en el iPhone

Aspecto real del metal y del resplandor 2D; **que ya no aparezcan cuadrados negros al moverse el núcleo** (el CI solo lo comprobó en capturas del simulador); que los dos anillos se vean entrelazados desde varios ángulos; fluidez a 60 fps y batería; que la máscara radial no deje un cuadrado visible; que el menú «Más» responda; contraste y legibilidad con luz solar.
