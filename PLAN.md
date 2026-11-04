# PLAN — investigación, decisiones y hoja de ruta

Fecha de la investigación: 4 de noviembre de 2026. Las fuentes están enlazadas al final. Lo que **no** pude verificar está marcado como tal.

## 1. Hallazgos de la investigación

| Tema | Hallazgo | Consecuencia |
|---|---|---|
| Compilar iOS | Requiere macOS + Xcode. El entorno de trabajo era Windows. | Proyecto completo preparado + CI en macOS + instrucciones exactas. No se afirma que compile. |
| MLX en iPhone | `mlx-swift-lm` (3.32.x, `swift-tools-version: 6.2` ⇒ Xcode 26+). Plataformas del paquete: iOS 17+. API de `ChatSession` con `streamResponse` → `AsyncThrowingStream<String>`. Carga con el macro `#huggingFaceLoadModelContainer` (con `progressHandler`). | Motor MLX aislado en un archivo (`MLXEngine.swift`). |
| Modelo del sistema | Framework `FoundationModels` (iOS 26+): modelo en el dispositivo, sin descarga. El README de mlx-swift-lm menciona iOS 26/27 para su puente `MLXFoundationModels`. | Primer cerebro por defecto cuando está disponible. |
| Reconocimiento | `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26) soportan español, con modelos descargables por idioma. `SFSpeechRecognizer` funciona desde iOS 10 y admite reconocimiento en el dispositivo. | v0.1 usa `SFSpeechRecognizer` (API estable y conocida); `SpeechAnalyzer` queda como mejora planificada ([VOICE.md](VOICE.md)). |
| Claude sin API | La app móvil expone la acción «Ask Claude» (App Intent, iOS 18+) en Atajos/Siri/Spotlight, y el esquema `claude://` (documentado solo para rutas de Claude Code). La documentación no dice si «Ask Claude» devuelve texto a un Atajo. | Dos modos honestos + adaptador. Ver [CLAUDE_INTEGRATION.md](CLAUDE_INTEGRATION.md). |
| Memoria del dispositivo | Reporte de un desarrollador: en un iPhone SE 3 (4 GB) un Qwen 1.7B cuantizado no cargaba (límite de ~2 GB por proceso). Con más RAM y el entitlement `increased-memory-limit` mejora. | Recomendador por RAM + catálogo con modelos de 0,8–2,3 GB. |
| Tamaños | Gemma 3 1B QAT 4 bits ≈ 772 MB; Qwen3 1.7B 4 bits ≈ 984 MB (benchmark de terceros en iPhone 17 Pro). | Valores usados en el catálogo; el resto son estimaciones marcadas «≈». |

**No verificado** (por falta de dispositivo): tokens/s, consumo de batería, calidad de español de cada modelo, comportamiento exacto de `fractionCompleted` durante la descarga, ruta de la caché de Hugging Face en iOS, y si `claude.ai/new?q=` se intercepta como enlace universal dentro de la app de Claude.

## 2. Decisiones técnicas

1. **Core portable + app fina.** Toda la lógica comprobable vive en `ViernesCore` (solo Foundation). Razón: poder probarla con `swift test` sin simulador y aislarla del riesgo de compilación de la capa de Apple.
2. **Swift 5 language mode** con concurrencia moderada (`@MainActor`, actores, `AsyncStream`). Razón: no puedo compilar; el modo Swift 6 estricto añade errores de aislamiento difíciles de predecir.
3. **SwiftData con contenido cifrado** (AES-GCM, clave en Keychain) en lugar de SQLite en claro. Las búsquedas se hacen en RAM sobre los recuerdos descifrados (pocos y cortos).
4. **Sin escucha en segundo plano.** No se declara `UIBackgroundModes`. La palabra «Viernes» solo funciona en primer plano, con indicador visible y apagada por defecto.
5. **Herramientas con tres barreras**: validación estricta → confirmación del usuario (si es sensible) → ejecución; el resultado real vuelve al modelo y a la UI como `ActionRecord`.
6. **Audio sin salir del teléfono por defecto**: reconocimiento solo en el dispositivo; el uso de servidores de Apple es opt-in.
7. **Dos cerebros**, uno del sistema (calidad, sin descarga) y uno MLX (funciona en más dispositivos, descarga explícita).
8. **XcodeGen** (`project.yml`) en vez de un `.xcodeproj` escrito a mano que no pude abrir ni validar.

## 3. Hoja de ruta

### Hecho en v0.1.0 (escrito, no compilado)
- [x] Core: memoria + política + redacción de datos sensibles, recuperación léxica, personalidad, motor de conversación con herramientas, validador, puente Claude, VAD, wake word, texto→voz, ranking de voces, catálogo/recomendador de modelos, enlaces profundos.
- [x] App: UI holográfica, 10 pantallas, voz (STT/TTS), SwiftData cifrado, Siri/App Intents, herramientas EventKit/UIKit, confirmaciones, onboarding, permisos.
- [x] 112 pruebas declaradas + comprobaciones estáticas ejecutadas.
- [x] 9 documentos.

### Siguiente (orden sugerido)
1. **Compilar en Mac/CI y corregir** (esperable: ajustes de firmas en `MLXEngine.swift` y detalles de aislamiento de concurrencia).
2. Ejecutar `swift test` y las pruebas de simulador; corregir.
3. **Pruebas en iPhone físico** (lista en INSTALL.md): voz, Siri, wake word, batería, modelos.
4. Medir rendimiento real y ajustar `ModelRecommender` y `historyCharBudget`.
5. `SpeechAnalyzer` en iOS 26+ como motor de dictado preferente (`SpeechListener` es el único punto de captura de audio y reconocimiento; habrá que extraer un protocolo para poder elegir motor).
6. Voz neuronal local (Kokoro vía MLX/Core ML) si la calidad de `AVSpeechSynthesizer` no basta.
7. Wake word dedicada (Porcupine u otra) solo si se acepta su licencia/AccessKey; sigue siendo solo en primer plano.
8. Widget / Control Center / Botón de Acción con App Intents adicionales.
9. Localización completa de cadenas (String Catalog).

## 4. Fuentes consultadas

- mlx-swift-lm (README, `Package.swift`, `ChatSession.swift`, `LLMModelFactory.swift`, macros de `MLXHuggingFace`): <https://github.com/ml-explore/mlx-swift-lm>
- Claude — App Intents, Atajos y widgets en iOS: <https://support.claude.com/en/articles/10263469-using-claude-app-intents-and-shortcuts-on-ios>
- Claude — abrir la app móvil con un enlace (`claude://`): <https://support.claude.com/de/articles/14898120-offnen-sie-die-claude-mobile-app-mit-einem-link>
- SpeechAnalyzer (artículos de terceros; no la documentación de Apple): <https://blog.addpipe.com/apple-speechanalyzer-api/>, <https://antongubarenko.substack.com/p/ios-26-speechanalyzer-guide>
- Foro de Apple — Qwen 1.7B en iPhone SE 3: <https://developer.apple.com/forums/thread/816847>
- Benchmark de LLM en iPhone 17 Pro (tamaños 4 bits): <https://hn.jakechampion.name/reader/https://rickytakkar.com/blog_russet_mlx_benchmark.html>
