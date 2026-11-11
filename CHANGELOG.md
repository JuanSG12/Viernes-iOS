# CHANGELOG

Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/). Versionado semántico.

## [0.8.0-dev] — Evolución (en curso; ver AUDIT_0_8.md)

**Fase C — Contactos y WhatsApp** (CI verde en 576531c): resolutor central de contactos (búsqueda aproximada, apodos, empresa, móvil preferido, desambiguación), número en formato internacional con el código de país de la región del perfil, enlaces `wa.me` documentados por WhatsApp, y `compose_message`/`call_phone`/`compose_email` por nombre. Nunca se afirma que se envió.

**Fase B — Multi-Brain, consumo y presupuesto** (CI verde en ffa8b69): presets de OpenAI y Cerebras (API compatible con OpenAI; Groq sigue disponible y es opcional); registro de consumo por perfil (cifrado) con los tokens reales del proveedor o una estimación marcada; tarifas que escribe el usuario (la app no trae precios propios); presupuesto mensual (5, 10, 20 o el monto que quieras) que detiene las solicitudes a proveedores de pago y explica el motivo, con alerta al 80 %; proveedores autorizados; lo que cada proveedor informe de sus límites (`x-ratelimit-*`), y nada más. Nunca cambia de proveedor por su cuenta. Sin probar en el iPhone ni con claves reales de OpenAI/Cerebras.

**Fase D — Voz: banco de medición** (escrita): Ajustes › Voz › Rendimiento › Banco de medición. Dice las mismas 4 frases fijas con cada modo (voz del sistema, ElevenLabs en tiempo real, ElevenLabs por frases) y anota los tiempos reales de ese iPhone: primer audio, tiempo total, cortes (tiempo real) o silencios entre frases (voz del sistema), errores, audio recibido y variación de memoria. Sin ganador automático. **No se cambia de proveedor de voz hasta tener estas mediciones, que solo se pueden tomar en el iPhone.**

**Fase E — Misiones del agente** (escrita): `MissionRunner` con dependencias, consultas seguras en paralelo (hasta 3) y acciones una a una, reintentos limitados solo en fallos pasajeros, cancelación, verificación (un resultado vacío no cuenta), estado guardado cifrado tras cada paso, recuperación de misiones interrumpidas y reanudación de lo que no terminó. Misiones conocidas: «organiza mi día / mi mañana», «organiza el día de mañana», «organiza mi semana» (agenda + recordatorios + clima si se sabe la ciudad). El modelo recibe solo resultados reales y lo que falla se dice con su motivo. Pantalla Ajustes › Misiones del agente.

**Fase F — Investigación web** (escrita): herramientas `web_search` y `read_page`, **apagadas por defecto**; se encienden eligiendo un buscador (Brave Search o Tavily, ambos opcionales y con su propia clave en el Llavero del perfil) en Ajustes › Investigación web. Solo sale del iPhone el texto de la búsqueda (las búsquedas con datos sensibles se rechazan); las páginas se leen en el teléfono (solo https público, sin IP ni redes locales, cada redirección revisada, sin JavaScript, sin cookies, tamaño acotado). Todo lo de internet es contenido NO confiable (neutralizado; mientras esté en la conversación las acciones que no son consultas piden confirmación), sus fuentes aparecen en «Fuentes consultadas» y el prompt exige citar, comparar y señalar contradicciones. Historial de investigaciones cifrado y aparte de la memoria.

**Fase G — Memoria avanzada y visión** (escrita): cada recuerdo puede llevar **proyecto**, **personas** y **caducidad** (opcionales; lo guardado antes se lee igual). La memoria episódica (resúmenes de conversaciones) caduca a los 90 días; un recuerdo caducado deja de usarse y se borra al abrir la app. Recuperación por contexto (lo del proyecto o la persona que mencionas pesa más), pantalla Memoria con «Personas y proyectos» (conteo, relaciones persona–proyecto, ver y borrar todo lo de uno), editor con proyecto/personas/caducidad y herramienta `save_memory` con proyecto y personas. Nunca se guarda una conversación completa. **Modo visión**: con una imagen, el modelo separa lo que SE VE de lo que SUPONE, no rellena huecos, no identifica personas por la cara y avisa de riesgos (electricidad, gas, baterías, medicamentos); el texto dentro de la imagen sigue siendo un dato, no una orden. La lectura de PDF, Word y Excel, el OCR (Vision/VisionKit), la biblioteca y las fuentes ya existían (0.7) y no se reconstruyeron.

**Fase H — Windows Companion (prueba de concepto)** (escrita; servicio verificado en Windows): carpeta `companion/windows` — servicio Node sin dependencias con API HTTPS (certificado propio con huella fijada por el iPhone), **solo red local**, emparejamiento por código de un solo uso, tokens revocables (solo su huella), lista blanca de herramientas (buscar/leer archivos de carpetas autorizadas sin secretos, procesos, ejecuciones de GitHub de repositorios autorizados, scripts aprobados con huella y confirmación en el PC, bandeja de mensajes al iPhone), **sin ejecutar comandos libres**, límites y auditoría. 9 pruebas en Node (corren también en el CI) y `setup.ps1` probado con el certificado real. En el iPhone: cliente con huella fijada, token en el Llavero del perfil y pantalla Ajustes › Windows Companion. Sin probar desde un iPhone real; las herramientas del compañero aún no están conectadas al asistente (solo a su pantalla). Ver `companion/windows/README.md`.

**Fase I — Comercial y domótica (solo diseño)**: `COMMERCIAL_ARCHITECTURE.md` (backend, autenticación, sincronización cifrada, proxy de IA con clave maestra solo en el servidor, planes por dimensiones, facturación, métricas, panel, costos y riesgos de privacidad; sin precios, sin cobros) y `HOME_ASSISTANT_ARCHITECTURE.md` (Home Assistant opcional, token en el Llavero, lista blanca de entidades, acciones por riesgo; **no implementado**).

## [0.7.0] — Fase 5: integración final (incluye las fases 1 a 4; CI verde en e3876e3: estáticas, núcleo, app sin MLX y app completa; sin probar en el iPhone)

No se añadió funcionalidad nueva en la fase 5: se integró y se verificó todo lo anterior. En la práctica fueron ciclos de CI que sacaron fallos reales (abajo) y un IPA que reúne las cuatro fases.

**Regresión.** El CI ejecuta unas 450 pruebas (núcleo: motor de conversación, herramientas, memoria, calendario, contactos, correo, mensajes, clima, atajos, Claude, voz, multimodal, biblioteca, perfiles; app: SwiftData cifrado, Llavero, Vault, integración e interfaz en simulador) y compila la variante con MLX. **Verificado solo en CI**: la lógica de motores y herramientas con dobles de prueba. **NO verificado en el iPhone** (no se puede desde aquí): llamadas reales a Groq, Gemini y ElevenLabs; MLX local; calendario, recordatorios, contactos, correo y mensajes reales; cámara, escáner, micrófono, Face ID, selector de archivos; rendimiento real.

**Fallos reales encontrados y corregidos en esta ronda**: (1) en la búsqueda de la biblioteca, un empate dependía del orden aleatorio de un diccionario (ahora es determinista); (2) una prueba de interfaz de borrado esperaba el instante equivocado; (3) las pruebas de Ajustes no se desplazaban hasta filas que quedaron fuera de pantalla; (4) una prueba de importación suponía un valor de fábrica erróneo para Claude.

**Privacidad y consumo (revisión por lectura de código, sin medición en el iPhone).** Nada sale del teléfono sin acción del usuario: adjuntos y fragmentos de la biblioteca piden permiso con un cerebro en la nube; no hay embeddings en la nube; la voz en la nube, el dictado en servidores y el envío de adjuntos son opcionales; cada perfil tiene sus propias claves. Consumo: el índice de la biblioteca vive en RAM (hasta unos 16 MB con los límites) y solo el del perfil activo; cambiar de perfil descarta el anterior; PBKDF2 (600 000 vueltas) solo corre al exportar o importar con contraseña. **No hay cifras medidas de batería, memoria ni latencia en un iPhone real**: está pendiente.

## [0.7.0-fase4] — Personalización y preparación multiusuario (CI verde en e3876e3; sin probar en el iPhone)

Detalle, separación de datos y arquitectura comercial (documentada, sin facturación) en **PERSONALIZATION_ARCHITECTURE.md**.

- **Perfiles**: hasta 8 en el iPhone, cada uno con SU memoria, SUS documentos, SUS conversaciones, SUS ajustes, SUS claves de API y SU clave de cifrado (almacenes y cuentas del Llavero distintos). El perfil que ya existía conserva exactamente sus nombres: no se migra ni se mueve nada. Cambiar de perfil crea un modelo nuevo y descarta el anterior. Perfiles **protegidos** con Face ID/código. Eliminar un perfil borra su clave, claves de API, ajustes y archivos.
- **Personalidad** separada del motor: trato, naturalidad, longitud, estilo, instrucciones personales, pronunciación, idioma y región, nombre de la asistente; con los valores por defecto el prompt es idéntico al de siempre; las instrucciones se neutralizan y acotan y no pueden tocar las reglas.
- **Autonomía** prudente/normal/proactiva: solo puede pedir más confirmaciones, nunca menos. **Herramientas apagadas por perfil**.
- **Exportar/importar** un perfil (sin claves; cifrado opcional con contraseña PBKDF2 + AES-GCM). Importar crea un perfil nuevo, con recuerdos pendientes de aprobar, sin instrucciones personales salvo confianza expresa y sin activar permisos.
- **Interfaz**: Ajustes › Perfiles (lista, nuevo, cambiar, renombrar, proteger, exportar, importar, eliminar) y Ajustes › Personalidad (con la vista previa exacta de lo que se añade al modelo).
- **Arquitectura comercial** documentada (Free/Plus/Pro/Business), sin precios, sin facturación y sin cifras inventadas.
- Pruebas nuevas: núcleo (registro, nombres de almacenamiento, personalidad, autonomía, herramientas, pronunciación, dos perfiles de prueba con memoria/documentos/configuración separados, paquete de exportación), app (dos perfiles sobre archivos reales con claves distintas, borrado, cifrado del archivo, `ProfileHost`) y 2 de interfaz.
- Arreglo: la prueba de interfaz de borrado de la biblioteca esperaba el instante equivocado (el resultado viejo sigue en pantalla unos instantes tras borrar).
- **Sin verificar en el dispositivo**: biometría real, selector de archivos/compartir, rendimiento de PBKDF2, personalidades con proveedores reales. Sin sincronización entre dispositivos.

## [0.7.0-fase3] — Knowledge Engine: biblioteca de conocimiento personal (el CI compila y prueba; sin probar en el iPhone)

Detalle, pipeline, búsqueda y límites en **KNOWLEDGE_ENGINE.md**.

- **Biblioteca** de documentos, imágenes con texto, notas y textos, con proyectos/carpetas/colecciones anidables, etiquetas, fechas, identificador estable, metadatos y **estado de procesamiento real** (procesando → indexado | error). Guarda el texto extraído con su página/sección/líneas, no el archivo original.
- **Pipeline**: validar → límites → hash SHA-256 (archivo y texto) → duplicados (mismo archivo, mismo texto en otro formato, casi idéntico) → fragmentar con referencias → vectores → guardar cifrado → indexar → **verificar que se recupera**. Una interrupción nunca deja un elemento «indexado» a medias.
- **Búsqueda híbrida** sin base de datos externa: BM25 con raíces y sin acentos + significado por coseno (modelo de frases del sistema en español si existe; si no, un modelo básico propio, portable y sin descargas, que **no entiende sinónimos**) + fechas literales («15 de marzo de 2023» se busca como `2023-03-15`, `15/03/2023`…); filtros por documento, proyecto, etiqueta, tipo y fecha.
- **Memoria y biblioteca separadas**: almacén aparte (`knowledge.store`), índice, pantalla y borrado propios; ambos cifrados con la clave del Llavero. «Borrar todos los datos» también vacía la biblioteca.
- **Respuestas fundamentadas**: si preguntas por tus documentos («mi contrato», «mis notas»…) o hay coincidencias claras, Viernes busca fragmentos en el teléfono y los entrega al modelo con documento y página; cita, distingue texto de interpretación y, si no hay evidencia o la biblioteca está vacía, se lo dice al modelo para que no invente. Herramienta `search_library` para búsquedas explícitas. Cada respuesta muestra **«Fuentes consultadas»**.
- **Privacidad y seguridad**: con un cerebro en la nube se pide permiso antes de enviarle fragmentos (ajustable); lo que devuelve la biblioteca es contenido no confiable (neutralizado, y con él en juego cualquier acción exige confirmación).
- **Interfaz**: Más › Biblioteca (lista con estados, buscador, filtro, detalle, notas, carpetas), «Guardar en la biblioteca» desde el detalle de un adjunto, ajustes de la biblioteca.
- Pruebas: ≈ 45 en el núcleo, 9 en la app (SwiftData cifrado, separación memoria/biblioteca, OCR, borrado) y 2 de interfaz.
- **Sin verificar en el dispositivo**: rendimiento con una biblioteca grande, calidad de la búsqueda por significado con el modelo del sistema, uso real con Groq/Gemini. Pendiente: índice persistente cifrado si se superan los límites, editar notas, exportar.

## [0.7.0-fase2] — Multimodalidad: adjuntos, imágenes, documentos y escáner (el CI compila y prueba; sin probar en el iPhone)

Detalle técnico, formatos, matriz de capacidades y límites en **MULTIMODAL_ARCHITECTURE.md**.

- **Adjuntos** desde la fototeca, la cámara, el escáner de documentos (VisionKit) y Archivos, con vista de estado real por adjunto (*leyendo / listo / con avisos / no se pudo leer*), detalle, vista previa y quitar. Menú «Adjuntar» y botón de clip.
- **Imágenes** JPG/PNG/HEIC/WebP: orientación EXIF, transparencia → blanco, reducción a ≤ 1 568 px y JPEG ≤ 2,9 MB; OCR local (Vision) como alternativa que no saca nada del teléfono.
- **Documentos** con lector propio por tipo: PDF (PDFKit + OCR para páginas escaneadas, con número de página), DOCX y XLSX (lector ZIP/DEFLATE propio en Swift puro, sin dependencias), CSV, JSON, XML, Markdown, TXT y código (con rangos de líneas). Sin lector real ⇒ se rechaza con el motivo (`.doc`, `.xls`, `.pptx`…).
- **Validación por contenido** (no por extensión), límites de tamaño/páginas/celdas, protección contra bombas de compresión y contra archivos con contraseña o dañados; mensajes en español con alternativa.
- **Matriz de capacidades** por cerebro (texto, imagen, PDF, audio, contexto, herramientas, streaming) con sus fuentes, visible en Ajustes › Adjuntos y visión; modelo de visión de Groq editable y comprobable.
- **Enrutador**: decide qué cerebro puede leer lo adjuntado; pide permiso antes de enviar nada a la nube (ajustable); nunca cambia a otro proveedor sin autorización; el cambio dura un mensaje y conserva el contexto; la respuesta dice qué cerebro contestó.
- **Selección de fragmentos** por relevancia (BM25) o repartidos (peticiones generales), con referencia de archivo + página/sección/líneas; **comparación** de documentos y hojas calculada en el teléfono.
- **Seguridad**: el contenido de archivos es información no confiable (bloque marcado, etiquetas internas y caracteres invisibles neutralizados, reglas de sistema) y, mientras haya contenido de archivos, **toda acción que no sea una consulta exige confirmación**; detector heurístico de frases que dan órdenes (solo avisa).
- El historial guarda solo metadatos de los adjuntos; los archivos temporales se borran al quitarlos, al iniciar una conversación nueva y al arrancar.
- Pruebas: ≈ 100 en el núcleo (archivos reales: DOCX/XLSX con DEFLATE de .NET, ZIP con bomba, etc.), 20 en la app (imágenes, PDF con texto, OCR, PDF con contraseña, centro de adjuntos) y 2 de interfaz.
- **Sin verificar en el dispositivo**: cámara, escáner VisionKit, envío real a Groq/Gemini (se prueba la forma de la petición, no la respuesta del proveedor). Pendiente para la fase 3: biblioteca persistente, índice, búsqueda y respuestas con fuentes guardadas.

## [0.7.0-fase1] — Motor de voz en tiempo real (el CI compila y prueba la lógica; sin oír en el iPhone)

Reporte real: al responder por voz, el audio se traba. Ver **VOICE_ENGINE.md** (auditoría, decisión sobre ElevenLabs, arquitectura, métricas).

- **Auditoría** (por lectura de código; la causa dominante en el teléfono no se puede determinar sin medir): ElevenLabs por HTTP con una petición por frase y un `AVAudioPlayer` nuevo por frase, pausas artificiales sumadas al silencio del audio, `setCategory`/`setActive` en el hilo principal en cada frase, planificación en el actor principal junto al núcleo 3D, cancelar la generación no cortaba la voz, interrupciones y cambios de audífonos sin observar y ninguna métrica.
- **Motor nuevo**: texto → `SpeechSegmenter` (unidades naturales; el primer fragmento sale en la primera cláusula) → turno con identificador (`VoiceTurnLedger`: sin duplicados, sin desorden, sin fragmentos tardíos) → **WebSocket de Text-to-Speech de ElevenLabs** con `eleven_flash_v2_5` y audio `pcm_24000` → `RealtimePCMPlayer` (un motor continuo, colchón anti-cortes, cola propia fuera del hilo principal). Empieza a hablar sin esperar al final de la respuesta.
- **ElevenLabs**: `eleven_v4_turbo` existe pero solo por el WebSocket de **Text-to-Dialogue** (otro protocolo): evaluado, no seleccionado, y nunca se mezclan; un modelo `v3/v4` guardado se sustituye por Flash en este protocolo. «Voz en tiempo real» se puede apagar para volver al envío por frases.
- **Recuperación**: si la conexión se corta, reconecta una vez retomando solo lo no hablado (alineación del servidor); si no, la voz del sistema termina la respuesta sin repetir ni solaparse; los fallos de configuración (clave, plan, voz, cuota) suspenden la nube con un aviso.
- **Interrupción**: tocar mientras habla corta al instante (silencio medido) y abre el micrófono; la respuesta cortada no vuelve. Interrumpir *hablando* no está implementado (exige cancelación de eco).
- **Sistema de audio**: la sesión se configura una vez por turno, no por frase; llamadas, Siri y audífonos desconectados detienen la voz.
- **Métricas** por turno y pantalla «Rendimiento de la voz» (primer token, primer audio, cortes, descartes, errores, reconexiones, interrupciones; medianas y p95; informe copiable).
- **CI**: el paso de pruebas del núcleo no tenía `pipefail` (un fallo de `swift test` no habría hecho fallar el trabajo): corregido; los fallos del núcleo y de la app se publican en ramas públicas `ci-errors-*`.
- ≈ 45 pruebas nuevas en `VoiceEngineTests.swift` (segmentación independiente de los deltas, turnos, colchón, PCM partido a media muestra, métricas con reloj falso, protocolo, simulación de un turno y de una interrupción).
- **Sin verificar en el dispositivo**: todo lo de audio, red y ElevenLabs (incluidos `pcm_24000` y `auto_mode` con una cuenta gratuita); no hay ninguna cifra de latencia real.
- **Estado del CI en `517d7ee`**: comprobaciones estáticas, pruebas del núcleo (217) y compilación + pruebas de UI de la app completa (con MLX) en verde; IPA sin firmar compilado. La variante sin MLX no obtuvo runner de macOS (cancelada sin ejecutar pasos) y se relanzó en el commit siguiente.

## [0.6.0] — Viernes 2.0: modificar y borrar eventos, correo con vista previa, dictado mejorado y límite de Groq (el CI lo compila y prueba; sin probar en el iPhone)

Reporte real (iPhone, IPA #5): el calendario crea y consulta bien, pero «elimina la reunión que acabas de crear» respondía que no existe una herramienta para borrar; un correo dictado no se entendía y, al reescribirlo, salió «Alcanzaste el límite del plan gratuito de Groq».

### Calendario: modificar y eliminar (lo ya resuelto —permisos, consulta, creación— no se reescribió)
- Herramientas nuevas **`update_event`** y **`delete_event`** (solo existen con «Permitir que Viernes lea mi calendario», porque hay que leer para localizar). El ejecutor **resuelve el evento real ANTES de confirmar o ejecutar**: búsqueda por título (sin tildes ni mayúsculas), día, hora de inicio o «el que acabas de crear»; 0 coincidencias → se dice; varias → **no se elige**, se lista con sus identificadores reales de EventKit y el modelo pregunta cuál; un identificador inventado no se resuelve.
- **Eliminar siempre confirma, mostrando el evento exacto** (título, día, hora, calendario); **modificar un evento claro no pregunta**. Calendarios de solo lectura o suscritos se rechazan con el motivo. En eventos repetidos solo se toca esa ocurrencia y se dice.
- **Verificación real**: tras guardar o borrar, el evento se vuelve a leer desde un `EKEventStore` NUEVO y se compara con lo pedido; si iOS no refleja el cambio, el resultado es un fallo, no un «listo». Los errores de EventKit se informan con su motivo.
- «Ponla para el viernes» (`new_date`) conserva la hora; «a las 4 de la tarde» (`new_time`) conserva el día.
- Identificadores: el registro local `EventLedger` guarda los eventos que Viernes crea (id de EventKit) para entender «el que acabamos de crear» solo entre lo que Viernes creó en las últimas 12 horas y todavía existe; nunca «el más reciente del calendario».
- La tarjeta de «crear evento» deja de enseñar la fecha en ISO.

### Correo
- `compose_email` ahora **muestra una vista previa editable** (para, asunto, mensaje) y espera a que el usuario decida: **Abrir en Correo** (compositor de iOS `MFMailComposeViewController` si hay cuenta, con resultado real: enviado/guardado/cancelado/fallido; si no, `mailto:`), **Usar otra app de correo**, **Copiar** o **Descartar**. Si no se puede abrir, el borrador se conserva en la hoja para copiarlo. Al modelo se le cuenta lo que pasó de verdad; nunca «enviado» si el usuario no pulsó Enviar.
- Una dirección **dictada** («kisameyguy arroba gmail punto com») se convierte en dirección antes de validar; una no válida da un error claro para el modelo. Sin destinatario conocido el borrador se prepara igual y se avisa.
- `find_contact` también busca por apodo y empresa.
- Instrucciones del prompt: redactar asunto y cuerpo, buscar al destinatario en recuerdos/contactos, preguntar solo si no se sabe de qué trata.

### Límite de Groq (HTTP 429)
- Causa probable (por lectura del código y de la documentación de Groq; **sin confirmar con tus cifras reales**): cada petición enviaba hasta 14 000 caracteres de historial + el prompt completo + 1 500 tokens reservados, y una orden con herramienta hace dos peticiones; con un límite por minuto del plan gratuito eso se agota rápido.
- Ahora: el historial enviado a la nube baja a 7 000 caracteres; lo que cambia en cada petición (hora, recuerdos) va al final del prompt para que la caché de prompt del proveedor aproveche el principio; un 429 con espera corta (≤ 30 s) se **espera y se reintenta solo (máx. 2 veces)** y la pantalla dice «Groq pidió esperar N s»; un límite **diario** o una espera larga se informa con el tiempo y las cifras reales del proveedor (límite/usados/pedidos), que además quedan en el registro técnico.

### Voz (ver VOICE_AUDIT.md)
- Auditoría completa del reconocimiento por lectura de código. Hallazgos corregidos: faltaban `contextualStrings` (nombres propios), no se manejaban interrupciones de audio ni cambios de audífonos, el silencio fijo de 1,3 s cortaba al hacer pausas, solo se trataban dos códigos de error y el fallo del reconocedor no se reintentaba.
- **Revisión antes de enviar** (apagada/«2,5 s»/siempre): lo entendido aparece editable con «Enviar», «Editar» y «Descartar»; en el modo breve se envía solo. Un **lápiz** junto a la última frase dictada permite corregirla y reenviarla.
- **Corrección automática y aprendizaje**: glosario de nombres (sesga al reconocedor y corrige lo transcrito, de forma prudente), correos dictados, y correcciones aprendidas de lo que editas (visibles y borrables en «Nombres y términos»).
- Pausa para cerrar la frase configurable (0,8–3 s; por defecto 1,8 s), espera si el reconocedor aún añade palabras, un reinicio automático ante errores recuperables, mensajes claros para «falta el modelo de dictado» y «dictado desactivado», y opción de usar el micrófono del iPhone con audífonos Bluetooth.
- **Diagnóstico de reconocimiento**: historial cifrado (texto, nunca audio) con entrada de audio, idioma realmente usado, duración, motivo del fin, parciales, error, reinicios, interrupciones, lo corregido y lo editado.
- **Whisper de Groq (opcional)**: apagado por defecto; al activarlo se pide consentimiento y el audio de las frases dictadas con el botón (nunca el de la escucha «Viernes», nunca a ElevenLabs) se envía a Groq como WAV de 16 kHz y se borra al terminar. El reconocimiento local sigue siendo la base y el respaldo. El diagnóstico guarda ambas versiones y permite votar cuál acertó; **no se afirma que Whisper sea mejor**.

### Pruebas
- ≈ 70 pruebas nuevas en `Viernes2Tests.swift` (búsqueda y ambigüedad de eventos, cambios de día/hora, validación, confirmaciones, correo dictado, límites de Groq, corrección y aprendizaje, ajustes de consentimiento, diagnóstico, `mailto:`, Whisper).
- **Sin verificar en el iPhone**: EventKit real (resolver/modificar/borrar/releer), el compositor de correo, el dictado, la captura de audio para Whisper y el comportamiento exacto de Groq. Los pasos para probarlo están en VOICE_AUDIT.md y en el resumen de la sesión.

## [0.5.1] — Agente más robusto y núcleo sin cuadrados negros (pendiente de probar en el iPhone)

Reporte real (iPhone, IPA #4): al pedir «agendar una reunión» o «ver mi agenda» salía «El modelo no devolvió texto», y el núcleo mostraba cuadrados negros al moverse.

- **Respuestas vacías**: causas halladas por lectura del código, no confirmadas en el dispositivo: (1) el flujo de la nube ignoraba errores del proveedor enviados dentro del flujo (Groq corta con `tool_use_failed` cuando el modelo escribe una llamada a función a su manera), (2) el guardián de fugas borraba un JSON de llamada escrito sin las etiquetas `<tool>`, y (3) la respuesta vacía se mostraba como error sin reintentar. Ahora: `ToolCallRecovery` rescata llamadas en JSON suelto, `<function=…>` y `functions.nombre {…}` (solo herramientas del catálogo, con la misma validación y confirmaciones); `tool_use_failed` se convierte en una llamada válida; `finish_reason: length` se explica; una respuesta vacía se reintenta hasta 2 veces; y si todo lo intentado queda oculto (faltaban datos) se responde un mensaje neutro en vez de una burbuja en blanco. El prompt fija un único formato de llamada y la conversión de horas («3:30 de la tarde» = 15:30).
- **Núcleo 3D**: se retira el bloom HDR (las capturas con bloom mostraban cuadrados negros; sin bloom salen limpias) y el resplandor pasa a una capa 2D (`CoreGlow`). La causa exacta (probablemente valores inválidos en los reflejos del metal que el desenfoque del bloom esparce) no está demostrada; el criterio fue empírico (capturas con y sin bloom).
- Pruebas nuevas (`ToolRecoveryTests`): rescate de llamadas, errores dentro del flujo, reintento de vacíos, sin burbuja en blanco, sin repetir una llamada copiada por el modelo.
- `static-check.ps1` entiende cadenas crudas de Swift (`#"…"#`).
- **Sin verificar**: nada de esto está probado con Groq real ni en el iPhone; el CI solo compila y ejecuta pruebas con un modelo simulado.

## [0.5.0] — Núcleo 3D y pantalla principal según la referencia (sin verificar en pantalla)

El núcleo 2D (Canvas) se leía como una ilustración vectorial. Se sustituye por un objeto tridimensional real. Ver **CORE_VISUAL.md** (decisión técnica, fidelidad frente a la referencia y lo que no se reproduce).

- **`ViernesCoreVisual`** (componente independiente, solo recibe estados visuales): escena **SceneKit** con dos eslabones de cromo **entrelazados** (malla procedural de bandas con torsión y ondulación), un anillo orbital, materiales PBR metálicos, tiras incandescentes, chispa central con luz naranja real, mapa de entorno procedural para los reflejos, bloom HDR, destello y partículas. Estados: `idle, listening, thinking, speaking, executing, error, offline`, con parámetros suavizados. El 2D queda como respaldo (sin Metal, «efectos reducidos», pruebas de UI).
- **Pantalla principal** rehecha según la referencia: marca y engranaje, núcleo grande, pastilla «En línea», «¿En qué puedo ayudarte?», mosaicos **Mi día · Tareas · Clima · Más** (menú con Memoria, Historial, Nueva conversación y Preguntar a Claude) y cápsula de voz. Fondo con barridos de cromo y vetas naranja (`ChromeBackdrop`).
- **Capturas del simulador en el CI** (`screenshots.yml`, rama `ci-screenshots`) para revisar el diseño sin un Mac; estados fijados con `--uitest-core-state=…` y una conversación de ejemplo («Vista de prueba») con `--uitest-demo-weather`, ambos **solo con `--uitest`**.
- Pruebas de UI actualizadas al menú «Más». Análisis de funciones avanzadas en `AGENT_AND_AUTOMATION.md`.
- **Sin verificar**: el aspecto real, la fluidez a 60 fps y la batería en un iPhone; SceneKit está marcado como obsoleto por Apple (avisos de compilación, funciona en iOS 18).

## [0.4.0] — Auditoría crítica: calendario, resultados internos, confirmaciones y clima (sin verificar en iPhone)

Tras probar la 0.3.0 en el iPhone: el calendario no funcionaba aun con permisos, aparecían etiquetas internas como `[RESULTADO_HERRAMIENTA]` en la conversación y Viernes preguntaba demasiado antes de actuar.

### Calendario / EventKit — causas encontradas y corregidas
- Se leía con un `EKEventStore` creado **antes** de conceder el permiso (puede devolver vacío): ahora se lee con un almacén nuevo tras comprobar la autorización.
- No se comprobaba el estado real: con permiso de «solo escritura» (el que concede crear un evento) se pedía acceso completo a ciegas. Ahora se consulta `authorizationStatus`, se pide acceso solo si hace falta y, si queda denegado o en solo escritura, el mensaje dice exactamente qué hacer («Ajustes › Viernes › Calendarios › Acceso completo») y la tarjeta ofrece **Abrir Ajustes**.
- Las fechas en español fallaban: el modelo enviaba `mañana` y la validación solo aceptaba `tomorrow`, así que el usuario veía un error técnico. Ahora se aceptan `hoy`, `mañana`, `pasado mañana`, `ayer`, días de la semana y `YYYY-MM-DD`.
- La pantalla de Permisos decía «Viernes no lee tu calendario» y no permitía pedir lectura: se reescribió con el estado real (incluye «Solo escritura», Contactos) y un **diagnóstico del calendario** (pide acceso completo y muestra estado, calendarios visibles y número de eventos de los próximos 7 días) más un registro técnico local.
- Mismas comprobaciones para Recordatorios, Eventos (escritura) y Contactos (incluye el acceso limitado de iOS 18).
- **Sin verificar**: nada de esto se ha ejecutado en un iPhone; el diagnóstico sirve justamente para saber qué ve iOS.

### Resultados de herramientas
- Los resultados viajan en un sobre interno `<tool_result>` (el filtro de salida lo oculta aunque el modelo lo repita) y `LeakGuard` elimina en streaming cualquier eco de `[RESULTADO_HERRAMIENTA]`, JSON de llamadas o líneas `- herramienta: …`, también si llegan partidos en trozos, antes de la pantalla y de la voz.
- El prompt ordena no citar etiquetas, nombres de herramientas ni JSON y explicar los fallos en lenguaje llano.
- Los errores de validación y las llamadas mal formadas se **ocultan** al usuario (el modelo sí los ve y los corrige) y se registran en diagnósticos; los errores técnicos de EventKit/Contactos/red se registran y se reemplazan por un mensaje breve.

### Política de confirmaciones por tipo de acción
- `ToolRisk` ahora distingue `safe` (consultas), `reversible`, `sensitive`, `external` y `destructive`. Se ejecutan directas: clima, agenda (con el interruptor de Privacidad), contactos, recordatorios, eventos, borradores de correo/mensaje, marcador. Siguen pidiendo confirmación: guardar en memoria, enlaces, Atajos, Claude y olvidar. El prompt ordena no preguntar lo ya pedido y preguntar solo el dato imprescindible.
- Cambio de texto en Privacidad: el interruptor de calendario/contactos **es** la autorización; ya no hay confirmación en cada lectura.
- No existe una herramienta para borrar recordatorios, así que «Elimina todos mis recordatorios» no se puede ejecutar (el modelo debe decirlo); una herramienta así tendría riesgo `destructive`.

### Clima
- Tarjeta nativa (`WeatherCard`) con temperatura, condición, ubicación, probabilidad de lluvia, viento y humedad, hoy y mañana. Los datos son los de Open-Meteo; si falta uno, no se dibuja. No hay imágenes (la referencia muestra una foto de la ciudad: no se reproduce).
- `ToolOutcome.card` y `ActionRecord.card` (opcional: el historial anterior sigue leyéndose).

### Pruebas
- 20 pruebas nuevas del núcleo (guardián de fugas, tarjeta de clima, política por riesgo, fechas en español, registros ocultos, diagnósticos) y ajuste de las que asumían el modelo de confirmaciones anterior.

## [0.3.0] — Rediseño visual Black Chrome / Neural Orange (sin verificar en dispositivo)

### Por qué
La interfaz azul/cian se parecía demasiado a la de otros asistentes de IA. Se pidió una identidad propia, cinematográfica y reconocible, sin perder funcionalidad.

### Cambiado
- **Sistema de diseño** (`Theme.swift`): materiales (negro, grafito, cromo, plata), un único color de energía (naranja eléctrico; ámbar solo para avisos, rojo para errores), tipografía ancha para títulos, medidas, superficies con luz de canto (`chromeSurface`), botones y paneles. Todas las pantallas se migraron por renombrado de tokens (`cyan→accent`, `deep→carbon`, `abyss→ink`…), así que Ajustes, Cerebro, Voz, Memoria, Historial, Permisos y Onboarding comparten la identidad.
- **Núcleo nuevo** (`ChromeCoreView`): tres anillos de cromo deformados y entrelazados (mitades traseras y delanteras para dar profundidad), segmentos incandescentes, órbitas finas con satélites y chispa central con destellos. Sustituye al núcleo holográfico azul (`HoloCoreView`, eliminado). Estados reales: escucha (ondas y deformación según el nivel del micrófono), pensamiento (partículas en espiral hacia el centro, anillos concentrados), habla (pulso y onda por palabra), **herramientas** (nodos conectados al centro; solo mientras una herramienta se ejecuta de verdad) y espera (casi quieto, 12 fps). Los parámetros se suavizan entre estados; respeta «Reducir movimiento» y el ajuste de efectos reducidos; en segundo plano no dibuja.
- **Pantalla de inicio**: marca y subtítulo, estado, núcleo grande, mensaje contextual (saludo según la hora, o «Te escucho» con la transcripción en vivo, o la herramienta en curso), accesos rápidos (Tareas, Clima, Claude, Memoria: solo capacidades que existen) y **cápsula de voz** integrada con el núcleo (ondas naranjas a ambos lados del micrófono).
- **Conversación**: al haber mensajes el núcleo se compacta y la conversación ocupa la pantalla. Mensajes del usuario en burbuja compacta; respuestas de Viernes como texto limpio con una línea de energía (no tarjetas enormes); cursor en el streaming; indicador de procesamiento con la herramienta en curso; **tarjetas de acción** con icono por herramienta y resultado real; botones de **escuchar de nuevo / detener** y **copiar** en la última respuesta.
- **Icono** nuevo (cromo y naranja), generado con `scripts/make-icon.ps1` y revisado a ojo.

### Añadido en el motor (mínimo)
- Evento `toolStarted` en `ConversationEngine`: la UI sabe cuándo una herramienta VA a ejecutarse (antes de confirmar), para animar el núcleo sin simular nada.

### Agente y herramientas (ver AGENT_AND_AUTOMATION.md)
- **Ejecución por rondas mejorada**: las herramientas seguras e independientes de una misma respuesta corren **en paralelo**; las sensibles y de memoria, una a una y con confirmación; los registros conservan el orden de las llamadas. **Un reintento** solo para fallos de red en herramientas seguras (nunca se repite una confirmación). Hasta **4 rondas** (antes 3) para encadenar consulta → acción → respuesta. Corregido: el motor describía al modelo todas las llamadas aunque solo ejecutara las primeras `maxCallsPerRound`.
- **Herramientas nuevas** (todas sensibles, con confirmación): `list_events` (leer agenda), `find_contact` (Contactos), `compose_email`, `compose_message` (SMS/WhatsApp) y `call_phone`. Correo y mensajes son **borradores**: no se envía nada hasta que el usuario pulsa Enviar.
- **Lectura de calendario y contactos: opt-in y apagada por defecto** (Privacidad). **Esto cambia la política anterior («Viernes no lee tus eventos»)** porque tu ejemplo («revisa mi agenda de mañana y recuérdame salir con tiempo») no es posible sin leerla. Con el interruptor apagado todo se comporta como antes, y el modelo sabe que no puede y lo dice. Nuevas claves de privacidad en `project.yml`.
- El prompt ordena encadenar con datos reales y pedir juntas las consultas independientes.
- 13 pruebas nuevas del núcleo (formatos, rango de calendario, validación, confirmaciones, permisos apagados, paralelismo, reintento, flujo agenda → recordatorio con dos confirmaciones, rechazo).
- Documentación: `AGENT_AND_AUTOMATION.md` (agente, herramientas evaluadas y descartadas, plan de memoria, proactividad real de iOS) y `WINDOWS_AGENT.md` (**solo diseño**: sin puertos públicos, emparejamiento por QR, firma con Secure Enclave, lista blanca, auditoría).

### No verificado
- Nada del rediseño se ha visto en un dispositivo ni en simulador: se escribió desde Windows. Solo se comprueba que compile y que los identificadores de las pruebas de UI sigan existiendo. Los riesgos son estéticos (proporciones, legibilidad, rendimiento del `Canvas` en un iPhone 14 Pro Max) y de compilación de SwiftUI.
- Pendiente de este rediseño: tarjeta visual de clima con datos estructurados (hoy el resultado se muestra como texto en la tarjeta de acción).
- Las herramientas nuevas (agenda, contactos, borradores, llamadas) se escribieron sin ejecutarlas en un iPhone: URLs de Correo/Mensajes/WhatsApp, permisos de EventKit/Contactos y el flujo completo con un modelo real están sin verificar.
- Pendiente de las prioridades 8–9: memoria contextual (caducidad, entidades, búsqueda semántica), ubicación para «clima aquí», resumen de agenda como notificación. Solo están diseñadas en AGENT_AND_AUTOMATION.md.

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
