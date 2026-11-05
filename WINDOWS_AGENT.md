# WINDOWS_AGENT — arquitectura recomendada (NO implementada)

Objetivo: que Viernes pueda pedirle cosas a un agente en tu PC con Windows (consultar archivos autorizados, ejecutar comandos aprobados, tareas de desarrollo) y recibir los resultados. **Esto es solo diseño.** No hay servidor, no se abre ningún puerto y no se ha escrito código del agente. Nada de esto se ha probado.

## Principios

1. **Cero puertos públicos.** El PC nunca escucha en Internet.
2. **Nada de shell remota abierta.** Solo un catálogo cerrado de capacidades, cada una con esquema de argumentos.
3. **El teléfono es el dueño de la decisión.** Lo que modifica algo o es sensible se confirma en el iPhone con el texto exacto, como las herramientas actuales.
4. **Autenticación por dispositivo, no por contraseña.** Claves asimétricas, emparejamiento explícito, revocable.
5. **Mínimo privilegio y auditoría.** Usuario limitado, carpetas permitidas, registro de todo.
6. **El cerebro en la nube no debe ver contenido del PC sin que lo apruebes** (ver «Fugas»).

## Componentes

```
iPhone (Viernes)                         Windows (Agente de Viernes)
┌──────────────────┐   canal cifrado    ┌─────────────────────────────┐
│ ConversationEngine│ ───────────────── │ Servicio local (usuario     │
│ + herramientas    │  JSON-RPC firmado │ limitado, sin admin)        │
│   windows_*       │                   │  • verificador de firmas    │
│ ConfirmationCenter│                   │  • catálogo de capacidades  │
│ Clave en Secure   │                   │  • ejecutor en sandbox      │
│ Enclave           │                   │  • registro de auditoría    │
└──────────────────┘                    └─────────────────────────────┘
```

## Transporte (sin exponer puertos)

Opciones, de más a menos recomendada:
1. **Red privada WireGuard (p. ej. Tailscale)**: el PC y el iPhone se unen a una red privada; el agente escucha solo en la IP privada del PC. No hay puertos públicos. Dispositivo del trabajo: puede estar prohibido instalar VPNs; hay que consultarlo con TI.
2. **Túnel saliente con autenticación de acceso** (p. ej. Cloudflare Tunnel + Access): el PC abre una conexión saliente; el acceso exige identidad. Más piezas de terceros.
3. **Solo red local (Wi-Fi de casa)** con TLS mutuo: sin acceso fuera de casa.

Descartado: reenvío de puertos del router, DynDNS, descubrimiento sin autenticar en la LAN, HTTP sin TLS.

## Emparejamiento y autenticación

1. El agente muestra en el PC un **QR de un solo uso** con: huella (SHA-256) de su certificado, dirección privada y un token que caduca en 2 minutos.
2. Viernes genera una **clave P-256 en el Secure Enclave** (no exportable, `kSecAttrTokenIDSecureEnclave`) y envía su clave pública junto al token. El agente la guarda en su lista de dispositivos autorizados.
3. Conexión: **TLS 1.3 con la huella fijada** (la del QR; no se confía en autoridades públicas para esto).
4. Cada petición lleva `id`, `timestamp` (±30 s), `nonce` único y una **firma ECDSA** con la clave del Secure Enclave. El agente rechaza firmas inválidas, repetidas o fuera de ventana.
5. **Revocación**: desde el PC (eliminar el dispositivo) o desde Viernes (borrar la clave). Un interruptor general («Pausar agente») corta todo.

## Autorización: capacidades y niveles

El agente carga una **lista blanca** (archivo de configuración firmado/solo lectura para el usuario del servicio):

| Nivel | Ejemplos | Aprobación |
|---|---|---|
| Lectura | listar/leer archivos dentro de carpetas permitidas; `git status`; estado del sistema | automática dentro de las rutas permitidas; el resultado se muestra al usuario |
| Escritura | crear/editar archivos en carpetas permitidas; `git commit` | **confirmación en el iPhone** con la ruta y el diff/resumen exactos |
| Ejecución | comandos de una lista aprobada (`dotnet build`, `npm test`, `python script.py` de carpetas concretas) con argumentos validados por esquema | **confirmación en el iPhone** con la línea exacta; tiempo y salida máximos |
| Prohibido | shell arbitraria, borrar fuera de la papelera, tocar el registro, instalar software, leer fuera de las rutas, elevar privilegios | nunca |

Reglas técnicas: normalizar y resolver rutas (sin `..`, sin enlaces simbólicos que salgan de la carpeta), nada de pasar texto del modelo a `cmd`/PowerShell sin esquema (inyección), ejecución con **usuario sin privilegios** y en un **Job Object** de Windows (límites de CPU/memoria/tiempo, sin procesos huérfanos), variables de entorno mínimas, salida truncada.

## Protocolo

JSON-RPC 2.0 sobre WebSocket (o HTTPS con respuestas en flujo):
- `capabilities.list` → herramientas disponibles con su esquema y nivel.
- `capabilities.invoke {name, args, approvalToken?}` → resultado o progreso en flujo.
- `approval.request` / `approval.response`: el agente puede pedir la aprobación del teléfono; la aprobación va firmada y ligada a la petición exacta (no reutilizable).
Los resultados vuelven a Viernes como cualquier `ActionRecord`, con el mismo cuidado de «no inventar».

## Integración con Viernes

- Herramientas nuevas `windows_*` en el catálogo, **solo visibles si hay un PC emparejado y el interruptor está activo**, como `list_events`/`find_contact`.
- Reutilizan `ToolValidator` (esquemas) y `ConfirmationCenter` (hoja con el texto exacto). No se añade ningún camino que ejecute sin confirmación lo que no sea de solo lectura.
- Ajustes › «Agente de Windows»: emparejar, ver dispositivos, pausar, ver el registro.

## Fugas y privacidad

- Con el **cerebro en la nube** activo, el contenido que el agente devuelva (archivos, salidas) se entrega al modelo y **sale del teléfono**. Mitigaciones: modo «solo local» obligatorio para herramientas `windows_*` de lectura de archivos, o aprobación explícita por consulta («esto se enviará a Groq»); lista de rutas que nunca se leen (credenciales, claves, `.env`, perfiles de navegador).
- El agente no registra el contenido de los archivos, solo metadatos (hora, capacidad, ruta, resultado).
- Equipo corporativo: ejecutar un servicio con acceso a archivos puede contravenir la política de TI; **hay que pedir permiso**. En este equipo Defender ya bloquea ejecutables nuevos.

## Amenazas y respuestas

| Amenaza | Respuesta |
|---|---|
| Alguien en la red intenta usar el agente | sin puertos públicos; TLS con huella fijada; firma por dispositivo |
| Robo o clonación de la credencial del iPhone | clave no exportable en Secure Enclave; revocación; confirmaciones en el propio teléfono |
| Reproducción de una petición capturada | nonce único + ventana de tiempo + firma ligada al contenido |
| Inyección de instrucciones vía contenido de archivos o páginas | el contenido de herramientas es dato, no órdenes; lo que modifica algo exige confirmación con el texto exacto |
| Comando malicioso propuesto por el modelo | solo comandos de la lista blanca con argumentos validados; nada de shell |
| Escalada en el PC | usuario sin privilegios, Job Object, rutas permitidas |
| Fuga hacia el proveedor del cerebro en la nube | modo solo local o aprobación por consulta; rutas vetadas |
| Agente comprometido | registro de auditoría, interruptor de pausa, actualizaciones firmadas |

## Fases sugeridas (cuando se decida construirlo)

1. Agente de **solo lectura** en red privada, una carpeta de prueba, emparejamiento por QR y firma, registro. Probar en LAN.
2. Confirmaciones desde el iPhone y herramienta `windows_read_file` con rutas vetadas.
3. Ejecución de 2–3 comandos aprobados en Job Object.
4. Revisión de seguridad externa antes de ampliar nada.
