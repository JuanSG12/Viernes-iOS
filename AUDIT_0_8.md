# AUDIT_0_8 — diagnóstico técnico de Viernes 0.7.0 (fase A de 0.8)

Fecha: 2026-11-11. Base: commit `bf02820` (0.7.0; CI verde en `3d5ffb5`: estáticas, núcleo, app sin MLX y completa, ≈ 450 pruebas; IPA compilado). **Todo lo que sigue se obtuvo leyendo el código y la documentación oficial, no ejecutando la app en un iPhone.** Cada hallazgo dice si está *verificado* (leído en el código o en una fuente oficial) o es una *hipótesis* (hay que confirmarla en el teléfono).

Niveles de prueba que se distinguirán en cada fase: **unitaria** (núcleo, CI), **integración** (núcleo con dobles de prueba, CI), **simulador** (app, CI), **dispositivo real** (solo la hace el usuario; no se puede dar por resuelto sin ella).

## Prioridades

| # | Área | Gravedad | Resumen |
|---|---|---|---|
| P0 | Contactos y WhatsApp | alta, falla a diario | Cuatro causas probables, tres verificadas en el código (abajo) |
| P0 | Un solo proveedor útil | alta | Solo Groq y Gemini; sin registro de consumo, sin presupuesto, sin OpenAI/Cerebras |
| P0 | Voz | alta, **no medible desde aquí** | La cadena de audio nunca se midió en un iPhone; hay que instrumentar y comparar en el dispositivo |
| P1 | Agente | media | Bucle de herramientas de una sola pasada (hasta 4 rondas); sin plan, dependencias ni persistencia |
| P1 | Investigación web | media | No existe ninguna herramienta web |
| P2 | Memoria | media | Memoria plana (preferencia/proyecto/dato/resumen); sin relaciones, caducidad ni tipos episódicos |
| P2 | Companion Windows, domótica | baja (nuevo) | Nada existe; se diseña como prueba de concepto segura |
| P2 | Comercial | baja (nuevo) | Ya hay perfiles y exportación; falta documentar backend, suscripciones y costos |

## P0 — Contactos y WhatsApp

Código: `App/Viernes/Tools/DeviceToolExecutor.swift` (`findContact`, `composeMessage`, `callPhone`), `Sources/ViernesCore/ToolValidator.swift` (`ContactFormat.normalizedPhone`), `Persona.swift`, `PrivacyView`.

1. **(verificado) La búsqueda de contactos está apagada por defecto.** `find_contact` solo se ofrece al modelo si el usuario activó «Permitir que Viernes lea mis contactos» (`contactsReadEnabled`, apagado de fábrica). Sin ese interruptor, el prompt le dice al modelo que no puede buscar contactos, y este le pide el número al usuario. Es la causa más probable de «me obliga a darle el número».
2. **(verificado) El número no lleva código de país.** `normalizedPhone("310 555 1234")` devuelve `3105551234`. El formato documentado por WhatsApp exige el número completo en formato internacional, sin ceros, paréntesis ni guiones. Con un número local, WhatsApp no resuelve el chat: se abre sin conversación y sin el texto. Falta un código de país por defecto (el de la región del perfil) y una normalización E.164.
3. **(verificado) Resolver el contacto depende de que el modelo encadene dos herramientas** (`find_contact` → `compose_message` con el número copiado del texto). Un modelo pequeño o un 429 a mitad rompe la cadena; no hay desambiguación estructurada (las coincidencias múltiples son solo texto) ni resolución determinista en código.
4. **(verificado en la documentación oficial) El formato del enlace.** La página oficial de WhatsApp «click to chat» documenta `https://wa.me/<número>?text=<texto codificado>` (número internacional completo; el texto aparece precargado en el campo de mensaje). No documenta `whatsapp://send?phone=…`, que es lo que usa hoy el código: funciona en la práctica pero no está respaldado por esa página. La documentación consultada **no dice** si el usuario debe pulsar Enviar (en la práctica sí: el enlace solo precarga el texto), así que Viernes nunca debe afirmar que se envió.
5. **(hipótesis, a confirmar en el iPhone)** Si WhatsApp no está instalada, `UIApplication.open` de un enlace `whatsapp://` falla; con `wa.me` abre Safari. Usar `open(_:options: [.universalLinksOnly: true])` permite saber de verdad si hay una app que abra el enlace y avisar en vez de abrir una página web.
6. **(verificado) Búsqueda limitada**: solo `predicateForContacts(matchingName:)` y, si no hay resultados, apodo/organización con coincidencia exacta de raíces; sin tolerancia a errores de dictado («Caren»/«Karen») ni a acentos en el nombre; solo se muestran 5 coincidencias; no distingue números móviles de fijos ni de trabajo.
7. **(verificado) Acceso limitado de iOS 18**: ya se trata como autorizado (`default:`), pero no hay forma de que el usuario amplíe la selección ni mensaje específico («iOS solo comparte N contactos con Viernes»). En iOS 18 `authorizationStatus` puede devolver `.limited`; hoy cae en `default`.

**Plan (fase C)**: `ContactResolver` en el núcleo (puro y probado: normalización, coincidencia aproximada, ranking, desambiguación) + `ContactDirectory` en la app (CNContactStore, estados de permiso incluido `.limited`); una sola ruta de resolución para WhatsApp, SMS, llamadas, correo y búsqueda de personas; `compose_message`/`call_phone`/`compose_email` aceptan un nombre y se resuelven en código; ambigüedad → hoja con opciones; enlaces `wa.me` con número E.164 y texto codificado; detección real de WhatsApp; el resultado dice solo lo comprobable. Criterios de aceptación y pruebas en la propia fase.

## P0 — Multi-Brain, consumo y presupuesto

Código: `LanguageModelEngine` (protocolo), `CloudBrain.swift` (presets, protocolo OpenAI, 429), `App/Viernes/Engines/CloudEngine.swift`, `CloudBrainView`.

- **(verificado) El protocolo `LanguageModelEngine` es suficiente y no necesita cambiar**: `generate` emite deltas, `availability/prepare/unload` cubren local y nube. Se mantiene.
- **(verificado) Solo hay dos presets** (Groq, Gemini), ambos con API compatible con OpenAI. OpenAI y Cerebras también usan el formato `/chat/completions`, así que son presets nuevos, no motores nuevos. Hay selección de proveedor y de modelo, «Probar conexión», lista de modelos (`parseModelIDs`) y manejo de 429 con `retry-after`.
- **(verificado) No hay registro de consumo**: la petición no pide `stream_options.include_usage` y no se lee el campo `usage` de la respuesta; no existen precios, presupuesto, alertas, historial ni lista de proveedores autorizados.
- **(verificado) Nada se cambia solo de proveedor** (regla ya cumplida por el enrutador de adjuntos); se mantendrá.
- **Límites**: los límites y cuotas solo pueden mostrarse cuando el proveedor los informa en cabeceras (`x-ratelimit-*`, `retry-after`); no se inventarán. Los **precios** por modelo cambian: irán en una tabla editable y fechada, marcada «estimación con tarifas que escribió el usuario o que trae la app con fecha»; el costo real lo manda la factura del proveedor.
- **Plan (fase B)**: presets OpenAI y Cerebras (URL fija HTTPS, la clave nunca va a una URL libre); `UsageLedger` (núcleo, cifrado por perfil) que registra tokens de entrada/salida, proveedor, modelo y fecha usando los datos reales del proveedor (y, si no los da, una estimación marcada como tal); `PriceBook` editable; presupuesto mensual por perfil (5/10/20 USD u otro) con alerta al 80 % y bloqueo duro de solicitudes **de pago** al llegar al límite, con explicación; los proveedores gratuitos (sin costo medible) no cuentan; lista de proveedores autorizados; pantalla de consumo. Groq sigue disponible y opcional.

## P0 — Voz

Código: fase 1 (0.7): `SpeechSegmenter`, `VoiceTurnLedger`, `ElevenLabsRealtime` (WebSocket `eleven_flash_v2_5`, `pcm_24000`), `RealtimePCMPlayer` (`AVAudioEngine` + `AVAudioPlayerNode` con buffers), respaldo a `AVSpeechSynthesizer`, métricas.

- **(verificado) Ya existe una cola de audio continua con buffers** (no un archivo por frase) cuando se usa ElevenLabs en tiempo real. No se reconstruirá.
- **(hipótesis, la más probable de «suena artificial y se traba»)** Cuando ElevenLabs está apagado, sin clave, sin cuota o falla, el habla cae a la **voz del sistema** (`AVSpeechSynthesizer`), que habla frase por frase con pausas y suena sintética. Las métricas de «Rendimiento de la voz» muestran qué *backend* habló cada turno; **hay que mirarlas en el iPhone antes de cambiar nada**.
- **(verificado) Nunca se midió en un dispositivo real.** Desde aquí no se puede medir latencia, cortes, memoria ni red: lo único posible es dejar un **banco de pruebas dentro de la app** (mismas frases, mismas condiciones, por proveedor) que el usuario ejecute en su iPhone, y comparar con esos números. Hasta tener resultados no se cambia de proveedor (regla de la propia especificación).
- **Plan (fase D)**: banco comparativo en la app (primer audio, tiempo total, cortes/huecos, errores, memoria, bytes de red) que guarda cada medición con su dispositivo y red; corregir lo que se pueda demostrar por código (p. ej. pausas artificiales entre segmentos, política de buffers y *backpressure*); evaluar Deepgram Aura y modelos Turbo de ElevenLabs **solo después** de las mediciones. Los resultados del banco son de dispositivo real: lo que no se mida, se documenta como no medido.

## P1 — Agente, web, memoria

- **Agente (verificado)**: `ConversationEngine` ejecuta un bucle (≤ 4 rondas, ≤ 3 llamadas por ronda) donde el modelo decide todo. No hay plan explícito, dependencias, paralelismo controlado, reintentos por paso, cancelación por misión, ni persistencia de estado. Reutilizables: validación de herramientas, confirmaciones por riesgo, contenido no confiable, registro de acciones. Plan: `MissionPlanner` + `MissionRunner` en el núcleo (comprensión → plan → ejecución con grafo de dependencias → verificación → respuesta), estado persistente por perfil, y misiones predefinidas como «organiza mi mañana» (agenda + recordatorios + clima + conflictos). Las consultas y acciones reversibles que el usuario pidió claramente no vuelven a preguntar (ya es así); lo sensible mantiene la confirmación.
- **Web (verificado: no existe)**: hace falta un proveedor de búsqueda con API permitida (no raspar buscadores) y un lector de páginas. Todo lo que venga de internet es contenido **no confiable** (se reutiliza la defensa de adjuntos y biblioteca) y se mantiene separado de la memoria personal. Se evaluarán proveedores con plan gratuito antes de elegir; ninguno será obligatorio.
- **Memoria (verificado)**: `MemoryItem` con cuatro tipos, retención por política, búsqueda léxica. Faltan relaciones persona–proyecto, caducidad, tipo episódico y semántico, resumen por conversación y administración selectiva en la interfaz. Se evoluciona sin romper los almacenes existentes (campos opcionales; el perfil heredado conserva todo).

## P2 — Windows, domótica, comercial

- **Companion Windows**: no existe nada. Se propone un servicio local con API HTTPS autenticada, emparejamiento por código de un solo uso, tokens revocables, lista blanca de herramientas, registro y confirmación de operaciones sensibles, sin puertos públicos ni ejecución arbitraria. Primero una prueba de concepto **de solo lectura** (archivos autorizados, procesos) verificable aquí en Windows. Lo que requiera el iPhone queda como «sin probar en dispositivo».
- **Domótica (Home Assistant)**: solo arquitectura y documento: API REST/WebSocket con token de acceso de larga duración guardado en Llavero, entidades en lista blanca, acciones por riesgo con confirmación, opcional y por perfil. Sin implementación hasta tener un Home Assistant de pruebas.
- **Comercial**: ya hay perfiles aislados, exportación/importación y la arquitectura de planes (`PERSONALIZATION_ARCHITECTURE.md`). Falta documentar backend, autenticación, suscripciones, métricas, panel administrativo, costos operativos y riesgos de privacidad. **No se implementan cobros ni se guardan claves maestras en la app.**

## Qué ya existe y se reutiliza (no se reimplementa)

`LanguageModelEngine` y los motores; presets y protocolo OpenAI; 429 + `retry-after`; perfiles y su aislamiento (`ProfileStorageLayout`, `Vault`); adjuntos, OCR, biblioteca y fuentes; contenido no confiable; confirmaciones por riesgo; voz en tiempo real y sus métricas; exportación/importación; CI y flujo del IPA.

## Reglas de trabajo para 0.8

Una fase cada vez; sin romper perfiles ni memorias existentes (los datos nuevos son opcionales y por perfil); nada se declara terminado porque compile: cada fase termina con el CI en verde **y** la lista de lo que solo se puede comprobar en el iPhone; IPA cuando haya un conjunto estable.
