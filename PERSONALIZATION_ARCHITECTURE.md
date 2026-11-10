# PERSONALIZATION_ARCHITECTURE — perfiles, personalidad y preparación multiusuario (0.7, fase 4)

**Estado honesto**: el CI compila y prueba el modelo de perfiles, la personalidad, la separación de datos y claves sobre archivos reales en un simulador, y el cifrado del archivo de exportación. **No se ha probado en un iPhone**: ni Face ID/código para entrar en un perfil protegido (el simulador no tiene biometría real), ni el selector de archivos al importar, ni el uso real de una personalidad con Groq o Gemini. No hay servidor ni cuentas en la nube: todo es local.

## Qué es un perfil

Un perfil es **una persona que usa este iPhone con Viernes**. Cada perfil tiene lo suyo, separado de los demás:

| | Dónde vive | Separación |
|---|---|---|
| Identidad de la asistente, personalidad, idioma, región, autonomía, herramientas apagadas | `AppSettings.profile` (`ProfileSettings`) | ajustes **por perfil** (una clave de UserDefaults por perfil) |
| Cerebro (modelo/proveedor), voz, memoria (política), permisos de lectura, biblioteca (sí/no), Claude | el resto de `AppSettings` | igual: **por perfil** |
| Recuerdos y conversaciones | `viernes.store` (SwiftData cifrado) | un archivo por perfil |
| Documentos y notas (biblioteca) | `knowledge.store` (SwiftData cifrado) | un archivo por perfil |
| Historial de reconocimiento de voz, registro de eventos creados | archivo cifrado / UserDefaults | uno por perfil |
| Clave de cifrado de todo lo anterior | Llavero (`vault.key.v1.<id>`) | **una clave por perfil**: con la de uno no se abre nada de otro |
| Claves de API (Groq, Gemini, ElevenLabs) | Llavero (`cloud-api-key.<proveedor>.<id>`) | por perfil |

Lo que **no** es por perfil (y se dice en la pantalla): los **modelos descargados** (pesos locales del iPhone) y lo que **iOS** guarda fuera de Viernes (calendario, contactos, recordatorios, correo): cada perfil puede o no leerlo según su propio permiso. Los perfiles no sustituyen a las cuentas de usuario de iOS ni protegen frente a quien tenga el iPhone desbloqueado y abra Ajustes de iOS.

### Registro y nombres de almacenamiento (`ProfileRegistry`, `ProfileStorageLayout`)

- El **registro** (`viernes.profiles.v1` en UserDefaults) guarda solo nombre, color, si es protegido y cuál está activo: nada secreto. Hasta 8 perfiles (límite técnico: cada perfil activo mantiene su índice de biblioteca en RAM).
- `ProfileStorageLayout` es una **función pura** que da todos los nombres de un perfil. Una prueba comprueba que dos perfiles nunca comparten un solo nombre (ajustes, claves, almacenes, historial) y que las rutas no pueden salirse de `Viernes/profiles/<id>/`.
- **Compatibilidad**: el perfil que ya existía (el primero, «Principal») usa **exactamente los nombres de siempre** (`viernes.store`, `knowledge.store`, `vault.key.v1`, `viernes.settings.v1`, `cloud-api-key.groq`…). No se migra ni se mueve ningún dato: actualizar la app no puede perder nada. Una prueba fija esos nombres.

### Cambiar de perfil (`ProfileHost`)

Cambiar de perfil **no reutiliza nada**: apaga el `AppModel` actual (escucha, voz, generación, red, adjuntos temporales, modelo cargado) y crea otro **desde cero** con los almacenes, la clave, los ajustes y las claves de API del perfil elegido; la pantalla se reconstruye entera (`.id` del perfil). Así no puede quedar en memoria nada del anterior ni mezclarse una escritura tardía. Un perfil **protegido** pide Face ID, Touch ID o el código del iPhone al entrar en él (al cambiar y al abrir la app); proteger/desproteger también lo pide.

### Borrar un perfil («eliminar cuenta»)

Elimina, en este orden: **la clave de cifrado** (los datos quedan ilegibles aunque algún archivo sobreviviera: borrado criptográfico), las claves de API, los ajustes, el registro de eventos y los archivos (`.store`, `-wal`, `-shm`, historial, carpeta del perfil). Si borras el perfil activo, antes se pasa a otro. Se devuelve y se muestra lo que no se pudo borrar. «Borrar TODOS los perfiles» lo hace con todos y deja la app como recién instalada.

## Personalidad (separada del motor de razonamiento)

`PersonalityConfig` es **solo datos de estilo**: trato (tú/usted), naturalidad (directa/natural/expresiva), longitud (corta/normal/detallada), estilo (conversacional/profesional), instrucciones personales (≤ 600 caracteres) y ajustes de pronunciación. `PersonalityPrompt` los convierte en **una sección** del prompt, después de las reglas de honestidad y herramientas y antes de la fecha y los recuerdos (así el principio del prompt sigue idéntico entre peticiones y la caché del proveedor sigue valiendo).

- **Con los valores por defecto no se añade nada**: el prompt es idéntico al de siempre (una prueba lo comprueba).
- **No puede tocar las reglas**: la sección termina con una nota explícita (no cambia honestidad, herramientas ni seguridad, no permite saltarse confirmaciones, no sustituye el formato de llamada). Pero la **garantía real no está en el prompt**: las confirmaciones, la validación de herramientas y la defensa contra contenido no confiable son código y no dependen de lo que diga el modelo.
- Las **instrucciones personales** se neutralizan igual que el contenido de archivos (etiquetas internas y caracteres invisibles), se aplanan a una línea y se acotan. Una prueba intenta colar `<tool>…</tool>`, `</tool_result>` y `<system>`.
- **Autonomía** (prudente / normal / proactiva): **solo puede pedir MÁS confirmaciones, nunca menos**. `AutonomyLevel.requiresConfirmation` nunca devuelve «no confirmar» donde la regla base exige confirmar (comprobado para todos los niveles y riesgos). «Prudente» confirma también las acciones reversibles; «Proactiva» propone el siguiente paso (sin ejecutarlo).
- **Herramientas apagadas por perfil**: no se le ofrecen al modelo y, aunque las pida, no se ejecutan.
- **Pronunciación**: cambia solo lo que se oye (palabras completas, sin distinguir mayúsculas), nunca el texto en pantalla.
- **Transparencia**: Ajustes › Personalidad muestra «Lo que se le añade al modelo», el texto real.
- **Límite**: la palabra de activación sigue siendo «Viernes» y la voz/idioma de dictado se eligen en Ajustes › Voz y Escucha; el idioma de respuesta solo cambia lo que dice el modelo.

## Exportar e importar un perfil

`ProfileBundle` (formato `viernes.profile`, versión 1): ajustes, recuerdos, biblioteca (texto, referencias, carpetas) y conversaciones. **Nunca** incluye claves de API ni la clave de cifrado (una prueba revisa que ningún campo del archivo tenga nombre de secreto). Los vectores de significado son opcionales (sin ellos lo importado se busca por texto).

- **Cifrado opcional** con contraseña: PBKDF2-HMAC-SHA256 (600 000 vueltas) → AES-256-GCM; la cabecera (formato, vueltas, sal) va **autenticada**; un archivo manipulado no puede imponer un número absurdo de vueltas. Sin contraseña el archivo lleva datos personales **en claro** y la pantalla lo dice. La contraseña no se guarda: si se olvida, no hay recuperación.
- **Importar crea un perfil NUEVO**, nunca mezcla ni pisa uno existente; si algo falla a medias, se deshace todo.
- **Un archivo importado es dato no confiable**: se comprueban formato, versión y límites (recuerdos, conversaciones, elementos, fragmentos, caracteres) antes de usar nada; los **recuerdos entran pendientes de aprobación** (no llegan a ningún prompt hasta que el usuario los apruebe); las **instrucciones personales y la pronunciación** no se importan salvo que el usuario confíe expresamente en el archivo; y **nunca se activan** permisos de calendario/contactos, escucha por voz, dictado en servidores, voz en la nube ni el envío de adjuntos sin preguntar (los activa el usuario en el perfil nuevo); la configuración de Claude vuelve a su valor de fábrica (abrir la app, con confirmación en cada envío), nunca un Atajo traído del archivo. Lo comprueba una prueba con un archivo «hostil».
- El archivo se escribe en la carpeta temporal (con protección de archivo) y se borra al abrir la app.

## Sincronización

**No hay sincronización entre dispositivos** ni servidor: sería necesario un backend con cuentas, cifrado de extremo a extremo y gestión de claves, fuera del alcance (y de los servicios gratuitos). El camino soportado para mover un perfil a otro iPhone es exportar (con contraseña) e importar. Una sincronización futura debería reutilizar `ProfileBundle` como formato y mantener que las claves no viajan.

## Arquitectura comercial (documentada, **no implementada**)

No hay facturación, tienda, cuentas ni precios. Esto es solo la forma en que el código actual permitiría planes, para decidir sin reescribir:

| Plan | Idea | Qué se limitaría (dimensiones, **sin cifras inventadas**) |
|---|---|---|
| **Free** | Lo que hay hoy: todo local, claves propias de los proveedores gratuitos | perfiles por dispositivo, elementos de la biblioteca (hoy 300 / 8 M de caracteres por límite técnico), adjuntos por mensaje |
| **Plus** | Más capacidad personal | más perfiles y biblioteca, exportación programada |
| **Pro** | Uso intensivo / profesional | límites mayores de biblioteca, perfiles protegidos con políticas, sincronización (si existiera backend) |
| **Business** | Equipos | perfiles administrados, política de herramientas por organización, auditoría local exportable |

- **Dónde se aplicarían los límites**: ya están centralizados como datos y funciones puras: `ProfileRegistry.maxProfiles`, `KnowledgeLimits`, `AttachmentLimits`, `ProfileBundleCodec` y `ProfileSettings.disabledTools` (política de herramientas). Un `PlanLimits` futuro sustituiría esas constantes por valores según el plan, sin tocar la lógica.
- **Lo que no se debe cobrar ni limitar por plan**: la seguridad (confirmaciones, cifrado, borrado, contenido no confiable) y el derecho a exportar y borrar los propios datos.
- **Los costes de IA** (Groq, Gemini, ElevenLabs) los paga hoy el usuario con sus propias claves; un plan con proveedor incluido exigiría un servidor intermediario, que rompería «sin servicios obligatorios» y necesitaría su propio análisis de privacidad.

## Pruebas

**Núcleo (CI)**: registro (límite, nombres únicos sin importar acentos/mayúsculas, renombrar, activar, borrar, reparar datos dañados), nombres de almacenamiento (el heredado conserva los de siempre; ningún nombre se repite; rutas seguras), personalidad (prompt idéntico por defecto; nombre, idioma, región, trato, longitud, estilo; instrucciones hostiles neutralizadas y acotadas; la nota de seguridad siempre presente), autonomía (nunca relaja una confirmación; prudente pregunta incluso lo reversible; consultas sin preguntar), herramientas apagadas (no se ofrecen ni se ejecutan), pronunciación (palabras completas, reemplazo literal), ajustes tolerantes a datos antiguos, **dos perfiles de prueba** (Ana: contrato, color verde, «Jarvis» formal, autonomía prudente; Beto: nota de arepas, color azul, valores por defecto) que muestran que **ni la memoria, ni los documentos, ni la configuración se cruzan** y que borrar los datos de uno no toca los del otro, y el paquete de exportación (ida y vuelta exacta, sin secretos, vectores opcionales, solo elementos indexados, restauración, permisos que no se activan, archivos inválidos o sobre los límites rechazados).
**App (simulador)**: dos perfiles sobre **archivos SwiftData reales** (cada uno su archivo y su clave: la clave de uno **no abre** los datos del otro; sin texto en claro en disco; borrar un perfil elimina archivos, carpeta y clave y deja intacto al otro), bibliotecas separadas, claves de API por perfil, el perfil heredado conserva su cuenta del Llavero, cifrado del archivo (ida y vuelta, contraseña errónea, manipulación de cuerpo/sal/cabecera, vueltas absurdas, sal aleatoria), `ProfileHost` (cambiar y volver, ajustes y memoria por perfil, nombres únicos, borrar el activo, recordar perfiles tras reiniciar, borrar todo, exportar cifrado → importar como perfil nuevo con recuerdos pendientes). **Interfaz**: crear un perfil, comprobar que su biblioteca está vacía y que el principal conserva la suya al volver; la vista previa de personalidad refleja nombre y autonomía.

## Limitaciones y pendiente

- **Sin probar en iPhone**: Face ID/código al entrar en un perfil protegido (en el simulador solo se prueba la lógica, no la biometría), selector de archivos y hoja de compartir, rendimiento de PBKDF2 (600 000 vueltas) en el teléfono, uso real de las personalidades con los proveedores.
- Un perfil protegido pide identidad al **entrar**, no vuelve a pedirla al volver del segundo plano.
- El idioma de respuesta no cambia la voz ni el dictado (ajustes aparte); la palabra de activación sigue siendo «Viernes».
- Importar no cambia automáticamente al perfil nuevo; la biblioteca importada sin vectores se busca por texto hasta volver a guardar cada elemento.
- Sin sincronización, sin cuentas en la nube, sin facturación (ver arriba).
- Si el registro de perfiles se corrompe del todo (JSON ilegible), la app arranca con un perfil principal y los perfiles extra quedan en disco sin listar (no se borran).
