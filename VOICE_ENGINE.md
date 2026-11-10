# VOICE_ENGINE — motor de voz en tiempo real (0.7, fase 1)

**Estado honesto.** Escrito desde Windows: el CI compila y ejecuta las pruebas de la lógica pura (segmentación, turnos, colchón, PCM, métricas, protocolo), pero **nadie ha oído todavía este motor en un iPhone**. No se ha medido ninguna latencia real y este documento **no promete ninguna**: dice cómo se mide y qué se ha cambiado para que sea medible. Las partes que dependen del teléfono (audio, red, ElevenLabs) están marcadas como *sin verificar en el dispositivo*.

## 1. Fase 0 — auditoría del repositorio

| Punto | Resultado |
|---|---|
| Versión | `0.6.0` (Viernes 2.0, IPA `682367b` compilado y verificado en CI; sin probar en iPhone) |
| Arquitectura | `ViernesCore` (Foundation) + app SwiftUI + XcodeGen; `LanguageModelEngine` intercambiable (MLX / Apple / Groq / Gemini); herramientas con validación y confirmaciones |
| CI | `ci.yml` (estático, núcleo, app con y sin MLX), `ipa.yml`, `screenshots.yml`. Todo en verde en `dfdc6d7`/`682367b` |
| Pruebas | ≈ 250 declaradas (núcleo + app + UI) |
| Duplicaciones | Dos segmentadores de texto para hablar (`SentenceStreamer` en el flujo + `SpeechText.chunks` otra vez al encolar); dos rutas de voz de nube con colas propias dentro de `SpeechSpeaker` |
| **Defecto de proceso** | En `ci.yml`, el paso de pruebas del núcleo era `swift test \| tee …` **sin `pipefail`**: el estado de salida era el de `tee`, así que **un fallo de `swift test` no habría hecho fallar el trabajo**. Los «Core: success» anteriores a este commit no demuestran por sí solos que las pruebas pasaran. Corregido (`set -o pipefail`) y el CI ahora publica los fallos en una rama pública (`ci-errors-core`). |

## 2. Auditoría de la cadena de voz

Se revisó el código de salida de voz (`SpeechSpeaker`, `CloudAudioPlayer`, `ElevenLabsClient`, `AudioSessionController`, `SentenceStreamer`, `SpeechText`, `AppModel.runGeneration`). **No se puede atribuir el corte a una sola causa sin medir en el teléfono**; lo que sigue son los defectos estructurales *presentes en el código anterior*, cada uno capaz de producir cortes por sí solo:

| # | Hallazgo (código 0.6.0) | Por qué se oye como «traba» | Estado |
|---|---|---|---|
| F1 | ElevenLabs por **HTTP, una petición por frase**: cada frase espera a que el servidor genere TODO el audio y a que se descargue entero antes de empezar. La precarga (2 frases) solo ayuda cuando ya hay frases en cola | Hueco = tiempo de ida y vuelta + generación de la frase siguiente − duración de la actual; empeora al principio y con red irregular | Sustituido por streaming por WebSocket (sigue disponible apagando el tiempo real) |
| F2 | Un **`AVAudioPlayer` nuevo por frase** (decodifica un MP3, `prepareToPlay`, `Timer`), con saltos de actor entre frases | Decenas–cientos de ms de silencio en cada frontera | Sustituido por un único motor continuo |
| F3 | **Pausas artificiales** (`pauseAfter × pauseScale`, 0,22–0,55 s) añadidas ENCIMA del silencio que ya trae el audio neuronal | Doble pausa: suena entrecortado | Con tiempo real no hay pausas artificiales (la entonación es continua) |
| F4 | `AudioSessionController.activateForConversation()` (`setCategory` + `setActive`) se ejecutaba **en el hilo principal en cada frase encolada** | Reconfigurar la sesión durante la reproducción puede cambiar la ruta y producir chasquidos o cortes, sobre todo con Bluetooth | Una vez por turno (`ensureConversationActive`); se invalida solo ante interrupciones o cambios de ruta |
| F5 | La planificación de la voz vivía en el **actor principal**, que también dibuja el núcleo 3D a 60 fps, las superposiciones 2D y reconstruye la conversación con cada token | Un fotograma lento retrasa la reanudación de la cola entre frases | Con tiempo real, el audio se programa y decodifica en **una cola propia**; el hilo principal solo recibe avisos |
| F6 | Voz del sistema: una `AVSpeechUtterance` por frase con `postUtteranceDelay` | Prosodia reiniciada por frase; las voces «Mejoradas/Premium» tardan en arrancar cada una | Fragmentos más largos (se unen frases cortas) y sin pausas dobles |
| F7 | **Sin métricas** | Imposible saber si el corte venía del modelo, de la red, de ElevenLabs, de la decodificación o de la reproducción | Métricas por turno (ver §5) |
| F8 | Interrupciones del sistema (llamadas, Siri) y cambios de audífonos **no se observaban** durante la voz | La voz seguía por el altavoz tras desconectar unos audífonos o intentaba sonar durante una llamada | `AudioSessionWatcher`: se detiene la voz |
| F9 | Cancelar la generación **no cortaba la voz** (solo `interrupt()` lo hacía) | Podía quedar un turno de habla abierto | `cancelGeneration()` corta también la voz |

**Qué NO se pudo determinar desde aquí**: cuál de F1–F5 domina en tu iPhone. El informe de rendimiento (§5) lo dirá: si «hasta el primer token» es grande, el cuello es el modelo; si «hasta el primer audio» es grande con tokens rápidos, es la red o ElevenLabs; si hay «cortes inesperados», el colchón se vacía (red) o el motor se reconfigura.

## 3. ElevenLabs: documentación oficial y decisión

Fuentes consultadas (documentación oficial de ElevenLabs): *Models*, *Text to Speech WebSocket (stream-input)*, *Text to Speech HTTP streaming*, *TTS vs TTD WebSockets*, *Real-time Text to Dialogue*.

| Opción | Protocolo | ¿Español? | Observaciones documentadas |
|---|---|---|---|
| `eleven_flash_v2_5` | **TTS WebSocket** `wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/stream-input` y HTTP streaming | Sí (32 idiomas) | ≈ 100 ms de mediana (sin red ni app); pensado para tiempo real y agentes; `language_code` admitido |
| `eleven_turbo_v2_5` | Igual | Sí | **Obsoleto**; equivalente a Flash con más latencia |
| `eleven_multilingual_v2` | Igual | Sí (29) | Más estable en texto largo; mayor latencia y coste por carácter; `language_code` no admitido |
| `eleven_v4_turbo` | **Text-to-Dialogue WebSocket** `wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input` | Sí (90+) | ≈ 100 ms de mediana. **Existe**, pero **solo** por el WebSocket de Text-to-Dialogue; exige registrar exactamente una voz en el primer mensaje; el servidor acumula ≈ 40 caracteres y 8 palabras antes del primer audio; se cierra a los 20 s sin mensajes (hay que enviar `keep_alive`); formato de errores y de ajustes de voz sin documentar en las páginas consultadas |
| `eleven_v3`, `eleven_v4` | Text-to-Dialogue | Sí | Expresivos, no pensados para un asistente de baja latencia |

**Decisión.** El WebSocket de **Text-to-Speech** con **`eleven_flash_v2_5`**. Motivos: es lo que la propia guía de ElevenLabs recomienda para un asistente de una sola voz; la voz va en la ruta (se puede elegir cualquiera de la cuenta del usuario, como hasta ahora); admite `language_code`; tiene `inactivity_timeout` configurable (usamos 60 s); y **el protocolo está documentado de extremo a extremo** (mensajes, `isFinal`, alineación). **`eleven_v4_turbo` queda evaluado y NO seleccionado**: requeriría el protocolo de Text-to-Dialogue (otro adaptador, otro formato de mensajes) y no se mezclan; si el usuario deja un modelo `eleven_v3*/v4*` guardado, el WebSocket usa Flash (`ElevenLabsRealtime.compatibleModelID`). Un adaptador de Text-to-Dialogue podría añadirse más adelante sin tocar el resto, porque el protocolo es una pieza aislada (`ElevenLabsRealtime`).

- **Formato de audio**: `pcm_24000` (16 bits little-endian, 24 kHz, mono): no hay que decodificar MP3 en el teléfono. La documentación dice que `pcm_44100` exige plan Pro y no dice nada de `pcm_24000`. *Sin verificar en una cuenta gratuita real*; si el servidor lo rechazara, el error llega como fallo de conexión y se pasa a la voz del sistema.
- **Ajuste de latencia**: `auto_mode=true` («fast») porque Viernes envía frases completas; el modo «balanced» (`chunk_length_schedule` 80/120/200/260) está en el protocolo pero no se expone en la interfaz. La documentación consultada lista `auto_mode` sin describirlo; el significado «sin esperas ni colchones del servidor» viene de la documentación anterior de ElevenLabs y **no se ha comprobado**. Si el audio sonara peor de lo esperado, es el primer ajuste a probar.
- **Alineación** (`sync_alignment=true`): da cuántos caracteres del texto de entrada ya son audio; sirve para retomar tras un corte sin repetir lo dicho.
- **Coste**: se consumen caracteres de la cuota del plan igual que con HTTP; al cancelar a mitad, los ya enviados cuentan. Sin plan de pago obligatorio.
- **Errores**: conexión rechazada (HTTP 401/402/403/404/422 = configuración: no se reintenta) o cortada (transitoria: se reconecta una vez); errores dentro del flujo (cuota, clave, voz) se traducen a mensajes en español.

## 4. Arquitectura

```
modelo (deltas) ──► SpeechSegmenter ──► VoiceTurnLedger ──► ┬─ tiempo real: RealtimeTTSSession (WebSocket) ──audio PCM──► RealtimePCMPlayer ──► altavoz
 (AppModel.runGeneration)  unidades          turno + dedupe   │                                         (cola propia, colchón)
                           naturales          + orden          ├─ por frases:   HTTP + AVAudioPlayer (código anterior)
                                                               └─ voz del sistema: AVSpeechSynthesizer (también respaldo)
```

- **`SpeechSegmenter`** (núcleo, puro): corta el texto en unidades naturales. El primer fragmento sale en cuanto hay una cláusula de ≥ 42 caracteres (coma, «;», «:») o una frase de ≥ 8; los siguientes, por frases (unidas hasta ≥ 40 caracteres); no corta decimales, abreviaturas (`Dr.`), iniciales, `p. m.`, marcadores de lista ni «etc. y»; parte frases de más de 220 caracteres. **Su resultado no depende de cómo lleguen los deltas** (probado con trozos de 1 a 34 caracteres).
- **`VoiceTurnLedger`** (núcleo, puro): cada turno tiene un identificador; cancelar lo invalida. Acepta cada fragmento **una vez y en orden** (`duplicate`, `outOfOrder`, `afterEnd`, `stale`, `cancelled`) y lleva la cuenta de lo enviado y lo ya hablado (`SpokenTextTracker`) para retomar sin repetir.
- **`RealtimePCMPlayer`** (app): un `AVAudioEngine` + `AVAudioPlayerNode` continuos en una cola de alta prioridad. Programa cada trozo PCM según llega. **Colchón anti-cortes** (`JitterBufferPolicy`): empieza a sonar con 250 ms de audio guardado; si se queda sin audio, se pausa y reanuda con 150 ms (o tras 1,2 s, para no quedar mudo). Anota cada hueco. Corta **de forma síncrona** (`stop()` no vuelve hasta que el nodo está parado). Libera el motor de audio 4 s después de acabar.
- **`RealtimeTTSSession`** (app): una conexión por turno; clave solo en la cabecera `xi-api-key`; el audio pasa **directo y en orden** al reproductor (sin saltos de actor que lo reordenen); `final` y fallos se avisan una sola vez.
- **`SpeechSpeaker`** (app): coordina el turno. API de turno: `beginTurn()` → `feed(delta)` → `endTurn()`; `stop()` corta todo. `enqueue(text)` (repetir una respuesta, muestras) es un turno de una vez.

**Cola serializada y sin solapes.** Un turno a la vez; empezar otro cancela el anterior sin avisar. Dentro de un turno, los fragmentos van en orden (el sintetizador los procesa en orden y el audio se programa en orden). En un respaldo, la voz del sistema **espera** a que termine de sonar el audio que ya estaba en el colchón.

**Cancelación inmediata.** `stop()`: invalida el turno, cierra el WebSocket, para el nodo de audio de forma síncrona, vacía las colas de la nube y de la voz del sistema y registra cuánto tardó el silencio. Todo lo que llegue después con el identificador viejo se descarta.

**Recuperación y respaldo.** Si la conexión falla sin ser un problema de configuración, se **reconecta una vez** y se retoma solo lo no hablado (por la alineación). Si no hay alineación y ya había audio, se prefiere **descartar** lo pendiente antes que repetir una frase. Si la reconexión falla, o el fallo es de configuración (clave, plan, voz, cuota), el resto del turno se dice con la voz del sistema y la nube se suspende hasta cambiar los ajustes.

**Eventos del sistema.** `AudioSessionWatcher` avisa de interrupciones (llamada, Siri), desconexión de la salida (audífonos) y reinicio de los servicios de audio: se detiene la voz. Un cambio de ruta que reinicia el motor corta el turno (no se intenta sacar el audio ya programado por otro dispositivo).

**Turnos de conversación.** Tocar el núcleo o el micrófono **mientras Viernes habla** corta la voz y la respuesta que siguiera generándose y **abre el micrófono** para la nueva instrucción (`interruptAndListen`). Nada de la respuesta cortada vuelve a sonar.

**No implementado: interrumpir hablando.** Oír al usuario mientras Viernes habla exige cancelación de eco (voz procesada del hardware sobre el mismo motor) y detección de voz sobre el eco residual; con la voz del sistema (`AVSpeechSynthesizer`) ni siquiera es posible. Queda como trabajo futuro con diseño propio; hoy la interrupción es por toque.

## 5. Métricas e informe

Por turno (`VoiceTurnRecorder`, reloj monótono del sistema): hasta el primer token; del token al primer fragmento; hasta el primer audio; fragmentos y caracteres enviados; audio programado; **cortes inesperados** (duración de cada uno); fragmentos descartados; errores de conexión; reconexiones; respaldo a la voz del sistema; duración de la interrupción (de la orden al silencio); resultado. Se ven en **Configuración › Voz y habla › Voz neuronal › Rendimiento de la voz** (medianas, p95, copiar informe). Solo tiempos y conteos, nunca el texto que se dijo.

**Pruebas reproducibles (CI)**: la lógica se prueba con un reloj falso, sin red ni audio: la primera frase sale antes de la mitad del tiempo que tarda el modelo; nada se pierde, repite ni desordena; un turno interrumpido descarta lo tardío y el siguiente empieza limpio; el colchón y el PCM (incluidos trozos cortados a media muestra); el protocolo de ElevenLabs (URL, mensajes, errores, que `v4_turbo` nunca va por el WebSocket de Text-to-Speech). **Lo que el CI NO mide**: latencia real, red, audio, consumo. No hay todavía ninguna cifra de latencia en un dispositivo; en cuanto haya, irá aquí con su fecha, modelo de iPhone y red.

**Consumo de recursos**: el motor de audio se libera 4 s después de hablar; los trozos PCM son de decenas de KB; el WebSocket se cierra al terminar el turno. Sin medir en el dispositivo.

## 6. Cómo probarlo en el iPhone

1. Voz neuronal activada con una voz predefinida; «Voz en tiempo real» activado.
2. Pide algo largo («explícame cómo funciona un motor de combustión interna»). Debe empezar a hablar antes de que termine de escribirse y sonar continuo.
3. Interrumpe tocando el núcleo en mitad: debe callar al instante y abrir el micrófono; la frase anterior no debe volver.
4. Pon el modo avión a mitad de una respuesta: debe pasar a la voz de Apple sin repetir lo dicho.
5. Conecta o desconecta unos audífonos hablando: debe detenerse.
6. Abre **Rendimiento de la voz**, copia el informe y pásalo: ahí se ve dónde se pierde el tiempo. Compara con «Voz en tiempo real» apagado.

## 7. Limitaciones y pendientes

- Todo lo de audio, red y ElevenLabs está **sin verificar en el dispositivo**; `pcm_24000` y `auto_mode` en el plan gratuito, en particular.
- `eleven_v4_turbo` (Text-to-Dialogue) evaluado y no implementado.
- Interrumpir hablando no implementado (necesita cancelación de eco).
- La reconexión depende de la alineación del servidor; sin ella se descarta lo pendiente en lugar de repetirlo.
- El núcleo 3D y la conversación siguen actualizándose con cada token en el hilo principal (no afecta al audio del tiempo real, sí podría afectar a la fluidez visual).
- Un cambio de ruta que reinicia el motor corta el turno; no se reanuda automáticamente.
