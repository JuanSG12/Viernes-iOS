# Viernes Companion para Windows (prueba de concepto, 0.1)

Un servicio que instalas **tú** en tu PC para que Viernes (en tu iPhone, en tu misma red local) consulte lo que tú autorices. Sin dependencias: solo Node.

## Qué puede hacer (y nada más)

| Herramienta | Qué hace | Límite de seguridad |
|---|---|---|
| `files/search` | busca archivos por nombre (o texto) | solo carpetas que autorizas con `allow-folder`; sin enlaces simbólicos, ocultos, `.git`, `node_modules` ni nombres con pinta de secreto (`.env`, `*.pem`, `id_rsa`, `password`…) |
| `files/read` | lee el comienzo (20 KB) de un archivo de texto | misma carpeta y mismos filtros; rutas absolutas y `..` rechazadas; se comprueba la ruta real |
| `processes` | lista procesos (nombre, PID, memoria) | solo lectura, comando fijo (`tasklist`) |
| `github/runs` | últimas ejecuciones de Actions de un repositorio | solo repositorios que autorizas con `allow-repo`; usa tu `gh` ya con sesión; argumentos fijos |
| `scripts/run` | ejecuta un script **aprobado** | el iPhone solo manda un NOMBRE; el script y su huella SHA-256 los apruebas tú con `allow-script`; si el archivo cambia se bloquea; cada ejecución pide confirmación (s/n) **en el PC**; sin argumentos |
| `outbox` | mensajes del PC al iPhone | `node server.js send "texto"`; el iPhone los recoge (iOS no permite empujarlos sin un servidor externo) |

**No existe «ejecutar un comando»**: nada de lo que manda el iPhone llega a un intérprete.

## Seguridad

- **HTTPS con certificado propio**; el iPhone fija su huella SHA-256 al emparejarse (no confía en autoridades del sistema).
- **Solo red local**: rechaza cualquier dirección que no sea privada (10.x, 172.16–31.x, 192.168.x, 169.254.x, loopback, ULA/link-local IPv6). No abras el puerto en el router; la regla de firewall de `setup.ps1` es `-RemoteAddress LocalSubnet`.
- **Emparejamiento** con un código de 8 dígitos de **un solo uso**, que vale 2 minutos y muere tras 5 fallos.
- **Tokens revocables** (32 bytes aleatorios): solo se guarda su huella SHA-256; se revocan desde el iPhone (`DELETE /v1/pair`) o en el PC (`revoke <id>`).
- **Límites**: cuerpo ≤ 8 KB, 120 peticiones por minuto y dirección, tiempos de espera.
- **Auditoría** (`audit.log`): cada petición con ruta, resultado y token; **nunca** contenido de archivos ni el token.
- La carpeta de datos (`%APPDATA%\ViernesCompanion`) queda solo para tu usuario (ACL) porque guarda el certificado y su clave.

## Uso

```powershell
pwsh -File setup.ps1                                   # certificado propio + huella (no necesita administrador)
node server.js allow-folder docs C:\ruta\a\documentos  # solo lectura
node server.js allow-repo JuanSG12/Viernes-iOS         # opcional
node server.js start --pair                            # servicio + código de emparejamiento
```

En el iPhone: Ajustes › Windows Companion → dirección del PC, puerto, **huella** (compárala con la del PC) y código.

## Pruebas

`node --test companion/windows/test/companion.test.js` (9 pruebas: red local, emparejamiento de un solo uso y caducidad, tokens y revocación, recorrido de rutas y secretos, lista blanca de GitHub y scripts con hash y confirmación, bandeja, límites y auditoría). Corren en el CI de GitHub y se verificaron aquí en Windows con el certificado real que crea `setup.ps1`.

## Límites honestos

- **Prueba de concepto**: no está empaquetado como servicio de Windows; se inicia a mano con `node server.js start`.
- Probado contra clientes de prueba en Node, **no desde un iPhone real**: la fijación de huella y el permiso de red local de iOS solo se pueden comprobar en el teléfono.
- Una página o archivo del PC puede contener texto malicioso: Viernes lo muestra como dato y no lo trata como orden. Las herramientas del compañero no están conectadas todavía al asistente (solo a la pantalla Windows Companion); conectarlas exigiría tratarlas como contenido no confiable, igual que internet.
- No hay protección contra alguien que ya controle tu PC o tu red local.
