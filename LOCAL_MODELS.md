# LOCAL_MODELS — cerebros locales

Cómo se eligieron, qué hay en el catálogo, qué se sabe y qué **no se ha medido**.

## Runtimes evaluados

| Runtime | Estado | Motivo |
|---|---|---|
| **Foundation Models (Apple, iOS 26+)** | ✅ Implementado (`FoundationModelsEngine`) | Sin descarga ni RAM extra para la app, optimizado por Apple, español soportado, streaming nativo. Limitado a iPhones con Apple Intelligence y a que el usuario lo tenga activado. Contexto pequeño (por eso `historyCharBudget` = 4 500 con este motor). |
| **MLX Swift (`mlx-swift-lm` 3.32.x)** | ✅ Implementado (`MLXEngine`), **sin compilar** | GPU de Apple Silicon, muchos modelos (Qwen, Gemma, Llama, Phi…), `ChatSession` con streaming, descarga integrada desde Hugging Face. Requiere Xcode 26+ (tools 6.2). |
| **Core ML** | ❌ No usado | Convertir y mantener LLMs en Core ML (cuantización, KV-cache con estado) es más costoso y con menos modelos listos; hay reportes de fallos de carga en dispositivos de 4 GB. MLX cubre el caso con menos fricción. |
| **llama.cpp** | ❌ No usado | Alternativa válida (GGUF, Metal); descartada para no mezclar dos runtimes en v0.1. El contrato `LanguageModelEngine` permite añadirlo. |

## Catálogo (`ModelCatalog.all`)

| Modelo | Backend | Descarga (≈) | RAM sugerida | Licencia | Español (editorial 1–5) |
|---|---|---|---|---|---|
| Apple Intelligence (sistema) | `FoundationModels` | 0 | 8 GB / dispositivo compatible | Términos de Apple | 4 |
| Qwen3 1.7B 4 bits | `mlx-community/Qwen3-1.7B-4bit` | ~1,0 GB (984 MB según benchmark de terceros) | ≥ 6 GB | Apache 2.0 | 3 |
| Gemma 3 1B QAT 4 bits | `mlx-community/gemma-3-1b-it-qat-4bit` | ~0,77 GB (772 MB según benchmark) | ≥ 4 GB | Términos de uso de Gemma | 3 |
| Llama 3.2 3B Instruct 4 bits | `mlx-community/Llama-3.2-3B-Instruct-4bit` | ~1,8 GB (estimación) | ≥ 8 GB | Llama 3.2 Community License | 3 |
| Qwen3 4B 4 bits | `mlx-community/Qwen3-4B-4bit` | ~2,3 GB (estimación) | ≥ 8 GB | Apache 2.0 | 4 |

> **Importante**: la columna *Español* es **mi valoración editorial** basada en las capacidades multilingües declaradas por cada familia; **no es un benchmark** y no se midió en esta sesión. Los tamaños marcados «estimación» no se verificaron. Los identificadores de repositorio coinciden con los registrados en `LLMRegistry` de mlx-swift-lm 3.32.x.

### Criterios de selección (no solo popularidad)
1. **Tamaño real en iPhone**: ≤ ~2,3 GB descargados; los modelos de 7–8 B (≥ 4,5 GB) quedan fuera aunque estén en `LLMRegistry`.
2. **Español**: familias con soporte multilingüe declarado (Qwen3, Llama 3.2, Gemma 3, sistema de Apple).
3. **Instruct** y plantilla de chat disponible en `mlx-community`.
4. **Licencia utilizable por un particular** (ver abajo).
5. **Diversidad de huella**: del más ligero (Gemma 1B) al mejor local razonable (Qwen3 4B).

### Evaluados y descartados (por ahora)
- **Phi-3.5 mini / Phi-4 mini**: fuertes en razonamiento, pero centrados en inglés; menos adecuados para español colombiano.
- **Gemma 3n E2B/E4B y Gemma 4 E2B/E4B** (están en `LLMRegistry`): prometedores y multimodales, pero no verifiqué tamaño en memoria ni calidad en español; candidatos para una v0.2.
- **Qwen3 0.6B / SmolLM**: demasiado débiles para conversar con coherencia en español.
- **Modelos 7–8 B**: no caben con holgura en la mayoría de iPhones.

## Licencias (resumen no legal)

- **Qwen3**: Apache 2.0 — uso libre, incluso comercial.
- **Gemma 3**: *Gemma Terms of Use* de Google — uso permitido con condiciones (política de uso aceptable, redistribución con los mismos términos).
- **Llama 3.2**: *Llama 3.2 Community License* — condiciones de atribución («Built with Llama»), política de uso aceptable y un umbral de usuarios para licencia especial. Si descargas el modelo tú mismo desde Hugging Face para uso personal no hay problema práctico; revisa los términos si distribuyes la app con el modelo.
- Viernes **no incluye** los pesos en el repositorio ni en la app: se descargan en el dispositivo a petición del usuario.

## Memoria y rendimiento (heurística, NO medida)

`ModelRecommender` estima: *huella ≈ descarga × 1,3 + 0,4 GB* y un presupuesto de **≈ 50 % de la RAM física** (iOS limita el uso por app; el entitlement `increased-memory-limit` lo eleva). Etiqueta:
- **Recomendado**: huella ≤ 75 % del presupuesto.
- **Posible**: huella ≤ presupuesto.
- **No recomendado**: por encima, o RAM < `minDeviceRAMGB`.

Un reporte público indica que un iPhone SE (4 GB) falla al cargar un Qwen 1.7B cuantizado (límite ~2 GB por proceso); la heurística es coherente con eso (Qwen3 1.7B ⇒ «No recomendado» con 4 GB).

**Sin medir** (hacerlo en dispositivo, ver [INSTALL.md](INSTALL.md#pruebas-que-requieren-iphone-físico)): tokens/s, tiempo hasta el primer token, pico de memoria, temperatura, consumo (%/hora de conversación), calidad del español.

Parámetros de generación usados: `temperature 0.6`, `maxTokens 512` (respuestas habladas cortas). Para Qwen3 se añade `/no_think` al prompt y se filtran bloques `<think>` por si aparecen.

## Modelos intercambiables

- Cambiar de modelo: Configuración › Modelo local › «Usar este». Los modelos MLX piden confirmación **antes de descargar** (tamaño y requisito de internet) y se pueden eliminar.
- Añadir un modelo: nueva entrada en `ModelCatalog.all` (repo `mlx-community/…`, tamaño, RAM, licencia, `emitsThinkTags`). No hay que tocar nada más.
- Añadir otro runtime: implementar `LanguageModelEngine` y enrutarlo en `EngineProvider.makeEngine`.

## Funcionamiento sin internet

- Apple Intelligence: ✅ siempre que esté disponible.
- MLX: ✅ **tras la primera descarga**. Viernes marca los modelos cargados con éxito y los recarga solos al abrir. *A verificar*: que el cliente de Hugging Face cargue desde la caché sin red (debería, pero no se probó).
- Si el modelo no está listo, Viernes lo dice («Mi modelo local aún no está descargado…») en lugar de improvisar una respuesta.

## Honestidad del modelo

El prompt de sistema obliga a reconocer límites: «eres un modelo pequeño… no tienes internet… si no sabes, dilo». Aun así, **los modelos pequeños alucinan**; por eso las acciones y los hechos del dispositivo (recordatorios, batería, fecha) vienen de herramientas, no del modelo.

## Verificación pendiente (MLX)

`MLXEngine.swift` usa, según README y fuentes de mlx-swift-lm 3.32.x:
- `ModelConfiguration(id:)` y el macro `#huggingFaceLoadModelContainer(configuration:progressHandler:)` (imports: `MLXLLM`, `MLXLMCommon`, `MLXHuggingFace`, `HuggingFace`, `Tokenizers`).
- `ChatSession(model, instructions:, history:, generateParameters:)` y `streamResponse(to:)`.
- `Chat.Message.user(_:)` / `.assistant(_:)` y `GenerateParameters(maxTokens:temperature:)`.

Lo que **no** pude confirmar leyendo las fuentes: el inicializador exacto con `history:` + `generateParameters:` juntos, los constructores estáticos de `Chat.Message`, y el orden de los parámetros de `GenerateParameters`. Si Xcode reporta algo, es aquí donde se arregla. No se configura `MLX.GPU` / límite de caché (API cambiante); ajustarlo tras medir la memoria.
