# Viernes — asistente personal nativa para iPhone

Viernes es una asistente de voz **nativa de iOS** (Swift + SwiftUI) con cerebro de IA **local**, memoria cifrada en el dispositivo, voz en español, integración con Siri/Atajos y una interfaz holográfica. Es una identidad original: no imita a ningún personaje ni su voz.

> **Estado: v0.1.0 — código completo, sin compilar ni probar en iPhone.**
> Se desarrolló en Windows, donde no existe Xcode ni el SDK de iOS. El **core** (lógica + pruebas) ya pasa el compilador de Swift; la **app iOS** no se ha compilado (necesita un Mac) y **ninguna prueba se ha ejecutado**. Lee [Estado real](#estado-real) antes de asumir nada.

## Qué es y qué no es

| Es | No es |
|---|---|
| App nativa de iPhone (iOS 18+; Apple Intelligence con iOS 26+) | PWA, servidor Windows ni nada que dependa de un PC encendido |
| IA local: modelo del sistema (Apple) o modelos MLX cuantizados | Un cliente de la API de Anthropic (no hay claves ni endpoints) |
| Memoria y historial cifrados (AES-256-GCM, clave en Keychain) | Un servicio en la nube con cuentas |
| Voz: dictado y síntesis del sistema, en el dispositivo | Escucha permanente con la app cerrada (iOS no lo permite) |
| Siri/Atajos vía App Intents | Un reemplazo de Siri |

## Capacidades

- **Conversación por voz o texto**, respuestas habladas frase a frase mientras se generan (menor latencia).
- **Cerebro intercambiable** ([LOCAL_MODELS.md](LOCAL_MODELS.md)): Apple Intelligence (sin descarga) o Qwen3 / Gemma 3 / Llama 3.2 en MLX. Si el modelo es limitado o no está disponible, lo dice; nunca inventa respuestas.
- **Personalidad** consistente (español colombiano neutro, ingeniosa con sarcasmo sutil) y un prompt que separa *recuerdo / lo dicho en la conversación / suposición / acción realizada*.
- **Memoria**: guardar, buscar, editar, fijar y borrar recuerdos; política configurable por tipo; sugerencias solo con tu aprobación; datos sensibles rechazados siempre.
- **Herramientas de iOS** (todas validadas; las sensibles piden confirmación): abrir apps de una lista blanca, abrir enlaces https, crear/listar/completar recordatorios, crear eventos (acceso solo de escritura), ejecutar Atajos, consultar batería/almacenamiento/hora, memoria local.
- **Activación**: botón/núcleo, palabra «Viernes» **solo con la app abierta**, Siri («Habla con Viernes»), Atajos, enlaces `viernes://`.
- **Claude por vías oficiales** ([CLAUDE_INTEGRATION.md](CLAUDE_INTEGRATION.md)): abrir la app de Claude o un Atajo tuyo con «Ask Claude». La UI nunca afirma que Claude está integrado cuando solo se abrió su app.
- **Interfaz holográfica** (Canvas de SwiftUI, 8–30 fps según el estado, 0 fps en segundo plano): estados escucha / pensamiento / respuesta / espera / error / sin cerebro.

## Estado real

| Área | Escrito | Verificado |
|---|---|---|
| Lógica portable (`Sources/ViernesCore`: memoria, herramientas, conversación, política, VAD, wake word…) | ✅ | ✅ **compila y sus pruebas pasan el chequeo de tipos** con Swift 6.4.2 (Windows, `scripts/typecheck-windows.ps1`) · ⚠️ las pruebas **no se han ejecutado**: Defender (política de TI) bloquea ejecutar `.exe` recién compilados, así que `swift test` no corre aquí |
| App iOS (SwiftUI, SwiftData cifrado, voz, Siri, herramientas) | ✅ | ❌ no compilada |
| Motor MLX (`MLXEngine.swift`) | ✅ | ❌ **mayor riesgo de compilación**; escrito contra la API de mlx-swift-lm 3.32.x sin compilador |
| Motor Apple Intelligence | ✅ | ❌ no compilado ni probado en dispositivo |
| Comprobaciones estáticas (`scripts/static-check.ps1`) | ✅ | ✅ ejecutadas en Windows: delimitadores balanceados en 67 archivos, core solo con Foundation, sin claves/endpoints de Anthropic, herramientas ↔ ejecutor, IDs de UI ↔ código, documentación |
| Pruebas en iPhone físico (voz, Siri, wake word, rendimiento de modelos, batería) | — | ❌ pendientes (lista en [INSTALL.md](INSTALL.md#pruebas-que-requieren-iphone-físico)) |

**Lo que no se puede garantizar todavía**: que compile a la primera, que cada modelo quepa en tu iPhone, que «Ask Claude» devuelva texto a un Atajo, ni la calidad real de la voz o del reconocimiento. Está documentado dónde mirar.

## Inicio rápido (en un Mac)

```bash
brew install xcodegen
xcodegen generate                 # crea Viernes.xcodeproj desde project.yml
open Viernes.xcodeproj            # Signing: pon tu Team y cambia el Bundle ID
swift test                        # pruebas del core (rápido, sin simulador)
```

Detalle completo, requisitos y solución de problemas: [INSTALL.md](INSTALL.md).

## Estructura

```
Sources/ViernesCore/   lógica pura (solo Foundation) — portable y comprobable con `swift test`
Tests/ViernesCoreTests pruebas del core
App/Viernes/           app iOS: UI, Voice, Engines, Persistence, Security, Tools, Intents
App/ViernesTests/      pruebas que necesitan iOS (Keychain, SwiftData, voz, integración)
App/ViernesUITests/    pruebas de interfaz (XCUITest)
scripts/               static-check.ps1, make-icon.ps1
project.yml            definición del proyecto Xcode (XcodeGen)
```

## Documentación

[PLAN](PLAN.md) · [ARCHITECTURE](ARCHITECTURE.md) · [SECURITY](SECURITY.md) · [INSTALL](INSTALL.md) · [VOICE](VOICE.md) · [CLAUDE_INTEGRATION](CLAUDE_INTEGRATION.md) · [LOCAL_MODELS](LOCAL_MODELS.md) · [CHANGELOG](CHANGELOG.md)

## Licencia

Sin licencia declarada todavía (decisión del propietario). Los modelos tienen licencias propias: ver [LOCAL_MODELS.md](LOCAL_MODELS.md).
