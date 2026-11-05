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

**Ejemplo pedido** — «revisa mi agenda de mañana, identifica mi primera cita y recuérdame salir con tiempo»: ronda 1 `list_events` (confirmación) → el modelo lee los eventos reales → ronda 2 `create_reminder` con la hora calculada (confirmación) → ronda 3 respuesta. La prueba `testReadCalendarThenCreateReminderChainsWithRealResultsAndTwoConfirmations` lo verifica con un motor de pruebas; con un modelo real no está probado, y un modelo pequeño puede planificar mal.

**Lo que NO es (todavía)**: no hay un planificador explícito con grafo de dependencias; la dependencia se resuelve por rondas (el modelo decide qué consultar antes de actuar). Un plan declarativo (lista de pasos con dependencias que el usuario aprueba de una vez) es una mejora posible **[pendiente]**.

## 2. Herramientas nativas de iOS

| Herramienta | Riesgo | Notas |
|---|---|---|
| `open_app`, `open_url` | seguro / sensible | lista blanca de apps; solo https |
| `create_reminder`, `complete_reminder`, `list_reminders` | sensible/sensible/seguro | EventKit, acceso completo a Recordatorios |
| `create_event` | sensible | Calendario en modo **solo escritura** |
| `list_events` **[nuevo, sin probar en iPhone]** | sensible | Lee la agenda. **Opt-in** en Privacidad («Permitir que Viernes lea mi calendario»), apagado por defecto; pide acceso completo a iOS solo en el primer uso; cada lectura pide confirmación |
| `find_contact` **[nuevo, sin probar en iPhone]** | sensible | Contactos de solo lectura. **Opt-in** en Privacidad, apagado por defecto |
| `compose_email` **[nuevo]** | sensible | **Borrador** en Correo (`mailto:`). No envía: el usuario pulsa Enviar |
| `compose_message` **[nuevo]** | sensible | Borrador en Mensajes (`sms:`) o WhatsApp (`whatsapp://send`). No envía |
| `call_phone` **[nuevo]** | sensible | Abre el marcador (`tel:`); iOS pide su confirmación |
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

## 5. Pendiente y riesgos

Probar todo en iPhone; plan declarativo opcional; caducidad y entidades en memoria; tarjeta de clima con datos estructurados; ubicación para «clima aquí»; resumen de agenda como notificación; agente de Windows (ver WINDOWS_AGENT.md).
