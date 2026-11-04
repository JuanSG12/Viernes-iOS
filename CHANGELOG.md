# CHANGELOG

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/). Versionado semántico.

## [0.1.0] — 2026-11-04 — Primera versión (código completo, SIN compilar ni probar en iPhone)

### Añadido
- **Core portable** (`ViernesCore`, solo Foundation): motor de conversación con herramientas validadas y confirmadas, personalidad y reglas de honestidad, memoria con política y redacción de datos sensibles, recuperación léxica en español, filtro de etiquetas en streaming (`<think>`, `<tool>`), división de respuesta en frases para hablar, VAD por energía, detección de palabra de activación, ranking de voces, catálogo y recomendador de modelos, puente Claude, enlaces profundos.
- **App iOS** (SwiftUI, iOS 18+): núcleo holográfico (Canvas, 8–30 fps), pantalla principal, conversación con chips de acciones reales, historial, memoria (CRUD, fijar, sugerencias por aprobar, Face ID opcional), configuración, selección de modelo (descarga explícita), selección de voz con ajustes, Claude, escucha/activación, privacidad, permisos, ayuda de Siri y onboarding.
- **Cerebros locales**: Apple Intelligence (`FoundationModels`, iOS 26+) y modelos MLX (Qwen3 1.7B/4B, Gemma 3 1B QAT, Llama 3.2 3B) intercambiables.
- **Voz**: dictado en el dispositivo (`SFSpeechRecognizer`), síntesis `AVSpeechSynthesizer` con selección automática de la mejor voz en español, habla frase a frase durante la generación, interrupción.
- **Activación**: botón/núcleo, palabra «Viernes» solo en primer plano (opt-in, indicador), Siri/Atajos (App Intents: abrir, hablar, preguntar), enlaces `viernes://`.
- **Herramientas**: abrir apps (lista blanca), abrir enlaces https, recordatorios (crear/listar/completar), eventos (solo escritura), Atajos, información del dispositivo, memoria local.
- **Claude por vías oficiales**: abrir la app o Atajo «Ask Claude» con retorno por x-callback y *nonce*; sin API ni credenciales.
- **Seguridad**: cifrado AES-256-GCM en reposo con clave en Keychain, borrado criptográfico, almacén excluido de copias, validación estricta de herramientas, confirmaciones, política de memoria, sin modos de fondo.
- **Pruebas**: 112 declaradas (core: memoria, conversación, herramientas, seguridad, voz, modelos; iOS: Keychain/Vault/SwiftData/persistencia, integración; UI: 11 flujos con XCUITest).
- **Herramientas de verificación**: `scripts/static-check.ps1` (+ autoprueba), generador de icono, CI de macOS (`.github/workflows/ci.yml`).
- **Documentación**: README, PLAN, ARCHITECTURE, SECURITY, INSTALL, VOICE, CLAUDE_INTEGRATION, LOCAL_MODELS, CHANGELOG.

### Verificado
- Comprobaciones estáticas en Windows: delimitadores y cadenas balanceados en todos los archivos Swift; el core solo importa Foundation; sin claves/endpoints de Anthropic ni `UIBackgroundModes`; cada herramienta del catálogo tiene implementación y viceversa; los identificadores de las pruebas de UI existen en la app; los 9 documentos existen.

- **Compilador real (Swift 6.4.2 para Windows, Visual Studio Build Tools)**: `ViernesCore` (22 archivos) compila y los 6 archivos de pruebas del core pasan el chequeo de tipos con XCTest (`scripts/typecheck-windows.ps1`). Se comprobó que el chequeo detecta errores deliberados.
- **CI de GitHub listo** (nunca ejecutado): jobs `static`, `core` y `app` en dos variantes (`no-mlx` / `full`) para aislar fallos de `MLXEngine.swift`; logs y `.xcresult` como artefactos; repositorio git local con el primer commit.
- **Dos revisiones independientes de lectura** (core y app) aplicadas: manifiesto `Package.swift` (`.iOS("18.0")`), URLs solo ASCII, falsos positivos del filtro de sensibles y de la raíz de palabras, pausas de voz, carreras entre sesiones de reconocimiento y de síntesis, cancelación de confirmaciones, ciclo de vida (`inactive` ya no cancela respuestas), orden de arranque con Siri, bloqueo inicial de Memoria con Face ID, aislamiento de la clave de pruebas, ajustes de pruebas de UI.

### No verificado (pendiente)
- **Ejecutar** las pruebas: en este equipo Defender (política administrada, evento 1121) bloquea ejecutar cualquier `.exe` nuevo, así que `swift test` no puede correr. Se ejecutarán en un Mac o con el CI incluido.
- Compilación con Xcode 26 (en especial `MLXEngine.swift` y aislamiento de concurrencia en los puentes de audio).
- Ejecución de las 112 pruebas.
- Todo lo que requiere iPhone: voz, Siri, wake word, rendimiento y memoria de los modelos, batería, Apple Intelligence, comportamiento real de «Ask Claude» y de los enlaces de Claude.

### Limitaciones conocidas
- La palabra «Viernes» no funciona con la app cerrada ni el teléfono bloqueado (restricción de iOS).
- Recuperación de memoria léxica (sin sinónimos).
- `SpeechAnalyzer` (iOS 26) y voz neuronal local (Kokoro) no incluidos.
- El historial no está protegido por Face ID (solo la pantalla de Memoria).
- Cadenas de interfaz solo en español.
