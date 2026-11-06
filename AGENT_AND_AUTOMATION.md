# AGENT_AND_AUTOMATION — agente, herramientas, memoria y proactividad

Estado honesto: lo marcado **[hecho]** está en el código y comprobado por pruebas del núcleo (que corren en el CI de macOS); **[sin probar en iPhone]** significa que la parte del dispositivo (EventKit, Contactos, URLs de apps) nunca se ejecutó en un teléfono; **[pendiente]** no existe todavía.

## 1. El agente hoy: planificar → ejecutar → responder

Todo vive en `ConversationEngine` (core, portable). El modelo NO ejecuta nada: propone llamadas `<tool>{…}</tool>` y el motor decide.

| Fase | Qué pasa | Dónde |
|---|---|---|
| Planificar | El modelo ve la petición, la memoria relevante y el catálogo de herramientas **disponibles** (las de lectura de calendario/contactos solo existen si el usuario las activó). Se le ordena encadenar: primero consultar, luego actuar con datos reales. | `Persona`, `availableTools()` |
| Validar | Cada llamada pasa por `ToolValidator` (esquema, longitudes, formatos, rangos) **antes** de pedir confirmación o ejecutar. | `ToolValidator` |
| Confirmar | Las herramientas `sensitive` muestran la hoja con el texto exacto y caducan a «rechazado» a los 90 s. | `ConfirmationProvider` |
| Ejecutar | Las **seguras e independientes** de una misma respuesta corren en paralelo; las sensibles y las de memoria, una a una y en orden. Un fallo **de red** se reintenta una vez (solo en herramientas seguras; nunca se repite una confirmación). | `executeRound`, `performWithRetry` |
| Verificar | El modelo recibe el resultado REAL (`ÉXITO` / `RECHAZADA` / `FALLÓ`) y solo entonces cuenta qué pasó. La UI muestra el `ActionRecord`, no lo que el modelo diga. | `describe`, `ActionRecord` |
| Responder | Hasta 4 rondas (3 de herramientas encadenadas + respuesta final). Cancelable en cualquier momento (`Task.isCancelled`). | `maxToolRounds` |

**Historial de acciones [hecho]**: cada mensaje guarda sus `ActionRecord` (herramienta, resumen, resultado, fecha) cifrados con el resto de la conversación; se ve en las tarjetas de acción y en Historial.

**Ejemplo pedido** — «revisa mi agenda de mañana, identifica mi primera cita y recuérdame salir con tiempo»: ronda 1 `list_events` (consulta, con el permiso de Privacidad: sin preguntar) → el modelo lee los eventos reales → ronda 2 `create_reminder` con la hora calculada (reversible: se crea directo) → ronda 3 respuesta. La prueba `testReadCalendarThenCreateReminderChainsWithRealResultsAndNoNeedlessQuestions` lo verifica con un motor de pruebas; con un modelo real no está probado, y un modelo pequeño puede planificar mal.

**Lo que NO es (todavía)**: no hay un planificador explícito con grafo de dependencias; la dependencia se resuelve por rondas (el modelo decide qué consultar antes de actuar). Un plan declarativo (lista de pasos con dependencias que el usuario aprueba de una vez) es una mejora posible **[pendiente]**.

## 2. Herramientas nativas de iOS

| Herramienta | Riesgo | Notas |
|---|---|---|
| `open_app` (seguro), `open_url` (externo: confirma) | ver política | lista blanca de apps; solo https |
| `create_reminder`, `complete_reminder` (reversibles), `list_reminders` (consulta) | directo | EventKit, acceso completo a Recordatorios; el estado real se comprueba antes |
| `create_event` | reversible: directo | Calendario con acceso de escritura |
| `list_events` **[sin probar en iPhone]** | consulta: directa | Lee la agenda. **Opt-in** en Privacidad («Permitir que Viernes lea mi calendario»), apagado por defecto: ese interruptor es la autorización; se comprueba el estado real y hay un diagnóstico en Permisos |
| `find_contact` **[sin probar en iPhone]** | consulta: directa | Contactos de solo lectura. **Opt-in** en Privacidad, apagado por defecto |
| `compose_email` | reversible: directo | **Borrador** en Correo (`mailto:`). No envía: el usuario pulsa Enviar |
| `compose_message` | reversible: directo | Borrador en Mensajes (`sms:`) o WhatsApp (`whatsapp://send`). No envía |
| `call_phone` | reversible: directo | Abre el marcador (`tel:`); iOS pide su confirmación |
| `get_weather` | seguro | Open-Meteo, solo el nombre de la ciudad |
| `run_shortcut`, `ask_claude`, `device_info`, memoria | varios | ver SECURITY.md |

Evaluadas y **no** implementadas: enviar correos o mensajes sin tocar (iOS no lo permite sin conectar Gmail/Outlook por API: riesgo de inyección), archivos y fotos (sin caso de uso claro y con mucho riesgo de fuga hacia un cerebro en la nube), cámara, portapapeles (lectura = fuga silenciosa), alarmas (no hay API pública estable en iOS 18), ubicación (útil para «clima aquí», pendiente), ajustes de iOS (solo se puede abrir la pantalla de Ajustes de la app). No se usan APIs privadas.

## 3. Memoria contextual

Hoy **[hecho]**: tipos (preferencia, proyecto, dato, resumen), alta solo por orden explícita, manual o sugerencia aprobada, política por tipo, filtro de datos sensibles, recuperación léxica en español con raíz simple, fijar/editar/borrar, bloqueo opcional con Face ID, cifrado AES-256-GCM por registro. El prompt separa recuerdo / lo dicho / suposición / acción.

Propuesta **[pendiente, sin implementar]** (en orden de valor/riesgo):
1. **Caducidad**: campo opcional `expiresAt` en `MemoryItem` (compatible: JSON opcional) para recuerdos temporales («esta semana viajo a Cali»); purga al arrancar y aviso en Memoria.
2. **Entidades**: etiquetas tipadas (`persona:`, `proyecto:`) para relacionar recuerdos y recuperar por entidad.
3. **Recuperación semántica**: evaluar `NLEmbedding` (framework de Apple, en el dispositivo) para español antes de añadir dependencias; medir calidad y coste. No se afirma que funcione hasta probarlo.
4. **Consentimiento**: ya existe (sugerencias pendientes); se mantendría para cualquier extracción automática.
No se guardan conversaciones completas como memoria.

## 4. Proactividad: lo que iOS permite de verdad

- **Notificaciones locales** (`UNUserNotificationCenter`): recordatorios y resúmenes programados por el propio usuario. Funcionan con la app cerrada. Un «resumen de agenda cada mañana» necesitaría leer el calendario al programarlo y una notificación con texto fijo; **[pendiente]**.
- **Automatizaciones de Atajos** (hora, llegada a un lugar, apertura de una app): pueden ejecutar un atajo que abra Viernes con una pregunta mediante App Intents / `viernes://ask`. Se configuran en la app Atajos; Viernes no puede crearlas por sí sola. Los App Intents ya existen **[hecho, sin probar en iPhone]**.
- **BGAppRefreshTask**: iOS decide cuándo y cuánto; no sirve para ejecutar un modelo ni para conversar. No se usa.
- **Escucha permanente**: no es posible para una app de terceros con la app cerrada. «Viernes» solo con la app abierta; alternativa más cercana a «reemplazar a Siri»: Toque posterior → atajo «Hablar con Viernes», o «Oye Siri, Habla con Viernes».

## 5. Funciones avanzadas: análisis de impacto y riesgo (nada de esto está implementado)

Criterios: **impacto** para quien usa la app, **riesgo** (privacidad, seguridad, restricciones de iOS), **esfuerzo** y dependencias. «Cerebro en la nube» = lo que se procesa sale del teléfono.

| # | Función | Impacto | Riesgo | Esfuerzo | Notas y restricciones reales |
|---|---|---|---|---|---|
| 8 (memoria) | **Memoria contextual avanzada** (caducidad, entidades, búsqueda semántica) | Alto | Bajo–medio | M | Ya existe la base cifrada y el consentimiento. `expiresAt` opcional y etiquetas de entidad son cambios compatibles. La búsqueda semántica (`NLEmbedding`) debe medirse antes. |
| 5 | **Resúmenes diarios** | Medio–alto | Bajo | S–M | Lo viable en iOS: una **Automatización de Atajos** (hora del día) que abre Viernes con «resume mi día» (App Intent) y usa agenda + clima + tareas que ya existen. Una notificación local tendría texto fijo calculado al programarla. |
| 1 | **Modo misión** (plan visible → ejecución → informe) | Alto | Medio | M | Sobre el bucle actual: el modelo propone un plan, la UI lo muestra y el usuario aprueba una vez los pasos con efectos; el progreso se ve en tarjetas. Necesita límites (pasos, tiempo) y cancelación; un modelo pequeño planifica mal: pensado para el cerebro en la nube. |
| 3 | **Interrupciones naturales** | Alto | Medio | M | Interrumpir tocando ya funciona. Interrumpir **hablando** exige escuchar mientras se habla (sesión de audio con cancelación de eco, `voiceChat`) y distinguir eco de voz; hay que probarlo en dispositivo. |
| 4 | **Rutinas inteligentes** | Medio | Medio | S | Mediante Atajos y App Intents (iOS no deja a una app programarse sola ni escuchar siempre). Viernes puede ofrecer «plantillas» de atajos; no crearlas por su cuenta. |
| 6 | **Contactos y comunicaciones** | Medio | Bajo | S | Ya hay búsqueda de contactos y borradores. Falta: elegir entre varios contactos y preferir el canal. El envío real seguirá siendo del usuario. |
| 7 | **Investigación web** | Alto | Medio–alto | M | Riesgos: **inyección de instrucciones** desde páginas (el contenido web es dato, nunca orden) y privacidad (las consultas salen a un buscador; con el cerebro en la nube, también el contenido). Empezar con fuentes sin clave (Wikipedia, Open-Meteo) y mostrar siempre las fuentes. Los buscadores generales requieren una API con clave y sus propios términos. |
| 8 (docs) | **Análisis de documentos** | Medio–alto | Medio–alto | M | Extraer texto con PDFKit en el dispositivo y resumir con el cerebro activo; con la nube, el documento **sale del teléfono**: aviso y aprobación por documento. |
| 9 | **Visión por cámara** | Alto (efecto) | Medio | M–L | Un modelo de visión local no cabe en 6 GB junto al resto; implica cerebro en la nube con imágenes (privacidad, cuota gratuita) y permiso de cámara. |
| 11 | **Hogar inteligente** | Medio | Medio | S vía Atajos | Hoy ya posible con `run_shortcut` si el usuario crea atajos de Casa. HomeKit directo requiere una capacidad (entitlement) que puede no estar disponible con un Apple ID gratuito: **sin verificar**. |
| 12 | **Automatización entre dispositivos** | Bajo ahora | Bajo | S | Atajos + iCloud; Handoff exige más trabajo. Sin urgencia. |
| 10 | **Agente de Windows** | Medio | Alto | L | Diseñado en WINDOWS_AGENT.md. Requiere revisión de seguridad y, en un equipo corporativo, autorización de TI. |

**Orden recomendado** (mayor impacto con menor riesgo primero): (1) memoria con caducidad y entidades; (2) resumen diario por Atajos; (3) modo misión con plan aprobable; (4) interrupciones por voz, tras medir en dispositivo; (5) investigación web con fuentes sin clave y protección contra inyección; (6) documentos locales; después visión, hogar y multi-dispositivo; el agente de Windows al final.

## 6. Pendiente y riesgos

Probar todo en iPhone; plan declarativo opcional; caducidad y entidades en memoria; tarjeta de clima con datos estructurados; ubicación para «clima aquí»; resumen de agenda como notificación; agente de Windows (ver WINDOWS_AGENT.md).
