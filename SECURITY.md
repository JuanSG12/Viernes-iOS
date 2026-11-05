# SECURITY

Modelo de amenazas, controles implementados y límites. Nada de esto ha sido auditado por terceros ni probado en dispositivo todavía.

## Principios

1. **Local primero, nube solo si la activas**: no hay servidor de Viernes, cuentas, telemetría ni analítica. Por defecto todo corre en el teléfono. El **cerebro en la nube** (Groq / Gemini con TU clave gratuita) es opcional y, si lo activas, el texto de la conversación sale hacia ese proveedor (ver «Límites»).
2. **El audio no sale del teléfono por defecto** y nunca se guarda.
3. **El modelo no es de confianza**: todo lo que produce (llamadas de herramientas, URLs, fechas) se valida; lo sensible requiere confirmación humana.
4. **Lo externo no es de confianza**: enlaces `viernes://`, resultados de Atajos y texto de Claude son datos, no órdenes.
5. **Sin secretos en el código ni en UserDefaults**.

## Controles

| Riesgo | Control | Dónde |
|---|---|---|
| Fuga de memoria/historial desde disco o copia | AES-256-GCM por registro; clave aleatoria en Keychain `AfterFirstUnlockThisDeviceOnly` (no sale del dispositivo ni va a copias); almacén excluido de copias; protección de archivo del directorio | `Vault`, `KeychainStore`, `ViernesStore` |
| Borrado | Borrado por registro/total; «Borrar todos los datos» destruye la clave (borrado criptográfico) | `PrivacyView`, `AppModel.eraseAllData` |
| Guardar secretos por accidente | `SensitiveDataRedactor` rechaza tarjetas (Luhn), contraseñas dichas, claves/tokens y documentos; también en resúmenes y sugerencias; `ask_claude` se niega a enviarlos | `MemoryStore.remember`, `ToolValidator` |
| Memoria indiscriminada | Solo por orden explícita, alta manual o sugerencia aprobada; política por tipo; interruptor general; sugerencias desactivadas por defecto | `MemoryPolicy`, `ConversationEngine` |
| Herramienta maliciosa vía modelo/prompt-injection | Lista cerrada de herramientas; argumentos filtrados por esquema; límites de longitud; `open_url` solo https sin credenciales y con host con punto; `open_app` solo lista blanca; fechas validadas | `ToolValidator`, `AppLinkCatalog` |
| Acciones sin consentimiento | Herramientas `sensitive` muestran hoja con el detalle exacto; caduca a «rechazado» a los 90 s; sin proveedor de confirmación ⇒ no se ejecuta | `ConfirmationCenter`, `ConversationEngine.perform` |
| El modelo miente sobre lo hecho | La UI y el historial muestran `ActionRecord`, no el texto del modelo; el prompt exige esperar `[RESULTADO_HERRAMIENTA]` | `ConversationEngine`, `ActionChip` |
| Enlaces externos | `viernes://ask` solo precarga; `claude-result` requiere *nonce* vigente y único | `DeepLink`, `ClaudeCoordinator` |
| Inyección de parámetros en URLs de Atajos | Codificación manual estricta de cada valor | `ClaudeLinkBuilder` |
| Micrófono oculto | Sin `UIBackgroundModes`; sesión liberada al salir de primer plano; indicador visible («Micrófono abierto…») con wake word; wake word apagada por defecto | `AppModel.scenePhaseChanged`, `MainView` |
| Audio a servidores | `requiresOnDeviceRecognition = true` salvo opt-in «Permitir reconocimiento de Apple por internet» | `SpeechListener`, `ListeningSettingsView` |
| Calendario/recordatorios | Calendario: acceso **solo de escritura**; recordatorios: acceso completo solicitado al primer uso con explicación | `DeviceToolExecutor`, Info.plist |
| Pantalla de memoria | Face ID/código opcional (`LocalAuthentication`) | `MemoryView`, `Permissions` |
| Clave del proveedor en la nube | Solo en el Llavero (`AfterFirstUnlockThisDeviceOnly`), nunca en UserDefaults/código/registros; solo se envía por HTTPS a presets cerrados (no hay URL libre); formato validado; «Borrar todos los datos» la elimina; los mensajes de error no la incluyen | `CloudKeyStore`, `CloudBrain`, `CloudEngine` |
| Voz en la nube (ElevenLabs) | Opcional y apagada por defecto; clave solo en el Llavero; HTTPS a un único host fijo; el identificador de voz se valida (solo alfanumérico) porque va en la ruta de la URL; solo se envía el texto hablado, nunca el audio del micrófono; si falla, se usa la voz del sistema | `CloudVoice`, `ElevenLabsClient`, `SpeechSpeaker` |
| Claves de Anthropic | No existen; `static-check.ps1` y una prueba unitaria fallan si aparece `api.anthropic.com`, `x-api-key` o algo con forma `sk-ant-…` | `scripts/`, `SecurityTests` |

## Límites y riesgos residuales (honestos)

- **El filtro de datos sensibles es heurístico**: puede dejar pasar un secreto con formato raro y rechazar un texto inocente que contenga «clave es…».
- **Texto a Claude**: lo que se envía a la app de Claude sale del dispositivo y lo gobierna la política de Anthropic. Viernes pide confirmación y bloquea datos sensibles, pero no controla qué hace Claude después.
- **Descarga de modelos**: se hace con el cliente de Hugging Face de `mlx-swift-lm` (HTTPS). No se verifica una firma/hash propio del modelo más allá de lo que haga ese cliente. Los repos son de `mlx-community`; la cadena de suministro es la de terceros (Hugging Face, `mlx-swift-lm`, `swift-transformers`).
- **Macros de Swift**: `mlx-swift-lm` usa macros (swift-syntax); Xcode pedirá confiar en ellas. Revisa qué paquetes aceptas.
- **Prompt injection**: un modelo pequeño puede ser manipulado por texto adversarial (p. ej. pegado por el usuario) para *pedir* una herramienta. Las barreras (validación + confirmación) limitan el daño a lo que tú confirmes; las acciones «seguras» (abrir una app de la lista, consultar batería, listar recordatorios) no piden confirmación.
- **Recordatorios completos**: `list_reminders` lee tus recordatorios pendientes y los entrega al modelo activo. Con un modelo local no salen del teléfono; **con el cerebro en la nube sí salen** (igual que el resto de la conversación), y también si luego usas `ask_claude`. Revisa siempre la confirmación.
- **Cerebro en la nube (opcional)**: con él activo salen del teléfono tu mensaje, el historial reciente (hasta ≈14 000 caracteres), los recuerdos relevantes al mensaje (hasta 5) y los resultados de herramientas. No salen la memoria completa, la clave de cifrado ni el audio. El proveedor puede registrar esos datos; los planes gratuitos suelen permitirle usarlos para mejorar sus productos (revisa sus términos). El filtro de datos sensibles protege lo que se **guarda** y lo que va a Claude, pero **no filtra lo que dictas al cerebro en la nube**: no le digas contraseñas ni tarjetas.
- **Voz en la nube (opcional)**: con ElevenLabs activo, **cada frase que Viernes dice sale del teléfono** hacia ElevenLabs (puede incluir lo que respondió el modelo con datos de tu memoria o recordatorios). El plan gratuito está pensado para uso no comercial y su política de datos es la de ElevenLabs. Si no quieres que eso salga, déjalo apagado.
- **Clima**: `get_weather` envía a Open-Meteo (HTTPS, sin clave ni cuenta) el nombre de la ciudad y luego sus coordenadas. Es una herramienta «segura» (sin confirmación) porque no revela nada más que esa ciudad.
- **Dispositivo desbloqueado**: con el teléfono desbloqueado y la app abierta, quien lo use puede ver el historial. Face ID solo protege la pantalla de Memoria, no el historial.
- **Sin auditoría ni pruebas de penetración**. Sin protección anti-jailbreak.
- **Cumplimiento de exportación (cifrado)**: la app usa AES-GCM de CryptoKit para datos propios; revisa la declaración de cifrado de App Store Connect si distribuyes la app (`ITSAppUsesNonExemptEncryption`). No se ha declarado.

## Qué NO hace Viernes (y nunca debe hacer)

- Extraer credenciales, tokens o sesiones de Claude, interceptar tráfico o saltarse límites de uso.
- Controlar apps arbitrarias, leer la pantalla o usar APIs privadas.
- Escuchar con la app cerrada o el teléfono bloqueado.
- Enviar audio a servicios externos sin tu autorización explícita.

## Reportar un problema

Proyecto personal sin canal público. Si lo publicas, añade aquí un contacto de seguridad.
