# CLAUDE_INTEGRATION — qué es posible, qué no, y qué hace Viernes

**Conclusión corta**: una suscripción de Claude **no** da acceso a una API para apps de terceros. Viernes **no** integra Claude "por dentro". Ofrece dos vías oficiales y un adaptador modular, y la interfaz dice siempre cuál se usa y qué NO ocurre.

## Reglas que cumple el proyecto

- Sin API key de Anthropic, sin `api.anthropic.com`, sin cabeceras de autenticación (lo vigilan `scripts/static-check.ps1` y `SecurityTests.testSourceContainsNoAnthropicKeysOrEndpoints`).
- No se extraen credenciales, no se manipulan sesiones, no se intercepta tráfico, no se eluden límites de uso.
- No se confunde Claude Code con una API.
- Nunca se afirma «Claude está integrado» si solo se abrió su app.

## Evaluación de cada opción

| Opción | ¿Sirve para integrar Claude en Viernes? | Detalle |
|---|---|---|
| **API de Anthropic** | Sí, pero **de pago aparte** y fuera de la suscripción | Descartada por requisito. Dejada como futura extensión (ver adaptador). |
| **Claude Code** | **No** | Es una herramienta de desarrollo (CLI/IDE/web), no una API general. Sus límites y su autenticación son de su propio cliente; reutilizarlos desde otra app sería construir una integración no autorizada. |
| **Claude Code Remote Control** | **No para este objetivo** | Permite continuar una sesión de Claude Code que corre en tu equipo desde la app móvil; depende de que ese equipo esté encendido (justo lo que no quieres) y no ofrece un endpoint a apps de terceros. *(Descripción general; no verifiqué sus detalles en esta sesión.)* |
| **Claude Mobile (app)** | **Sí, como destino externo** | Viernes puede abrirla. La conversación ocurre en Claude; Viernes no la ve. |
| **Claude Voice (modo de voz de la app)** | **No** | No hay un punto de integración documentado para apps externas. |
| **Enlaces oficiales `claude://`** | **Parcial** | Documentados para la app iOS/Android: `claude://code`, `claude://code/new?q=…&mode=…&repo=…` (requieren acceso a Claude Code en tu cuenta). Para un chat normal **no hay ruta documentada**. Viernes usa `claude://` solo para abrir la app. |
| **Enlaces universales `https://claude.ai/new?q=…`** | **Incierto** | El prefill `?q=` es conocido en la web. Que la app iOS intercepte el enlace universal **no está documentado**: se prueba en iPhone. Si no abre la app, abrirá el navegador. |
| **App Intents / Atajos de Claude** | **Sí, es la vía más prometedora** | La app de Claude expone la acción **«Ask Claude»** (Atajos, Siri, Spotlight, menú Compartir; iOS 18+), con la propia suscripción del usuario y contando para sus límites. La documentación **no dice** si devuelve la respuesta como texto a pasos posteriores del atajo. |
| **Siri** | Indirecto | Siri puede ejecutar el atajo o la acción «Ask Claude». Viernes no puede "escuchar a Siri". |

## Modos implementados (`ClaudeMode`)

### 1. Desactivado (por defecto)
Todo con el modelo local. La herramienta `ask_claude` ni siquiera se ofrece al modelo.

### 2. Abrir la app de Claude (`openApp`)
- Al usar `ask_claude` (siempre con **confirmación**), Viernes abre `https://claude.ai/new?q=<pregunta>`; si no se pudiera construir, `claude://`.
- **Qué ocurre de verdad**: se abre Claude (app o navegador). **Viernes no recibe ni lee la respuesta.** El resultado de la herramienta que ve el modelo y el usuario lo dice así. Los textos de la UI incluyen «NO integra Claude en Viernes».
- **A verificar en iPhone**: si la pregunta llega precargada en la app.

### 3. Atajo «Ask Claude» (`shortcut`)
Configuración (una sola vez, manual — no se pueden crear atajos por código sin la acción del usuario):

1. Abre **Atajos** → «+» → nombra el atajo exactamente como en Viernes › Claude (por defecto `Preguntar a Claude`).
2. Acciones: **Recibir entrada de atajo** (tipo Texto) → **Ask Claude** (app de Claude; usa la entrada como pregunta) → **Detener y dar resultado** (con el resultado de «Ask Claude»).
3. En Viernes: Configuración › Claude › «Atajo “Ask Claude”».

Flujo: Viernes → `shortcuts://x-callback-url/run-shortcut?name=…&input=text&text=…&x-success=viernes://claude-result?nonce=N&x-cancel=…` → Atajos ejecuta → si el atajo devuelve texto, Atajos abre `viernes://claude-result?nonce=N&result=<texto>` → Viernes lo muestra etiquetado **«Claude (Atajo)»** y lo añade al contexto de la conversación.

Seguridad del retorno:
- Cada petición lleva un **nonce** aleatorio; solo se acepta el resultado de **una** petición pendiente, **vigente 10 min**; cualquier otro `claude-result` (p. ej. de una web maliciosa) se ignora (prueba `testClaudeDisabledModeRefusesAndIgnoresUnsolicitedResults`).
- Todos los valores van codificados a mano (`ClaudeLinkBuilder.encode`), sin posibilidad de inyectar parámetros.
- Los mensajes con datos sensibles no se envían (`ToolValidator`).

**Honestidad del resultado**: «Pedí al Atajo que consulte a Claude. Si devuelve texto, lo mostraré». Si el atajo no devuelve nada, Viernes lo dice y no inventa la respuesta.

**A verificar en iPhone** (no documentado por Anthropic): que «Ask Claude» exponga su respuesta como salida utilizable, que x-callback devuelva `result` en la URL, y límites de longitud de URL para respuestas largas. Si «Ask Claude» no devolviera texto, este modo seguirá sirviendo como «abrir Claude con la pregunta», igual que el modo 2.

## Adaptador modular para una futura integración autorizada

`ClaudeCoordinator.ask(_:)` es el único punto por el que sale una pregunta. Para una integración oficial futura (p. ej. una API que Anthropic habilite para suscriptores, o un App Intent con salida tipada):

1. Añade un caso a `ClaudeMode` y su `honestDescription`.
2. Implementa el caso en `ClaudeCoordinator.ask` devolviendo `ToolOutcome` con lo que **realmente** ocurrió.
3. Si hay credenciales, guárdalas en `KeychainStore`, nunca en código o UserDefaults.
4. Mantén la confirmación del usuario y el filtro de datos sensibles.

## Diferencias entre modos (resumen para el usuario)

| | Local | Abrir app de Claude | Atajo «Ask Claude» |
|---|---|---|---|
| ¿Funciona sin internet? | ✅ | ❌ | ❌ |
| ¿Viernes lee la respuesta? | ✅ | ❌ | ⚠️ solo si el atajo la devuelve |
| ¿Usa tu suscripción de Claude? | — | ✅ (en la app) | ✅ (en la app) |
| ¿Sale texto del teléfono? | ❌ | ✅ hacia Claude | ✅ hacia Claude |
| ¿Hay API key? | ❌ | ❌ | ❌ |
| Estado | Implementado | Implementado, sin probar | Implementado, sin probar; depende del comportamiento de «Ask Claude» |

## Fuentes
- <https://support.claude.com/en/articles/10263469-using-claude-app-intents-and-shortcuts-on-ios> — «Ask Claude», widget, control de foto; iOS 18+. No menciona esquema de URL ni salida de texto.
- <https://support.claude.com/de/articles/14898120-offnen-sie-die-claude-mobile-app-mit-einem-link> — esquema `claude://` y rutas de Claude Code.
