# COMMERCIAL_ARCHITECTURE — Viernes como plataforma de asistentes personales (diseño; **sin cobros ni servidor**)

**Estado honesto**: Viernes hoy es una app **local**: sin cuentas, sin servidor propio, sin facturación. Este documento evalúa cómo se convertiría en una plataforma comercial y qué cuesta en privacidad y en operación. **No se implementa ningún cobro, no hay precios y no se guarda ninguna clave maestra en la app.** Las cifras de costo dependen de proveedores que cambian sus tarifas: aquí solo hay dimensiones y fórmulas, no números.

## Lo que ya existe y sirve de base

Perfil independiente (`ProfileRegistry`), memoria, biblioteca y claves aisladas por perfil (`ProfileStorageLayout`, una clave de cifrado por perfil), personalidad configurable (`PersonalityConfig`), proveedor de IA propio (Groq, Gemini, OpenAI, Cerebras o local), voz configurable, herramientas autorizadas por perfil (`disabledTools`), autonomía, exportación/importación (`ProfileBundle`), consumo y presupuesto por perfil (`UsageSettings`), investigación web, Windows Companion y misiones: todo **por perfil y local**.

## Los dos caminos

1. **Local con claves del usuario** (hoy). El usuario trae sus claves de IA; Viernes no ve ni cobra nada. Costo operativo propio: **cero**; privacidad máxima. Límite: no hay cuentas, ni sincronización, ni soporte a otros usuarios más allá del iPhone.
2. **Plataforma con backend** (futuro). Cuentas, sincronización, proveedor de IA incluido en el plan, panel de administración. Cambia el modelo de privacidad: hay datos del usuario en un servidor.

## Backend (solo si se elige el camino 2)

| Pieza | Opciones a evaluar | Notas |
|---|---|---|
| Autenticación | Sign in with Apple (obligatorio si se ofrece otro inicio de sesión social), correo + contraseña con proveedor gestionado, passkeys | Sin guardar contraseñas propias |
| Identidad y datos | Una cuenta ⇒ N perfiles; cada perfil conserva su aislamiento | El servidor **no debe poder leer** memoria ni biblioteca: cifrado de extremo a extremo con una clave del usuario (derivada de un secreto que no sale del dispositivo) |
| Sincronización | `ProfileBundle` como formato, cifrado antes de salir; resolución de conflictos por perfil | Las claves de API del usuario no viajan |
| Proveedor de IA incluido | Servidor intermediario («proxy») que firma peticiones con SU clave maestra | **La clave maestra vive en el servidor, nunca en la app**; la app usa un token de sesión de corta duración con cuota |
| Cuotas y consumo | Contador por cuenta y por periodo en el servidor; la app muestra lo que el servidor informa | Hoy el consumo se mide en el teléfono (`UsageStore`) |
| Métricas | Eventos agregados y anónimos (versiones, errores, uso de funciones), sin contenido | Opt-in, documentado |
| Panel administrativo | Altas/bajas, plan, cuotas, auditoría de uso, borrado de cuenta | Acceso del personal con roles y registro; **sin acceso a contenido** |

## Planes (dimensiones, sin precios)

| Plan | Idea | Qué se limitaría |
|---|---|---|
| **Gratuito** | Todo local con claves propias; proveedor incluido (si existiera) con cuota baja | perfiles, biblioteca, adjuntos, solicitudes al proveedor incluido |
| **Premium** | Más capacidad personal y sincronización | más perfiles, biblioteca mayor, sincronización, cuota mayor |
| **Profesional** | Uso intensivo | cuotas altas, misiones avanzadas, compañero de Windows, exportaciones programadas |
| **Business** (opcional) | Equipos | perfiles administrados, políticas de herramientas por organización, auditoría exportable |

Los límites ya están centralizados como datos (`ProfileRegistry.maxProfiles`, `KnowledgeLimits`, `AttachmentLimits`, `UsageSettings`): un `PlanLimits` los sustituiría por valores según el plan sin tocar la lógica. **No se limita por plan**: la seguridad (confirmaciones, cifrado, contenido no confiable), la exportación y el borrado de los propios datos.

## Facturación (solo diseño)

Apple exige compras dentro de la app para contenido digital en iOS (StoreKit / suscripciones); el servidor validaría los recibos de la App Store. Cobros fuera de la app solo para lo que Apple permita (p. ej. servicios para empresas). **No se implementa nada de esto ahora**; antes hay que revisar las reglas vigentes de la App Store y las obligaciones fiscales del país.

## Costos operativos (qué hay que estimar antes de fijar un precio)

`costo mensual por usuario = inferencia (tokens × tarifa del proveedor) + voz (caracteres × tarifa) + búsqueda web (consultas × tarifa) + almacenamiento y sincronización + servidor, base de datos y correo + soporte + comisión de la tienda + impuestos`. La inferencia y la voz dominan y varían con el modelo elegido; por eso `UsageStore` y el presupuesto por perfil ya registran tokens reales. Hay que medir el uso real de usuarios de prueba antes de calcular un plan.

## Riesgos de privacidad (y decisiones recomendadas)

- Con backend, **dejar de ser «todo en el teléfono»** es un cambio de promesa: debe ser opt-in, explicado y reversible (exportar y borrar).
- El proxy de IA ve el texto de las conversaciones que pasan por él: política de retención mínima (no guardar contenido), contrato con los proveedores y aviso claro; alternativa: claves propias del usuario (camino 1).
- Datos de menores, datos sensibles (salud, finanzas) y transferencias internacionales: revisión legal (Habeas Data / LOPD / RGPD según países) antes de abrir al público.
- Un panel administrativo es un objetivo: roles mínimos, registro de accesos y **sin acceso a contenido por diseño**.
- Una brecha del servidor no debe exponer memoria ni documentos: cifrado de extremo a extremo.

## Siguientes pasos (decisión del dueño del producto)

1. Decidir camino 1 (local, claves propias) o 2 (backend).
2. Si es el 2: prototipo de cuentas + sincronización cifrada de `ProfileBundle` con un servicio gestionado y datos de prueba, **sin cobros**.
3. Medir costos con usuarios de prueba; recién entonces definir planes y precios.
4. Revisión legal y de reglas de la App Store antes de cualquier cobro.
