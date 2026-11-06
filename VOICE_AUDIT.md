# VOICE_AUDIT — auditoría del reconocimiento de voz (v0.6.0)

**Estado honesto.** Esta auditoría se hizo **leyendo el código** y escribiendo pruebas de la lógica pura (el CI las ejecuta). Viernes se desarrolla desde Windows: no se pudo oír una sola frase en un iPhone, así que **no está medida la precisión** y no se afirma que ahora transcriba mejor. Cada punto indica qué es *verificado en CI*, qué es *cambio sin verificar en el dispositivo* y qué queda *por medir*.

## ¿Dónde pueden nacer los errores?

Una orden por voz pasa por cuatro etapas. El diagnóstico nuevo (Configuración › Escucha y activación › Diagnóstico) deja una ficha de texto por frase para separarlas:

| Etapa | Qué puede fallar | Qué dice la ficha |
|---|---|---|
| **1. Captura** | Micrófono equivocado (Bluetooth de baja calidad), nivel bajo, ruido, corte por silencio, interrupciones | Entrada de audio y frecuencia, duración, motivo del fin (silencio / tú / máximo / no se oyó voz), «hubo una interrupción» |
| **2. Reconocimiento** | Idioma/modelo (en el dispositivo es menos preciso que los servidores con nombres y palabras raras), palabras que suenan igual | Texto «Oído», idioma realmente usado, en el dispositivo o por internet, nº de parciales, confianza media (en el dispositivo suele ser 0 = sin dato), error con dominio y código |
| **3. Transcripción posterior** | Nombres partidos, correos dictados, mayúsculas | «Corregido» (si cambió algo), con la lista de cambios en el registro técnico |
| **4. Procesamiento** | El cerebro interpreta mal una frase bien transcrita | «Tú dejaste» (si editaste) y la conversación: si «Oído» es correcto y la respuesta no, el fallo no es de voz |

## Revisión punto por punto

| Revisado | Hallazgo (por lectura de código) | Cambio | Verificación |
|---|---|---|---|
| `SFSpeechRecognizer` y **locale** | Se pedía `es-CO` y, si no tenía modelo en el dispositivo, **se usaba otra variante sin avisar** (es-MX, es-US, es-419, es-ES). Nadie podía saber cuál se usó. | El idioma real queda en cada ficha. Se mantiene la preferencia por reconocimiento en el dispositivo (privacidad). | Por medir: si el acento colombiano mejora con es-CO o con servidores |
| Reconocimiento **en el dispositivo vs servidores** | `requiresOnDeviceRecognition = true` cuando hay modelo. Es la causa **más probable** de fallos con nombres y términos raros, pero no está medida. | Sin cambio de política: «Permitir reconocimiento de Apple por internet» sigue apagado por defecto. Se añadieron nombres propios y Whisper opcional. | Por medir con el diagnóstico |
| **Nombres propios y términos** | **No se enviaba `contextualStrings`** al reconocedor. | Glosario del usuario + correcciones aprendidas + «Viernes» se envían como `contextualStrings` (máx. 100). | Cambio sin verificar en el dispositivo |
| Permisos de micrófono y Speech | Correctos (`AVAudioApplication`, `SFSpeechRecognizer`), con explicación previa. | Sin cambio. | — |
| **AVAudioSession** | `playAndRecord` + `allowBluetooth` hace que unos audífonos Bluetooth impongan su micrófono de perfil de llamada (baja calidad). No se registraba la entrada usada. | La entrada y su frecuencia quedan en la ficha; opción «Usar el micrófono del iPhone con audífonos Bluetooth». | Sin verificar |
| **Interrupciones** (llamada, Siri, audífonos) | **No se manejaban**: el motor se paraba y la frase quedaba colgada hasta el tiempo límite. | Observadores de `interruptionNotification` y `AVAudioEngineConfigurationChange`: se entrega lo transcrito hasta ese momento (o se reinicia la escucha pasiva) y se marca en la ficha. | Sin verificar |
| Inicio/fin de grabación, tap, motor | Correctos (se quita el tap, se evita tocar el micrófono sin permiso). | Sin cambio estructural. | — |
| **SFSpeechRecognitionTask** | Cancelación y callbacks tardíos bien protegidos por `sessionID`. | Reinicio controlado ante errores (abajo). | — |
| **Reconocimiento parcial** | Ya se mostraba. | Además se cuenta en la ficha y se usa para no cortar mientras el reconocedor aún añade palabras. | Sin verificar |
| **Detección de silencio** | `endSilence` fijo de 1,3 s y umbral de −42 dBFS: **cortaba al hacer una pausa** (típico al dictar un correo o pensar). | Pausa configurable 0,8–3,0 s (por defecto 1,8 s); si el último parcial cambió hace menos de 0,7 s se espera un poco más. | Lógica del detector con pruebas; efecto real sin verificar |
| **Errores del reconocedor** | Solo se trataban `1110` y `301`; el resto se mostraba crudo. | `SpeechErrorPolicy`: benignos (sin voz/cancelado/ya hay texto), **un reinicio automático** si no hubo texto, y mensajes claros para «falta el modelo de dictado» (`kLSRErrorDomain 102`) y «dictado desactivado» (`201`). Los códigos salen de lo observado por desarrolladores; cualquier otro queda en la ficha con su dominio y código. | Política con pruebas; códigos sin verificar en iOS 26 |
| **Reconocimiento continuo** | Existe «Escuchar la palabra Viernes» (solo con la app abierta) y «Conversación continua». Cada petición del reconocedor dura ~1 min: se reabre cada 50 s y entre una y otra hay una **brecha de décimas de segundo** en la que se pierden palabras. | Sin cambio (iOS no permite más; ver VOICE.md). | Brecha sin medir |
| **Audio grabado vs en vivo** | Solo se usa reconocimiento **en vivo** (`SFSpeechAudioBufferRecognitionRequest`). | Con Whisper activado se graba además un WAV de 16 kHz de la frase para enviarlo (ver abajo). | Sin verificar |
| **Corrección posterior** | No existía. | `TranscriptCorrector` (glosario prudente: solo palabras casi iguales a un nombre de la lista y nunca «Daniela» → «Daniel»; correos dictados; correcciones aprendidas). | Con pruebas |
| **Edición antes de enviar y botón de corregir** | No existían. | Barra «Entendí…» (apagada / 2,5 s / siempre) y lápiz en la última frase dictada. Lo que editas se aprende (visible y borrable). | UI sin verificar en el dispositivo |
| **Historial de errores** | No existía. | `RecognitionHistory`: ficha cifrada por frase (texto, nunca audio), máx. 100, desactivable; «Copiar informe». | Con pruebas la lógica; UI sin verificar |

## Whisper de Groq (opcional)

- **Qué hace**: con el interruptor activado y consentido, las frases dictadas **tocando el micrófono** se graban también como WAV de 16 kHz mono (~32 KB/s) y se envían a `https://api.groq.com/openai/v1/audio/transcriptions` (`whisper-large-v3-turbo`, idioma `es`, `prompt` con tus nombres) con tu clave gratuita de Groq. Si responde, ese texto se usa; si falla o tarda (20 s), se usa el del iPhone y se avisa.
- **Privacidad**: apagado por defecto; la activación pide un consentimiento explícito que se guarda con fecha (`cloudConsentAt`) y **sin él el ajuste se anula** (comprobado en pruebas); al apagarlo se retira el consentimiento. **No se envía audio** de la escucha «Viernes» (ventanas continuas), **nunca a ElevenLabs** (solo recibe texto para sintetizar) ni a otro servicio. El archivo temporal se borra siempre (éxito, fallo, cancelación o arranque posterior). El reconocimiento local sigue disponible y es el respaldo.
- **¿Es mejor?** **No se afirma.** No hay pruebas comparativas todavía. Cada frase con Whisper guarda las dos versiones y puedes votar «iPhone / Whisper / ninguna»; el resumen del diagnóstico solo saca una conclusión (sobre TUS votos) a partir de 5 votos, y la llama muestra pequeña y personal.
- **Límites**: plan gratuito de Groq (peticiones y segundos de audio por hora); tamaño máximo de archivo 24 MB (≈ 12 min, muy por encima de una frase).

## No evaluado

- **`SpeechAnalyzer` / `SpeechTranscriber` (iOS 26)**: el motor de dictado nuevo de Apple. Es el candidato natural si el reconocimiento local sigue siendo insuficiente, pero sin un dispositivo para probarlo no se integró a ciegas.
- **Confianza por palabra / alternativas** (`SFTranscriptionSegment.alternativeSubstrings`): en el dispositivo la confianza suele venir en 0 y no se pudo comprobar su utilidad.

## Cómo comprobarlo en el iPhone (≈ 10 min)

1. Instala el IPA nuevo. En **Escucha y activación**, deja «Antes de enviar» en «Mostrar 2,5 s para corregir».
2. Di 8–10 frases reales de las que antes fallaban (agenda, nombres de tus contactos, un correo). En cada una mira «Entendí…»; corrige las malas con el texto.
3. Abre **Diagnóstico del reconocimiento**: ¿la entrada es «iPhone» o un Bluetooth? ¿hay «hubo una interrupción» o «terminó por silencio» demasiado pronto? ¿el idioma realmente usado es es-CO? Toca «Copiar informe» y pásalo.
4. (Opcional) Activa Whisper, repite las frases y vota. Con ≥ 5 votos el resumen te dice cuál acertó más **en tus pruebas**.
5. Añade los nombres que fallan en **Nombres y términos** y repite.
