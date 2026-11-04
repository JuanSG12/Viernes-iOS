# ARCHITECTURE

## Vista general

```
┌────────────────────────────── App iOS (App/Viernes) ──────────────────────────────┐
│  UI (SwiftUI)        HoloCoreView · MainView · Conversation · Settings · Memory …  │
│        │ @EnvironmentObject                                                         │
│  AppModel (@MainActor, ObservableObject)  ← estado único; orquesta todo            │
│     │        │            │             │              │                           │
│  Voice     Engines    Persistence    Tools         Intents                          │
│  SpeechListener  FoundationModelsEngine  SwiftDataMemoryStore  DeviceToolExecutor  IntentBridge
│  SpeechSpeaker   MLXEngine               ConversationRepository ConfirmationCenter  ViernesShortcuts
│  Permissions     UnavailableEngine       Vault + KeychainStore  ClaudeCoordinator
└───────────────────────────────┬────────────────────────────────────────────────────┘
                                │ protocolos: LanguageModelEngine · MemoryStore · ToolExecutor · ConfirmationProvider
┌───────────────────────────────▼────── ViernesCore (Foundation puro) ─────────────────┐
│ ConversationEngine (actor) ── Persona · MemoryRetriever · ToolValidator · StreamingTagFilter
│ MemoryModels/Policy · SensitiveDataRedactor · ModelCatalog/Recommender · ClaudeBridge  │
│ WakeWordMatcher · SilenceDetector · SpeechText · SentenceStreamer · VoiceRanker · DeepLink
└────────────────────────────────────────────────────────────────────────────────────────┘
```

**Regla de dependencias**: `ViernesCore` no importa nada salvo Foundation (lo verifica `scripts/static-check.ps1`). La app depende del core, nunca al revés. Todo lo que toca hardware o frameworks de Apple está detrás de un protocolo del core.

## Flujo de un turno de conversación

1. **Entrada**: voz (`SpeechListener` → texto final) o teclado/Siri → `AppModel.submit`.
2. `ConversationEngine.send` (actor):
   1. ¿Orden de memoria («recuerda que…», «olvida…»)? → se ejecuta (política + filtro de sensibles; olvidar pide confirmación) y su resultado se añade al turno del usuario como `[RESULTADO_HERRAMIENTA]`.
   2. Recupera recuerdos relevantes (`MemoryRetriever`; los pendientes nunca entran).
   3. Construye el *system prompt* (`Persona`): identidad, honestidad, fecha, **solo las herramientas realmente disponibles**, recuerdos etiquetados.
   4. Aplana el historial a turnos alternados user/assistant dentro de un presupuesto de caracteres (`turns(from:budget:)`; Gemma exige alternancia estricta).
   5. Llama al motor (`LanguageModelEngine.generate`, deltas) y filtra en streaming `<think>…</think>` y `<tool>…</tool>` (`StreamingTagFilter`, invariante al troceado).
   6. Cada llamada de herramienta: `ToolCallParser` → `ToolValidator` → ¿disponible? → ¿sensible? → `ConfirmationProvider` → ejecutor → `ActionRecord` (éxito / rechazada / falló).
   7. Si hubo herramientas, el modelo recibe el **resultado real** y redacta la respuesta (máx. 3 rondas).
3. **Salida**: los deltas visibles alimentan la UI y `SentenceStreamer` → `SpeechSpeaker` (habla frase a frase). `ChatMessage.actions` contiene lo que realmente ocurrió; la UI muestra eso, no lo que el modelo afirme.
4. **Persistencia**: transcripción cifrada si la retención lo permite.

## Decisiones clave

- **Honestidad por construcción**: el modelo no puede "hacer" nada; solo puede pedir una herramienta. El texto «Ya lo hice» no cambia el `ActionRecord`. Si el motor no está disponible, `UnavailableEngine` falla con motivo en vez de simular.
- **Dos cerebros tras un protocolo**: `FoundationModelsEngine` (`#if canImport(FoundationModels)` + `@available(iOS 26)`) y `MLXEngine` (`#if canImport(MLXLLM)`). Añadir un modelo = una entrada en `ModelCatalog`.
- **Cifrado en reposo**: `Vault` (AES-256-GCM, clave aleatoria en Keychain `AfterFirstUnlockThisDeviceOnly`). SwiftData guarda `id + fecha + blob`; la búsqueda ocurre en RAM. Borrar la clave = borrado criptográfico.
- **Ciclo de vida sin fondo**: al salir de primer plano se libera el micrófono, se cancela la generación (iOS termina apps que lanzan trabajo de GPU/Metal en segundo plano, y MLX usa Metal) y se detiene la voz.
- **Enlaces externos no confiables**: `viernes://ask` solo precarga texto; `viernes://claude-result` exige el *nonce* de una petición pendiente y vigente (10 min).
- **Energía**: el núcleo usa `TimelineView` con `minimumInterval` según estado (8 fps en espera, 30 con actividad, pausado fuera de primer plano), respeta *Reducir movimiento* y el ajuste «Efectos reducidos».
- **Concurrencia**: Swift 5 language mode. Los bloques que llama el hilo de audio o el reconocedor se crean en funciones `nonisolated static` y saltan a `@MainActor` con `Task`, para no heredar aislamiento que dispararía comprobaciones en tiempo de ejecución.

## Mapa de archivos

| Carpeta | Archivos clave |
|---|---|
| `Sources/ViernesCore` | `ConversationEngine`, `Persona`, `Tools`, `ToolValidator`, `MemoryModels`, `MemoryRetriever`, `SensitiveDataRedactor`, `ModelCatalog`, `ClaudeBridge`, `DeepLink`, `WakeWordMatcher`, `SilenceDetector`, `SpeechText`, `SentenceStreamer`, `VoiceSelection`, `AppSettings`, `StreamingTagFilter`, `Summarizer` |
| `App/Viernes/Model` | `AppModel`, `SettingsStore` (+ `ModelStorage`) |
| `App/Viernes/Voice` | `SpeechListener`, `SpeechSpeaker`, `AudioSessionController`, `Permissions` |
| `App/Viernes/Engines` | `FoundationModelsEngine`, `MLXEngine`, `EngineProvider`, `UnavailableEngine` |
| `App/Viernes/Persistence` | `Records`, `SwiftDataMemoryStore` (+ `ConversationRepository`) |
| `App/Viernes/Security` | `KeychainStore`, `Vault` |
| `App/Viernes/Tools` | `DeviceToolExecutor`, `ConfirmationCenter`, `ClaudeCoordinator` |
| `App/Viernes/Intents` | `ViernesIntents` (App Intents + `IntentBridge`) |
| `App/Viernes/UI` | `HoloCoreView`, `MainView`, `ConversationView`, `SettingsView` y subpantallas, `MemoryView`, `HistoryView`, `ConfirmationSheet`, `OnboardingView` |

## Límites conocidos de la arquitectura

- Un solo `SpeechListener`: wake word y comando comparten sesión (al oír «Viernes» se promueve a comando sin perder audio). Cambiar de motor de dictado exigirá extraer un protocolo.
- La recuperación de memoria es léxica (sin embeddings): predecible y auditable, pero no encuentra sinónimos.
- El historial se aplana a texto para el modelo del sistema (cada petición es independiente); no se usa `Transcript` nativo.
- `SpeechSpeaker` puede recibir `didCancel` tardíos tras `stop()`; hay una guarda (`cancelling`) pero no un contador de generación.
