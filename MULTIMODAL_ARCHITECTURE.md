# MULTIMODAL_ARCHITECTURE — adjuntos, imágenes, documentos y escáner (0.7, fase 2)

**Estado honesto**: el CI compila y prueba la lógica (núcleo y lectores, con archivos reales generados al vuelo) y la interfaz en un simulador. **Nada de esto se ha probado en un iPhone**: ni la cámara, ni el escáner de documentos, ni el envío real de una imagen a Groq o Gemini. Lo que depende de un proveedor externo (nombres de modelos, límites) se indica con su fuente y puede cambiar.

## Flujo de un adjunto

```
fuente (fototeca · cámara · escáner · Archivos)
   → AttachmentCenter (estado visible: leyendo / listo / aviso / error)
   → FileSniffer: tipo REAL por contenido + tamaño        (núcleo, con pruebas)
   → lector por tipo: imagen (ImageIO) · PDF (PDFKit + OCR) · DOCX/XLSX (ZIP propio) · texto/CSV/JSON/XML/código
   → ExtractedDocument: secciones con página / sección / líneas   |   ImagePart: JPEG reducido
   → [al enviar] AttachmentRouter: ¿qué cerebro puede leerlo? ¿sale algo del teléfono?  → permiso
   → ConversationEngine: bloque «CONTENIDO NO CONFIABLE» + selección de fragmentos + confirmaciones reforzadas
```

El contenido de los archivos **no se guarda** en el historial (solo nombre, tipo y tamaño). Se conserva en memoria, por conversación, hasta 6 documentos para preguntas posteriores; al reanudar una conversación guardada o empezar otra, desaparece (y Viernes lo dice si le preguntan por él).

## Formatos: un procesador real por cada uno

| Formato | Procesador | Qué conserva | Límites conocidos |
|---|---|---|---|
| JPG / JPEG, PNG, HEIC, WebP | ImageIO (`CGImageSource`) | Orientación EXIF aplicada; transparencia → blanco; se reduce a ≤ 1 568 px y se recodifica en JPEG (≤ 2,9 MB); miniatura | WebP solo si el sistema lo decodifica; GIF/AVIF/TIFF se rechazan con motivo |
| PDF | PDFKit (`PDFPage.string`) | Una sección por página con su número; limpieza de guiones de fin de línea, encabezados/pies repetidos y números de página | 300 páginas; PDF con contraseña se rechaza |
| PDF escaneado / foto de un documento | Vision (`VNRecognizeTextRequest`, español + inglés) sobre la página dibujada a ≈ 2 200 px | Texto por página marcado «OCR» | OCR en las primeras 20 páginas sin texto; puede errar |
| DOCX | ZIP propio + `XMLParser` (`word/document.xml`) | Títulos (estilos Heading/Título), párrafos, listas, tablas como filas «a \| b»; páginas **aproximadas** por saltos guardados | No lee encabezados/pies, notas ni cuadros de texto; cuadros alternativos pueden duplicar texto |
| XLSX | ZIP propio + `XMLParser` (libro, relaciones, cadenas compartidas, estilos, hojas) | Una tabla por hoja visible; fórmulas con su valor calculado; fechas (formatos de fecha integrados y personalizados, sistema 1900/1904); filas con su **número real** | 5 000 filas × 100 columnas por hoja; hojas ocultas no se leen; sin gráficos |
| CSV / TSV | Lector RFC 4180 propio | Comillas, saltos dentro de campo, delimitador `,` `;` tab `\|` detectado | 5 000 filas |
| JSON | `JSONSerialization` | Se valida y se reescribe con sangría | Si no es válido se conserva el texto y se avisa |
| XML | `XMLParser` (sin entidades externas) | Se comprueba que esté bien formado; texto original | — |
| TXT, MD, código | Decodificador UTF-8 / UTF-16 / Windows-1252 | Secciones de ~1 400 caracteres con **rango de líneas**; Markdown por encabezados | 600 000 caracteres |

No hay lector para `.doc`, `.xls`, `.ppt(x)`, `.rtf`, `.pages`, `.numbers`: se rechazan diciendo cómo exportarlos (PDF o DOCX/XLSX). Un DOCX/XLSX protegido con contraseña o en formato antiguo (contenedor OLE) se detecta y se explica.

**Por qué un lector ZIP propio** (`ZipArchive` + `Inflate`, Swift puro, ≈ 300 líneas): iOS no ofrece una API pública de ZIP en Foundation, y añadir una dependencia solo para esto contradice la regla de no sumar dependencias innecesarias. Se verificó con ZIP/DOCX/XLSX reales generados por .NET (DEFLATE de verdad), con CRC-32 y con una «bomba» (entrada que declara 100 bytes y expande 5 000).

## Matriz de capacidades por cerebro

| Cerebro | Texto | Imagen | PDF nativo | Audio | Contexto | Herramientas | Streaming | Texto de archivos por petición* |
|---|---|---|---|---|---|---|---|---|
| Groq · `openai/gpt-oss-120b` | ✓ | ✗ | ✗ | ✗ | 131 072 tokens | ✓ | ✓ | ≈ 5 000 caracteres |
| Groq · visión (por defecto `qwen/qwen3.8-27b`, vista previa) | ✓ | ✓ (≤ 3) | ✗ | ✗ | sin dato verificado | ✓ | ✓ | ≈ 5 000 |
| Google Gemini (`gemini-2.5-flash`) | ✓ | ✓ (≤ 8*) | ✗ | ✓† | sin dato verificado | ✓ | ✓ | ≈ 40 000 |
| MLX local (Qwen3 1.7B…) | ✓ | ✗ | ✗ | ✗ | pequeño | ✓ | ✓ | ≈ 2 500 |
| Apple Intelligence (FoundationModels) | ✓ | ✗ | ✗ | ✗ | pequeño | ✓ | ✓ | ≈ 2 000 |

\* Política propia de Viernes (cuánto texto de archivos se permite en una petición para no pasar el límite del plan gratuito ni la memoria de un modelo pequeño), no un límite del proveedor. Gemini admite más imágenes; 8 es un tope conservador.
† La API compatible con OpenAI de Gemini documenta `input_audio`; Viernes todavía no lo usa en el chat (la voz usa su propio reconocedor).

Fuentes (consultadas el 10-nov-2026): [Groq · Vision](https://console.groq.com/docs/vision.md) (formato `image_url` con URL de datos en base64, hasta 3 imágenes con el modelo de visión, 20 MB por URL; **no** da un límite para base64: el tope de 2,9 MB del JPEG es una política conservadora), [Groq · Modelos](https://console.groq.com/docs/models) (gpt-oss-120b: contexto 131 072; el modelo de visión figura como *preview*), [Gemini · compatibilidad con OpenAI](https://aistudio.google.com/docs/openai) (imágenes por `image_url` base64; **el PDF no está documentado** en esa API, por eso los PDF se leen en el teléfono y solo viaja su texto). Las fuentes se contradecían en el nombre exacto del modelo de visión de Groq (3.6 frente a 3.8); por eso es **editable** y hay un botón «Comprobar que existe en mi cuenta» (consulta `GET /models`).

## Enrutador (`AttachmentRouter`, núcleo, 14 pruebas)

Decide con: tipo de adjunto, capacidad del cerebro actual, claves guardadas, conexión y el ajuste de privacidad.

1. **Solo documentos, cerebro local** → se envía; no sale nada del teléfono.
2. **Documentos con cerebro en la nube** → pregunta: «Se enviará el texto de «contrato.pdf» a Groq (modelo …)…». (Se puede desactivar en Ajustes › Adjuntos y visión.)
3. **Imágenes con un cerebro que no ve**: si el mismo proveedor tiene modelo de visión (Groq) se usa **solo para ese mensaje**, con permiso y aviso en la respuesta. Si el cerebro es local, **no se envía nada**: se explica el motivo y se *ofrece* cada alternativa que el usuario puede autorizar: usar otro proveedor para ese mensaje (solo los que tienen clave), **leer solo el texto de la imagen con OCR local** o quitarla.
4. **Demasiadas imágenes / sin conexión** → se explica con una alternativa.
5. Nunca se cambia a otro proveedor externo sin autorización; el cambio dura un mensaje y el historial viaja con él (no se pierde el contexto); la respuesta lleva el nombre del cerebro que contestó.

## Selección de fragmentos (`ExcerptSelector`)

Si todo cabe, se envía todo. Si no: preguntas **concretas** («¿cuánto establece mi contrato como salario?») → fragmentos más relevantes por BM25 (sin acentos ni plurales); peticiones **generales** («resume este informe») → el comienzo de cada documento y fragmentos repartidos por todo el contenido. El bloque dice cuántos fragmentos se muestran de cuántos («no es completo»), y cada fragmento lleva su referencia (`pág. 6, «Cláusula 17»`, `Hoja «Precios», filas 2–3`, `líneas 40–88`). En preguntas de seguimiento el archivo solo se vuelve a incluir si la pregunta trata de él (así no se gasta cuota con un tema ajeno). Esta misma pieza (fragmentos + referencias) es la base del Knowledge Engine de la fase 3.

## Comparación

«Compara estos dos PDF» / «busca las diferencias entre estas hojas»: las diferencias se **calculan en el teléfono** (líneas por subsecuencia común más larga; tablas por la primera columna si es única, o fila a fila) y el modelo recibe el resultado, acotado a ≈ 2 400 caracteres, además de los fragmentos. Es más fiable y barato que pedirle al modelo que las busque.

## Seguridad del contenido (ver SECURITY.md)

El contenido de un archivo es información, nunca instrucciones. Capas: (1) bloque marcado y reglas en el prompt de sistema; (2) neutralización de etiquetas internas y caracteres invisibles/bidireccionales, también en nombres y títulos; (3) **mientras haya contenido de archivos, toda acción que no sea una consulta sin efectos exige confirmación** (aviso «surge de una conversación con archivos adjuntos»); (4) un detector heurístico avisa al usuario y al modelo (no es la defensa); (5) validación por contenido, límites y protección contra bombas de compresión; (6) las imágenes se recodifican (sin EXIF).

## Interfaz

- Botón de clip junto al campo de texto y submenú **Adjuntar** dentro de «Más»: Foto de la fototeca (`PhotosPicker`), Tomar una foto, Escanear documento (VisionKit, funciona en iOS 18: detecta la página, recorta y corrige la perspectiva; las páginas se unen en un PDF y se leen con OCR), Archivo (importador de Archivos). Lo que el dispositivo no ofrece (cámara en el simulador) aparece **desactivado y lo dice**.
- Fila de adjuntos con su estado **real**: *Leyendo…* → *listo* (tipo y tamaño), *con avisos* (OCR, recortado, texto que parece dar órdenes) o *No se pudo leer* (el motivo está en el detalle). Tocar uno abre el detalle: lo que se leyó, los avisos, el error, la imagen exactamente como saldría y vista rápida del archivo.
- En la conversación, los adjuntos enviados aparecen como chips en la burbuja del usuario (se pueden abrir mientras la conversación siga abierta).
- Distinción visible de estados: *temporal* (en el redactor), *procesando*, *listo*, *error*. «Guardado en biblioteca» e «indexado» llegan con el Knowledge Engine (fase 3); hoy no existen y no se muestran.

## Pruebas

**Núcleo (`swift test`, CI)**: ≈ 100 pruebas nuevas — formatos por cabecera y rechazo de contradicciones; ZIP/DEFLATE con archivos reales, CRC, truncados, cifrado, bomba; DOCX y XLSX reales (títulos, listas, tablas, fórmulas, booleanos, fechas, hojas ocultas, números de fila); CSV/JSON/XML/Markdown/código; limpieza de PDF; selección de fragmentos y relevancia; neutralización, etiquetas y detector; comparación; matriz y enrutador (incluida «nunca envía sola una imagen a la nube»); política de imágenes; formato multimodal de la petición; motor con adjuntos (bloque, historial solo con metadatos, seguimiento, cambio de cerebro por un mensaje, **un archivo no puede autorizar acciones**, consultas siguen funcionando).
**App (simulador, CI)**: JPG, PNG con transparencia, HEIC (si el simulador lo codifica), WebP, orientación EXIF, PDF con texto y números de página, PDF escaneado con OCR, OCR de una foto, PDF con contraseña y dañado; centro de adjuntos (estados, errores, límites, archivos temporales); y dos pruebas de interfaz con adjuntos reales (menú de fuentes; estados y errores).

## Limitaciones y pendiente

- Sin probar en iPhone: cámara, escáner VisionKit, rendimiento con PDF grandes, envío real a Groq/Gemini (la forma de la petición se prueba, la respuesta del proveedor no).
- Las imágenes solo se envían con el mensaje que las trae; las preguntas siguientes no las vuelven a ver.
- DOCX: sin encabezados/pies/notas; páginas aproximadas. XLSX: sin gráficos ni celdas combinadas especiales.
- OCR: calidad variable (letra manuscrita, fotos torcidas); no describe imágenes.
- Biblioteca persistente, índice, búsqueda por significado y respuestas con fuentes guardadas: **fase 3**.
