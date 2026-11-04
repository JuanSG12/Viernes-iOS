# INSTALL

## Requisitos (obligatorios)

| Requisito | Detalle |
|---|---|
| **Un Mac** | Compilar una app iOS **no es posible desde Windows** (hace falta Xcode y el SDK de iOS, solo para macOS). Alternativas sin Mac propio: alquilar un Mac en la nube o usar CI de macOS (GitHub Actions, incluido en este repo). Aun así, para instalarla en tu iPhone necesitas firmar con tu Apple ID desde Xcode en un Mac. |
| **Xcode 26 o superior** | `mlx-swift-lm` usa `swift-tools-version: 6.2`. El modelo Apple Intelligence necesita el SDK de iOS 26. |
| **iPhone con iOS 18+** | Mínimo del proyecto: 18.0 (Atajos «Ask Claude» ≥ iOS 18; SwiftData ≥ 17). Apple Intelligence: iOS 26+ y un iPhone compatible. Recomendado: ≥ 6 GB de RAM para modelos MLX. |
| **Apple ID** | Gratis basta para instalar en tu propio iPhone (el perfil caduca a los 7 días). Cuenta de pago para TestFlight/App Store y certificados duraderos. |
| **XcodeGen** | `brew install xcodegen` |
| **Internet (solo para descargar un modelo)** | El modelo del sistema no necesita descarga. Los modelos MLX se descargan una vez desde Hugging Face. |

## Compilar y ejecutar

```bash
git clone <tu-repo> Viernes && cd Viernes
brew install xcodegen
xcodegen generate
open Viernes.xcodeproj
```

En Xcode:

1. Selecciona el target **Viernes → Signing & Capabilities** y elige tu **Team**.
2. Cambia el **Bundle Identifier** (`com.example.viernes`) por uno tuyo. Hazlo también en `project.yml` (`bundleIdPrefix`, `PRODUCT_BUNDLE_IDENTIFIER`) si regeneras el proyecto.
3. **Entitlement `increased-memory-limit`**: está en `App/Viernes/Viernes.entitlements` para que iOS permita más RAM a los modelos. Si tu cuenta no puede firmarlo, elimina esa clave de `project.yml` y del archivo; verás más cierres por memoria con modelos de >1 GB.
4. Primera resolución de paquetes: Xcode descargará `mlx-swift-lm`, `swift-huggingface`, `swift-transformers` y `swift-syntax`. **Confía en los macros** cuando lo pida (o usa `-skipMacroValidation` en CI).
5. Conecta tu iPhone → *Run*. La primera vez: Ajustes › General › VPN y gestión de dispositivos › confiar en tu perfil. En iOS 16+ activa **Modo desarrollador** (Ajustes › Privacidad y seguridad).
6. En la app: onboarding → pulsa el núcleo (te pedirá micrófono y reconocimiento de voz) → **Configuración › Modelo local**:
   - Si ves *Apple Intelligence* como disponible: listo, sin descarga.
   - Si no: elige un modelo MLX → «Descargar y cargar».

> El simulador sirve para UI, memoria y pruebas. **Micrófono, voces premium, Siri real y el rendimiento de los modelos requieren iPhone físico.** MLX usa Metal y puede no funcionar o ir muy lento en el simulador.

### Probar sin abrir Xcode (Mac)

```bash
swift test                                                       # core: memoria, herramientas, conversación, seguridad…
xcodebuild test -project Viernes.xcodeproj -scheme Viernes \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipMacroValidation                                           # pruebas de iOS + UI
```

(Ajusta el nombre del simulador al que tengas: `xcrun simctl list devices available`.)

### Desde Windows (lo que sí se puede)

```powershell
pwsh scripts/static-check.ps1       # comprobaciones estáticas (no compila)
pwsh scripts/test-static-check.ps1  # autoprueba del lexer del verificador
pwsh scripts/typecheck-windows.ps1  # compila el core y chequea los tipos de sus pruebas con el compilador real
```

`typecheck-windows.ps1` requiere el toolchain de Swift para Windows (`winget install Swift.Toolchain`) y las Visual Studio 2022 Build Tools con la carga de trabajo de C++ y el Windows SDK. Usa `scripts/swift-windows.cmd`, que carga el entorno de Visual Studio y `SDKROOT`.

**Limitación**: `swift build` y `swift test` necesitan *ejecutar* binarios recién compilados (SwiftPM ejecuta el manifiesto; las pruebas son un `.exe`). Si tu equipo tiene reglas ASR/AppLocker de Defender que lo impiden (síntoma: «Acceso denegado» al correr cualquier `.exe` nuevo, evento 1121), solo podrás chequear tipos; ejecuta las pruebas en un Mac o en el CI.

## Configuración posterior

- **Voz mejor**: Ajustes de iOS › Accesibilidad › Contenido hablado › Voces › Español → descarga una voz *Mejorada* o *Premium* (p. ej. las de es-MX/es-CO). Luego, en Viernes › Voz y habla, déjala en «Automática» o elígela.
- **Dictado local**: Ajustes › General › Teclado › Dictado → activa el español. Si falta, Viernes te lo dirá (no usa internet sin tu permiso).
- **Siri y Atajos**: ver [VOICE.md](VOICE.md#siri-y-atajos).
- **Claude**: ver [CLAUDE_INTEGRATION.md](CLAUDE_INTEGRATION.md).
- **Idioma de reconocimiento**: Viernes › Escucha y activación.

## Solución de problemas

| Síntoma | Causa probable / acción |
|---|---|
| Error de compilación en `MLXEngine.swift` | Es el archivo más expuesto a cambios de API de `mlx-swift-lm`. Compara con su README (`ChatSession`, `ModelConfiguration`, macro `#huggingFaceLoadModelContainer`). Puedes excluir temporalmente los productos MLX de `project.yml`: la app compila con `#if canImport(MLXLLM)` y funciona solo con Apple Intelligence. |
| «No such module FoundationModels» | Xcode < 26. Actualiza; el código está protegido con `#if canImport`, así que compila sin él pero no habrá Apple Intelligence. |
| La app se cierra al cargar un modelo | Memoria insuficiente: elige uno más ligero (Gemma 3 1B), conserva el entitlement `increased-memory-limit`, cierra otras apps. |
| «No hay reconocimiento de voz en el dispositivo» | Descarga el dictado de español (ver arriba) o activa a conciencia el reconocimiento de Apple por internet. |
| No se oye la voz | Silencio/volumen del iPhone; comprueba la ruta de audio. Viernes usa `playAndRecord` con altavoz por defecto. |
| Siri no reconoce «abre Viernes» | Siri abre apps por nombre pero «viernes» es también un día; usa «Habla con Viernes» o crea tu propio atajo. |
| La palabra «Viernes» no se activa | Solo funciona con la app abierta, ajuste activado y permisos concedidos; busca el punto rojo «Micrófono abierto…». |

## Pruebas que requieren iPhone físico

Marca cada una al probarla (ninguna se ha ejecutado todavía):

- [ ] **Voz entrada**: dictado en español colombiano, ruido ambiente, fin de frase por silencio (1,3 s), cancelación, permisos denegados → mensaje claro.
- [ ] **Dictado en el dispositivo**: modo avión activado, la transcripción sigue funcionando.
- [ ] **Voz salida**: calidad de voces Estándar/Mejorada/Premium; velocidad, pausas, interrupción con toque; audio por altavoz y por AirPods.
- [ ] **Wake word**: «Viernes», «Oye Viernes, …» con la app abierta; falsos positivos en una conversación normal; indicador visible; **consumo de batería** durante 30 min; se detiene al bloquear/salir.
- [ ] **Siri**: «Habla con Viernes», «Abre Viernes», «Pregunta a Viernes»; con el teléfono bloqueado (pide desbloqueo).
- [ ] **Modelos**: descarga con Wi-Fi, carga en memoria, **tokens/s**, calor, memoria máxima y cierres en tu modelo de iPhone para cada modelo del catálogo; recarga sin internet tras descargar.
- [ ] **Apple Intelligence**: disponibilidad/estados, calidad en español, guardarraíles.
- [ ] **Herramientas**: crear recordatorio/evento (con y sin permiso), listar/completar recordatorios, abrir apps instaladas y no instaladas, ejecutar un Atajo, `device_info`.
- [ ] **Claude**: modo «Abrir app» (¿se precarga la pregunta?), modo «Atajo» con «Ask Claude» (¿vuelve texto por x-callback?).
- [ ] **Seguridad**: Face ID en Memoria, borrado total, comportamiento tras reiniciar y desbloquear por primera vez, restaurar sin clave (datos ilegibles → aviso).
- [ ] **Segundo plano**: el micrófono se libera y la generación se cancela al salir de la app sin cierres.
- [ ] **Accesibilidad**: VoiceOver en pantalla principal, *Reducir movimiento*, tamaños de texto grandes.
