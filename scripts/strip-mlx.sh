#!/usr/bin/env bash
# Quita de project.yml los paquetes y productos de MLX (mlx-swift-lm, swift-huggingface, swift-transformers).
# El código usa `#if canImport(MLXLLM)`, así que la app compila solo con Apple Intelligence. Sirve en CI para
# separar errores de MLXEngine.swift (API de mlx-swift-lm sin verificar) de errores del resto de la app.
# Uso: scripts/strip-mlx.sh project.yml > project.nomlx.yml
set -euo pipefail
awk '
  # bloque de paquete remoto: línea "  Nombre:" y todas las siguientes con 4+ espacios
  /^  (MLXSwiftLM|SwiftHuggingFace|SwiftTransformers):[[:space:]]*$/ { skipblock = 1; next }
  skipblock && /^    / { next }
  { skipblock = 0 }
  # dependencia "- package: X" seguida de "  product: Y"
  /^      - package: (MLXSwiftLM|SwiftHuggingFace|SwiftTransformers)[[:space:]]*$/ { skipdep = 1; next }
  skipdep && /^        product:/ { skipdep = 0; next }
  { skipdep = 0; print }
' "$1"
