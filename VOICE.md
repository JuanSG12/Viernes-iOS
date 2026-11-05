# VOICE — voz, activación, Siri

Nada de esto se ha probado todavía en un iPhone (ver [INSTALL.md](INSTALL.md#pruebas-que-requieren-iphone-físico)).

## Reconocimiento de voz (entrada)

**Implementado (v0.1)**: framework `Speech` con `SFSpeechRecognizer` y `AVAudioEngine`.

| Aspecto | Cómo funciona |
|---|---|
| Idioma | Español. Preferencia configurable (es-CO por defecto). Se elige la primera variante (es-CO, es-MX, es-US, es-419, es-ES) que tenga **reconocimiento en el dispositivo**. |
| Privacidad | `requiresOnDeviceRecognition = true` cuando el dispositivo lo soporta. Si **ninguna** variante lo soporta, Viernes **no** usa los servidores de Apple a menos que lo actives en «Escucha y activación › Permitir reconocimiento de Apple por internet»; en su lugar muestra cómo descargar el dictado. **Función que depende de internet**: solo ese modo opt-in. |
| Transcripción | Resultados parciales en vivo (se muestran sobre el núcleo); puntuación automática en modo comando. |
| Fin de frase | `SilenceDetector`: nivel RMS (dBFS) con suelo de ruido adaptativo; cierra tras 1,3 s de silencio habiendo hablado ≥ 0,25 s; 7 s sin voz = «no escuché»; tope de 40 s. Además, volver a tocar el botón cierra la frase al instante. |
| Interrupción | Tocar el núcleo o el botón (parar de hablar / interrumpir respuesta / cancelar pensamiento). |
| Permisos | Micrófono y reconocimiento se piden solo al primer uso, tras el onboarding que explica para qué. Denegado ⇒ mensaje y botón a Ajustes. |
| Errores | Códigos benignos (1110 «sin voz», 301 «cancelado») se tratan como fin normal; el resto se muestran y el núcleo pasa a *Error* 2,5 s. |
| Eficiencia | Un solo `AVAudioEngine`; tap de 1024 muestras; cálculo de RMS en el hilo de audio y salto a `@MainActor`. |

**Evaluado y no incluido aún**
- **`SpeechAnalyzer`/`SpeechTranscriber` (iOS 26)**: soporta español con modelos descargables (`AssetInventory`) y suele ser más preciso/rápido que `SFSpeechRecognizer` según fuentes de terceros; no lo implementé sin poder compilarlo/probarlo. Está en la hoja de ruta como motor preferente en iOS 26+.
- **Whisper en Core ML / MLX**: mejor tolerancia a ruido y a acentos, pero ~40 MB–1,5 GB extra, más batería y sin streaming nativo. Útil si la precisión de Apple no basta; no necesario para v0.1.

## Síntesis de voz (salida)

**Implementado**: `AVSpeechSynthesizer` — voces del sistema, 100 % locales (por defecto). Opcionalmente, voz neuronal de ElevenLabs en la nube (ver más abajo).

- **Selección automática** (`VoiceRanker`): solo español; puntaje por variante (es-CO ≫ es-MX/es-US/es-419 > otras latinas > es-ES), femenina, y calidad **Premium > Mejorada > Estándar**. Se penalizan las voces *eloquence* y de novedad (suenan robóticas). Si descargas una voz Premium, será la elegida.
- **Ajustes**: voz, velocidad (0,30–0,65), volumen, tono (0,7–1,3), escala de pausas (0–2,5×), hablar sí/no.
- **Naturalidad**: el texto se limpia antes de hablar (sin markdown, emojis ni URLs), se divide en frases con pausas distintas según puntuación y párrafos, y **empieza a hablar en cuanto hay una frase completa** mientras el modelo sigue generando (`SentenceStreamer`).
- **Interrupción y gestión de audio**: `stop()` inmediato; sesión `playAndRecord` con altavoz por defecto y Bluetooth permitido; al salir de la app se detiene todo.
- **Voz «elegante, madura, natural»**: depende de **las voces instaladas** en el iPhone. Las Premium de Apple son notablemente mejores que las estándar; es la mayor palanca de calidad sin cambiar código. No se imita la voz de ningún personaje.

**Voz neuronal en la nube (opcional, ElevenLabs)** — añadida en 0.2.0, **sin probar en dispositivo**.
- Ajustes › Voz y habla › «Voz neuronal»: clave del usuario (Llavero), lista de sus voces (`GET /v1/voices`), elección con muestra, e interruptor. Apagada por defecto.
- Cada frase (ya limpiada por `SpeechText`) se envía a ElevenLabs por HTTPS (`POST /v1/text-to-speech/{voice_id}`, mp3) y se reproduce con `AVAudioPlayer`. Se piden como máximo 2 frases a la vez porque el plan gratuito limita la concurrencia.
- **Respaldo**: si ElevenLabs falla (sin conexión, cuota, plan, clave), esa frase se dice con la voz del sistema, se avisa una vez y, si el error es de configuración, la nube se suspende hasta cambiar los ajustes.
- **Lo que sale del teléfono**: solo el texto que Viernes dice. No se envía audio del micrófono.
- **Límites que no pude verificar**: las fuentes contradicen qué voces y qué acceso por API incluye el plan gratuito, y cuántos créditos cuesta cada carácter. La app lo comprueba en vez de suponerlo: si una voz exige plan de pago, el error lo dice y se elige otra. La cuota mensual es corta y el plan gratuito no está pensado para uso comercial.
- **Español**: el acento depende de la voz y del modelo (`eleven_flash_v2_5` por defecto); hay que probar varias voces.
- No se imita la voz de ningún personaje ni actor: se usan voces genéricas de la lista de la cuenta.

**Evaluado y no incluido aún**
- **Kokoro (82 M parámetros, Apache 2.0)** local: investigado para 0.2.0 y **descartado por ahora**. Solo trae 3 voces en español (una femenina, `ef_dora`) y su documentación advierte soporte «escaso» fuera del inglés; `kokoro-ios` (MIT) solo incluye el conversor de texto a fonemas para inglés; el único para español es espeak-ng, cuyo paquete Swift es GPLv3 (incompatible con una app sin licencia GPL); y no encontré Kokoro en `mlx-audio-swift`. Habría que escribir un conversor propio de español a fonemas y no se puede oír el resultado desde este entorno.
- **Personal Voice** de Apple: requiere que el usuario grabe su propia voz y no hay API de TTS pública para apps de terceros en todos los casos; descartado.

## Activación por la palabra «Viernes»

**Realidad de iOS**: una app de terceros **no puede** escuchar de forma continua con la app cerrada ni con el teléfono bloqueado. El único mecanismo con ese comportamiento es «Oye Siri», que es del sistema. Las apps solo pueden usar el micrófono en segundo plano con el modo de fondo `audio` y una sesión activa, algo que Apple revisa y que Viernes **no declara ni intenta**.

**Implementado — en primer plano, opt-in, visible**
- Ajuste «Escuchar la palabra “Viernes”» (**apagado por defecto**).
- Mientras la app está abierta y en espera, abre una sesión de reconocimiento **en el dispositivo** en ventanas de 50 s y busca la palabra en los parciales (`WakeWordMatcher`: tolera «biernes/viernez»; solo en las primeras posiciones, con «oye/hey» opcional; mínimo 7 letras para evitar «vienes»).
- Indicador permanente: punto rojo + «Micrófono abierto · esperando “Viernes”».
- Al detectarla, la **misma sesión** pasa a modo comando (no se pierde lo que dices después: «Viernes, abre Spotify»).
- Se apaga al salir de primer plano, bloquear, perder permisos o desactivar el ajuste.
- **Costo**: reconocimiento continuo ⇒ más batería y calor mientras está activa. Medir en dispositivo.
- **Falsos positivos**: «viernes» es una palabra común (el día). El filtro de posición reduce, no elimina; si empiezas una frase con «Viernes tengo reunión», se activará.

**Porcupine (Picovoice)** — evaluado, no integrado: motor de wake word muy eficiente y con palabras personalizadas (se entrenaría «Viernes» en su consola). Requiere un **AccessKey** de Picovoice (no se puede incluir en el código de este repo) y su licencia gratuita es de uso personal/no comercial con condiciones; el uso comercial exige plan de pago. Sigue limitado al primer plano igual que la solución actual. *(Condiciones según mi conocimiento previo, no verificadas en esta sesión: revisa picovoice.ai antes de adoptarlo.)* Alternativas: modelo propio de keyword spotting en Core ML (requiere datos de entrenamiento de «Viernes»).

**Alternativas realistas que sí funcionan con el teléfono bloqueado o la app cerrada**
- Siri: «Oye Siri, habla con Viernes» (abre la app y escucha).
- Botón de Acción (iPhone 15 Pro+), Control Center, widget o pantalla de inicio con el atajo «Hablar con Viernes».
- Botón del núcleo / modo push-to-talk dentro de la app.

## Siri y Atajos

Implementado con **App Intents** (`ViernesIntents.swift`); Viernes **no reemplaza a Siri**.

| Intent | Frases (con el nombre de la app, como exige Apple) | Efecto |
|---|---|---|
| `OpenViernesIntent` | «Abre Viernes», «Abrir Viernes», «Muestra Viernes» | Abre la app |
| `TalkToViernesIntent` | «Habla con Viernes», «Hablar con Viernes», «Escucha Viernes» | Abre y empieza a escuchar |
| `AskViernesIntent` | «Pregunta a Viernes», «Pregúntale algo a Viernes», «Dile algo a Viernes» | Siri pide el mensaje; Viernes lo recibe y responde en la app |

**Configuración**: instala la app → abre **Atajos** → busca «Viernes» (las acciones aparecen solas) → añádelas a la pantalla de inicio, al Botón de Acción o a Control Center. Si Siri tarda en reconocer las frases tras instalar, ábrela una vez y espera unos minutos.

**Limitaciones**
- «Oye Siri, abre Viernes» funciona porque Siri abre apps por nombre; «viernes» puede confundirse con el día, de ahí la frase alternativa.
- Los App Intents se ejecutan con `openAppWhenRun = true`: siempre abren la app (con el teléfono bloqueado, pedirán desbloqueo).
- El desarrollo del proyecto es en español (`developmentLanguage: es`); las frases de Siri están escritas en español en el código. Para otros idiomas hace falta un String Catalog.
- Enlaces propios: `viernes://listen`, `viernes://ask?q=…` (solo precarga el texto).

## Funcionamiento sin conexión

| Función | Sin internet |
|---|---|
| Dictado | ✅ si el idioma está descargado (si no, aviso; no usa internet sin permiso) |
| Cerebro | ✅ Apple Intelligence (si está activo) o un modelo MLX **ya descargado** (la primera vez necesita internet) |
| Voz | ✅ voces del sistema instaladas |
| Memoria / historial / herramientas locales | ✅ |
| Claude | ❌ requiere la app de Claude y conexión |
| Abrir enlaces / apps web | ❌ según el destino |
