# HOME_ASSISTANT_ARCHITECTURE — domótica con Home Assistant (diseño; **sin implementar**)

**Estado honesto**: solo es arquitectura. No hay código de domótica en Viernes: no se implementa control hasta contar con una instancia de Home Assistant de pruebas y poder verificar cada paso. Nada de esto es obligatorio ni se activa solo.

## Por qué Home Assistant

Reúne luces, sensores, termostatos, escenas y automatizaciones de muchas marcas detrás de **una API local documentada** (REST y WebSocket) con **tokens de acceso de larga duración** que el usuario crea y puede revocar. Viernes no habla con cada marca: habla con la casa del usuario.

## Principios

1. **Opcional y por perfil**: un perfil sin Home Assistant no ve nada de esto; cada perfil tiene su URL y su token.
2. **Local primero**: URL en la red local (HTTPS con huella fijada como el Companion, o un nombre `.local`); acceso remoto solo mediante lo que el propio usuario configure en Home Assistant (VPN o su nube), nunca con puertos abiertos desde Viernes.
3. **El token es un secreto**: Llavero del perfil, borrado con el perfil; nunca en ajustes, registros ni prompts.
4. **Lista blanca de entidades**: el usuario elige qué entidades (luces del salón, termostato…) ve Viernes; el resto no existe para el asistente. Por defecto, ninguna.
5. **Acciones por riesgo** (misma tabla que las herramientas actuales):
   - *Consulta* (estado de una luz, temperatura, sensor de puerta): sin confirmación.
   - *Reversible de bajo riesgo* (encender/apagar luces, subir/bajar temperatura dentro de un rango, activar una escena marcada «segura»): sin confirmación **solo si el usuario lo pidió claramente**; con confirmación si el modo de autonomía es «prudente».
   - *Sensible* (cerraduras, alarma, garaje, calefacción por encima de un límite, apagar equipos críticos): **siempre confirma** y nunca desde una orden surgida de contenido de terceros.
6. **Contenido no confiable**: los nombres y estados que devuelve Home Assistant son datos; un nombre de entidad con una instrucción no puede ejecutar nada (misma defensa que adjuntos, biblioteca y web).
7. **Registro de acciones**: qué se pidió, qué entidad, qué respondió Home Assistant; sin guardar audio ni conversaciones.
8. **Nunca se afirma lo que no se verificó**: «encendí la luz» solo si la llamada devolvió éxito y, cuando se pueda, el estado posterior lo confirma.

## Arquitectura propuesta

- `HomeAssistantProtocol` (núcleo, puro y probado): construcción de peticiones (`GET /api/states/<entity>`, `POST /api/services/<dominio>/<servicio>`), análisis de estados, tabla de dominios/servicios permitidos y su riesgo, límites de rango.
- `HomeAssistantClient` (app): URLSession con fijación de huella; token del Llavero.
- Herramientas `home_state(entity)` y `home_action(entity, action, value?)` con el mismo flujo de validación y confirmación que el resto.
- Pantalla «Casa»: URL, huella, token, selección de entidades visibles y su riesgo, prueba de conexión, historial de acciones.
- Escenas y automatizaciones: Viernes **dispara** escenas/automatizaciones existentes (`scene.turn_on`, `automation.trigger`); no las crea ni las edita.

## Riesgos y cómo se tratan

| Riesgo | Mitigación |
|---|---|
| Orden maliciosa (voz, texto de un documento, página web) que abre una cerradura | Las cerraduras y alarmas no son una herramienta accesible por defecto; siempre confirman; el contenido de terceros marca la respuesta como no confiable |
| Token robado | Llavero local, revocable desde Home Assistant; fijación de huella; rango de red local |
| Entidad equivocada por homónimos | Lista blanca; ambigüedad ⇒ pregunta, no adivina |
| Acción repetida por un reintento | Sin reintentos automáticos de acciones; solo de consultas |
| Dependencia | Viernes funciona igual sin Home Assistant |

## Criterios de aceptación para implementarlo

Instancia de pruebas de Home Assistant; pruebas del protocolo y de la tabla de riesgo en el núcleo; prueba de que sin entidades autorizadas no se ofrece ninguna herramienta; prueba de que cerraduras/alarmas piden confirmación aunque el usuario haya elegido autonomía «proactiva»; verificación en el iPhone con una luz real antes de dar la fase por terminada.
