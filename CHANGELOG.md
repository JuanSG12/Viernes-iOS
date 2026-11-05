# CHANGELOG

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/). Versionado semántico.

## [0.2.0] — 2026-11-05 — Primeras pruebas en iPhone 14 Pro Max (sin verificar aún en dispositivo)

### Por qué
Instalada por Sideloadly con un Apple ID gratuito, la primera prueba real mostró el límite del modelo local: Qwen3 1.7B en un iPhone con 6 GB de RAM y sin Apple Intelligence es lento, no conversa como una IA y no sabe nada en tiempo real. No se arregla con código; se ofrece otro cerebro, opcional.

### Añadido
- **Cerebro en la nube opcional** (`CloudEngine`, `CloudBrain.swift`): API de chat compatible con OpenAI con streaming, presets Groq y Google Gemini, solo HTTPS. La clave es del usuario, gratuita, y vive solo en el Llavero. Pantalla «Cerebro en la nube» con «Probar conexión» (lista los modelos reales de la clave, porque nombres y límites gratuitos cambian). **El texto de la conversación sale del teléfono** cuando está activo: documentado en SECURITY.md y en la pantalla.
- **Herramienta `get_weather`** (Open-Meteo, sin clave): respuesta redactada para voz, sin símbolos.
- **Voz neuronal opcional (ElevenLabs)** (`ElevenLabsVoiceView`, `CloudSpeech.swift`, cola en `SpeechSpeaker`): clave en el Llavero, lista de voces de la cuenta, muestra, interruptor, máximo 2 descargas simultáneas y **respaldo automático a la voz del sistema** si falla. Cada frase hablada sale del teléfono hacia ElevenLabs (no el audio del micrófono). Kokoro local se investigó y se descartó por ahora (ver VOICE.md). 6 pruebas nuevas del protocolo.
- La personalidad sabe si su cerebro es la nube (ya no dice «soy un modelo pequeño sin internet» ni se limita a ser un asistente de comandos).

### Cambiado
- Claude: el modo por defecto pasa de «desactivado» a «abrir la app de Claude». Con el modo desactivado, la herramienta `ask_claude` ni siquiera se ofrecía al modelo, por eso «pregúntale a Claude» no hacía nada. Quien ya tenía el ajuste guardado debe cambiarlo en Ajustes › Claude. Si está desactivado, Viernes lo dice.
- Ajustes guardados antes de esta versión siguen leyéndose (el campo nuevo es opcional; hay prueba).

### Pruebas
- 15 pruebas nuevas del núcleo (flujo SSE, cuerpo de petición, errores sin fugas de clave, presets solo HTTPS, ajustes antiguos, formato de clave, clima, validación de `get_weather`). Chequeo de tipos y comprobaciones estáticas pasan en Windows; **el CI de macOS aún no las ha ejecutado** y nada de esto se ha probado en el iPhone.

### No verificado
- Funcionamiento real con Groq/Gemini (límites del plan gratuito, nombres de modelo vigentes, latencia), voz con respuestas largas de la nube, y que «Abrir Claude» precargue la pregunta (el enlace `claude.ai/new?q=` puede abrirse en Safari).
- ElevenLabs: qué voces y qué acceso por API incluye hoy el plan gratuito (las fuentes se contradicen), calidad del español, latencia por frase y cuota real. La cola de reproducción (orden, interrupción, respaldo) nunca se ha ejecutado.
- La lentitud del modelo local no se midió: no hay medición de tokens/s en dispositivo.

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

### Primera ejecución del CI de macOS (Xcode 26.6, simulador iPhone 17 Pro, iOS 26.2)
- **Core**: `swift test` pasó (los jobs de la app solo arrancan si él pasa).
- **App iOS**: **compila** en ambas variantes, incluida la de MLX (mlx-swift-lm 3.32.3, mlx-swift 0.32.3, swift-huggingface 0.13.0, swift-transformers 1.4.0).
- **Pruebas unitarias**: 18 de 27 pasaron. Las 9 que fallaron lo hicieron por `unexpectedStatus(-34018)` del Keychain: la app se compiló sin firma y el simulador no concede Keychain a binarios sin firmar. Corrección: firma ad-hoc en el CI.
- **Pruebas de UI**: 7 de 11 pasaron. Fallos: (1) `send` ambiguo con la tecla «send» del teclado → id propio `send-message`; (2) botón «Borrar todo» fuera de pantalla en una lista perezosa → la prueba desplaza; (3) alta de memoria, que dependía del Keychain.
- **Defecto real encontrado por el CI**: al lanzar la app salía el aviso de permiso de micrófono sin haber usado la voz, porque `SpeechListener.teardown()` accedía a `inputNode`. Corregido: solo se toca si hubo un tap instalado.
- Las correcciones se aplicaron y se **re-verificaron** (ver siguiente sección).

### Segunda ejecución del CI (commit `102f897`) — todo en verde
- Los 4 jobs pasan: estáticas, Core, App iOS (no-mlx) y App iOS (full, con MLX). `xcodebuild test` termina sin fallos en ambas variantes (27 unitarias + 11 de UI en simulador iOS 26.2).
- La firma ad-hoc resolvió el Keychain (`-34018`); `send-message` y el scroll resolvieron las dos pruebas de UI; el aviso espurio de micrófono desapareció.
- Una ejecución previa en runner Intel (macos-26-intel) mostró un fallo intermitente de enfoque de teclado en `testMemoryRefusesSensitiveText`; las pruebas que escriben texto ahora reintentan el toque hasta que aparece el teclado.
- El CI ya no cancela ejecuciones en `main` y permite elegir runner (`macos-26` / `macos-26-intel`) al lanzarlo a mano, porque los runners arm64 de GitHub tuvieron falta de capacidad.
- Nota: las cifras se leen del estado de los jobs; el listado completo está en los artefactos `app-*-logs`.

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
