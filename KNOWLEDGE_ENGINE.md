# KNOWLEDGE_ENGINE — biblioteca de conocimiento personal (0.7, fase 3)

**Estado honesto**: el CI compila y prueba la lógica del núcleo y el almacenamiento cifrado en un simulador, con documentos reales generados al vuelo. **No se ha probado en un iPhone**: ni el rendimiento con una biblioteca grande, ni la calidad de la búsqueda por significado con el modelo de frases del sistema (el simulador puede no tenerlo; en ese caso se usa el modelo básico), ni una conversación real con Groq o Gemini usando la biblioteca.

## Qué es (y qué no es)

Una biblioteca para guardar **documentos, imágenes con texto, notas y textos** y consultarlos desde cualquier conversación, sin volver a adjuntarlos. Guarda el **texto extraído** y sus referencias (página, sección, filas, líneas), **no el archivo original**. Es **independiente de la memoria personal**: otro almacén (`knowledge.store`), otro índice, otra pantalla y otro borrado.

| | Memoria personal | Biblioteca |
|---|---|---|
| Contiene | recuerdos, preferencias, proyectos (frases cortas) | texto de documentos, notas, imágenes con texto |
| Se guarda | por orden explícita o sugerencia aprobada | por acción del usuario (nunca se guarda sola la conversación) |
| Almacén | `viernes.store` | `knowledge.store` (cifrado igual, clave del Llavero) |
| Se consulta | siempre, 5 recuerdos relevantes | solo si preguntas por tus documentos o hay coincidencias claras; con permiso si el cerebro es de la nube |
| Borrado | por recuerdo / total | por elemento / total / «Borrar todos los datos» |

El historial de acciones sigue siendo el de las tarjetas de acciones; las conversaciones, su propio historial cifrado.

## Pipeline de ingestión (`KnowledgeEngine.ingest`)

1. **Recibir y validar formato**: lo hace la capa de adjuntos de la fase 2 (tipo por contenido, no por extensión).
2. **Validar tamaño y límites**: 300 elementos y 8 millones de caracteres en total (el índice vive en memoria; si no cabe, se dice y no se guarda).
3. **Hash** SHA-256 del archivo (CryptoKit en la app, implementación propia en Swift puro en el núcleo; una prueba comprueba que dan lo mismo) y del texto normalizado.
4. **Extraer** (PDFKit, ZIP/DOCX/XLSX propio, texto…) y **OCR** local (Vision) para escaneos e imágenes. Una imagen sin texto legible **no se guarda** (la biblioteca busca por texto).
5. **Detectar duplicados**: mismo archivo (hash), mismo texto en otro formato (hash del texto normalizado) o casi idéntico (≥ 80 % de fragmentos iguales). Se avisa y el usuario puede guardarlo igualmente.
6. **Fragmentar** (≈ 1 000 caracteres) conservando la **referencia** de cada fragmento: `pág. 2`, `«Cláusula 5»`, `Hoja «Precios», filas 31–60`, `líneas 40–88`.
7. **Vectores** de significado si hay un modelo disponible (ver abajo).
8. **Guardar** (cifrado) e **indexar** (en memoria).
9. **Verificar la recuperación**: se busca con las palabras de uno de sus fragmentos y debe aparecer entre los primeros resultados; si no, el elemento queda en **error** (no se finge que está indexado).
10. Estados visibles: *en cola → procesando → indexado | error*. Si la app se cierra a mitad, al reabrir el elemento aparece en error («Se interrumpió el procesamiento»), nunca como indexado.

## Búsqueda (`KnowledgeEngine.search`)

Híbrida, sin base de datos externa:
- **Texto**: BM25 sobre raíces sin acentos ni plurales (el título también cuenta).
- **Significado**: coseno entre vectores. **Alternativa local, sin descargas ni servidores**: el modelo de frases en español de NaturalLanguage (en el dispositivo) cuando el sistema lo ofrece; si no, `HashingEmbedder` (256 dimensiones sobre palabras, raíces y pares de palabras). **Limitación**: el modelo básico capta palabras y raíces compartidas («factura» ~ «facturación»), **no sinónimos**; el del sistema sí capta cierto significado, pero no está calibrado en un iPhone real. No se usan embeddings en la nube: nada del texto sale del teléfono por esto.
- **Fechas**: «¿dónde aparece el 15 de marzo de 2023?» se convierte en variantes literales (`2023-03-15`, `15/03/2023`, `15 de marzo de 2023`…) y se busca el texto exacto.
- **Filtros**: por documento, proyecto/carpeta/colección (incluye subcarpetas), etiquetas, tipo y fecha de importación.
- Fusión por rangos (RRF). Cada resultado trae documento, referencia, texto, puntuación y **cobertura**: qué fracción de los términos de la pregunta *que existen en la biblioteca* contiene el fragmento. Los términos que no aparecen en ningún documento («cuánto», «establece») no cuentan.

SQLite/FTS5 se evaluó y **no se usó**: un archivo SQLite quedaría en claro en disco (contradice el cifrado por registro del proyecto). El índice se reconstruye en memoria al abrir (descifrando los registros); con los límites de arriba (≈ 16 MB de RAM) es viable. Si una biblioteca real superara esos límites habría que migrar a un índice persistente cifrado: está anotado como pendiente.

## Respuestas fundamentadas

- **Cuándo se consulta**: si la pregunta habla de tus documentos («mi contrato», «mis notas», «en la biblioteca»…) basta una buena coincidencia de texto; si no, solo coincidencias **claras** (fecha literal, ≥ 2 términos propios en común o similitud semántica alta). Una pregunta cualquiera no arrastra fragmentos ni gasta cuota.
- **Herramienta `search_library`** para búsquedas explícitas; sus resultados se neutralizan igual que cualquier contenido de archivos y **no se enseñan como tarjeta**.
- **Cómo se le da al modelo**: en el mismo bloque marcado «CONTENIDO NO CONFIABLE» de los adjuntos, con `tipo="Biblioteca"` y la referencia de cada fragmento, y la regla de citar documento y referencia, distinguir lo que **dice** el texto de lo que se **interpreta** y no inventar.
- **Sin evidencia**: si preguntas por tus documentos y no hay nada relevante (o la biblioteca está vacía), el bloque se lo dice al modelo («busqué en N elementos y no encontré fragmentos relevantes: dilo y no inventes»).
- **Fuentes**: cada respuesta muestra «Fuentes consultadas» (documento · página/sección). Son las fuentes **entregadas** al modelo, no una garantía de cuál usó.
- **Permiso**: con un cerebro en la nube, antes de enviarle fragmentos de la biblioteca se pregunta qué documentos son y adónde saldrán (se puede desactivar en Ajustes › Adjuntos y visión). Sin forma de preguntar, no sale nada. Con un cerebro local, no sale nada.
- **Seguridad**: lo que devuelve la biblioteca es contenido no confiable; mientras haya fragmentos en la petición, cualquier acción que no sea una simple consulta pide confirmación con aviso. Un documento guardado con instrucciones maliciosas no puede ejecutar acciones.

## Interfaz

- **Más › Biblioteca**: lista con estado real por elemento (*Procesando* / *Indexado* / *Error*), buscador por contenido (con aviso cuando no hay nada relevante), filtro por proyecto o carpeta, borrado con confirmación y detalle (datos, título/etiquetas/carpeta editables, fragmentos guardados, hash corto, si tiene búsqueda por significado).
- **Añadir**: archivos (mismo lector y validaciones que los adjuntos), **nueva nota** y gestor de **proyectos / carpetas / colecciones** (anidables; borrar una carpeta no borra sus documentos).
- **Desde un adjunto**: «Guardar en la biblioteca» en su detalle; el adjunto pasa a mostrar «en la biblioteca (indexado)». Estados distinguidos: *temporal* (adjunto), *procesando*, *indexado*, *error*.
- **Ajustes › Adjuntos y visión › Biblioteca**: consultar la biblioteca en las conversaciones sí/no y borrar toda la biblioteca.

## Pruebas

**Núcleo (CI)**: hash SHA-256 con vectores estándar; vectores empaquetados; embedder básico; variantes de fechas; ingestión (identificador estable, metadatos, estados *procesando → indexado*, límites, texto vacío, notas); búsqueda por contenido (página correcta), sin modelo de vectores, con tildes/plurales, por fecha literal, y filtros por documento/proyecto/etiqueta/tipo/fecha; duplicados (archivo, texto, casi idéntico, guardar igualmente); **borrado** (deja de aparecer en búsquedas y en el almacén, también por fecha); recuperación en una «sesión posterior»; elementos interrumpidos; renombrar/etiquetar/mover; proyectos; compuerta «¿habla de mis documentos?»; conversación (cita la cláusula y devuelve **fuentes**, otra conversación, tema ajeno sin biblioteca, «no hay nada» sin inventar, **permiso antes de enviar a la nube**, herramienta `search_library`, **un documento guardado no autoriza acciones**).
**App (simulador)**: persistencia SwiftData cifrada (el texto no está en claro en disco), recuperación tras «reiniciar», registros ilegibles omitidos, **memoria y biblioteca en almacenes separados**, borrado completo, CryptoKit = núcleo, embedder, guardar un adjunto (texto, imagen con OCR, sin texto rechazado, duplicado), notas, «Borrar todos los datos». **Interfaz**: biblioteca vacía; biblioteca con elementos reales indexados, búsqueda por contenido y borrado.

## Limitaciones y pendiente

- Sin probar en iPhone: rendimiento, calidad del modelo de frases del sistema, memoria con una biblioteca grande.
- No se guarda el archivo original (no se puede «abrir el PDF» desde la biblioteca; sí ver los fragmentos).
- Un cambio de modelo de vectores deja los elementos antiguos solo con búsqueda de texto hasta volver a guardarlos.
- Las notas no se editan: se borran y se vuelven a crear.
- Sin sincronización entre dispositivos ni exportación (se tratan en la fase 4, con los perfiles).
