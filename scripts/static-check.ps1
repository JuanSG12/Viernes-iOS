# Verificación ESTÁTICA del proyecto (corre en Windows/macOS/Linux con PowerShell 7).
# NO sustituye a compilar con Xcode: solo detecta errores que se pueden ver sin compilador.
#   pwsh scripts/static-check.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = New-Object System.Collections.Generic.List[string]
$checks = 0
function Fail($msg) { $script:failures.Add($msg) | Out-Null; Write-Host "  FALLO: $msg" -ForegroundColor Red }
function Ok($msg) { Write-Host "  ok: $msg" -ForegroundColor Green }

$swiftFiles = Get-ChildItem -Path $root -Recurse -Filter *.swift | Where-Object { $_.FullName -notmatch '[\\/](\.build|\.swiftpm|build|DerivedData)[\\/]' }
# Rutas portables (el CI corre este script en Linux): se escriben con '/' y PowerShell las acepta en todos los sistemas.
function P([string]$relative) { Join-Path $root ($relative -replace '\\', '/') }
Write-Host "Archivos Swift: $($swiftFiles.Count)"

# ---------------------------------------------------------------- 1. Delimitadores balanceados (lexer mínimo de Swift)
function Test-SwiftBalance([string]$text) {
    $stack = New-Object System.Collections.Generic.Stack[char]
    $i = 0; $n = $text.Length
    # pila de contextos de cadena para interpolación: cada entrada = profundidad de paréntesis al entrar en \( ... )
    $strStack = New-Object System.Collections.Generic.Stack[hashtable]
    $inString = $false; $multi = $false; $rawHashes = 0
    $blockDepth = 0
    $line = 1
    $pairs = @{ ')' = '('; ']' = '['; '}' = '{' }
    while ($i -lt $n) {
        $c = $text[$i]
        if ($c -eq "`n") { $line++ }
        if ($blockDepth -gt 0) {
            if ($c -eq '*' -and $i + 1 -lt $n -and $text[$i+1] -eq '/') { $blockDepth--; $i += 2; continue }
            if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i+1] -eq '*') { $blockDepth++; $i += 2; continue }
            $i++; continue
        }
        if ($inString -and $rawHashes -gt 0) {
            # Cadena CRUDA (#"…"#): la barra invertida es literal; solo \#( interpola y solo «"» + los # de apertura la cierra.
            $hashRun = $true
            for ($k = 1; $k -le $rawHashes; $k++) { if ($i + $k -ge $n -or $text[$i+$k] -ne '#') { $hashRun = $false; break } }
            if ($c -eq '\' -and $hashRun -and $i + $rawHashes + 1 -lt $n -and $text[$i+$rawHashes+1] -eq '(') {
                $strStack.Push(@{ multi = $multi; raw = $rawHashes; depth = $stack.Count })
                $stack.Push('('); $inString = $false; $i += $rawHashes + 2; continue
            }
            if ($c -eq '"') {
                $closes = $true
                $offset = 1
                if ($multi) { $offset = 3; if (-not ($i + 2 -lt $n -and $text[$i+1] -eq '"' -and $text[$i+2] -eq '"')) { $closes = $false } }
                if ($closes) {
                    for ($k = 0; $k -lt $rawHashes; $k++) { if ($i + $offset + $k -ge $n -or $text[$i+$offset+$k] -ne '#') { $closes = $false; break } }
                }
                if ($closes) { $inString = $false; $i += $offset + $rawHashes; $rawHashes = 0; continue }
            }
            if (-not $multi -and $c -eq "`n") { return "línea ${line}: cadena sin cerrar" }
            $i++; continue
        }
        if ($inString) {
            if ($c -eq '\') {
                if ($i + 1 -lt $n -and $text[$i+1] -eq '(') {
                    # interpolación: se apila el contexto de cadena y se vuelve a código
                    $strStack.Push(@{ multi = $multi; depth = $stack.Count })
                    $stack.Push('('); $inString = $false; $i += 2; continue
                }
                $i += 2; continue
            }
            if ($multi) {
                if ($c -eq '"' -and $i + 2 -lt $n -and $text[$i+1] -eq '"' -and $text[$i+2] -eq '"') { $inString = $false; $i += 3; continue }
            } else {
                if ($c -eq '"') { $inString = $false; $i++; continue }
                if ($c -eq "`n") { return "línea ${line}: cadena sin cerrar" }
            }
            $i++; continue
        }
        # código normal
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i+1] -eq '/') { while ($i -lt $n -and $text[$i] -ne "`n") { $i++ }; continue }
        if ($c -eq '/' -and $i + 1 -lt $n -and $text[$i+1] -eq '*') { $blockDepth = 1; $i += 2; continue }
        if ($c -eq '#') {
            $j = $i
            while ($j -lt $n -and $text[$j] -eq '#') { $j++ }
            if ($j -lt $n -and $text[$j] -eq '"') {
                $rawHashes = $j - $i
                if ($j + 2 -lt $n -and $text[$j+1] -eq '"' -and $text[$j+2] -eq '"') { $inString = $true; $multi = $true; $i = $j + 3; continue }
                $inString = $true; $multi = $false; $i = $j + 1; continue
            }
        }
        if ($c -eq '"') {
            if ($i + 2 -lt $n -and $text[$i+1] -eq '"' -and $text[$i+2] -eq '"') { $inString = $true; $multi = $true; $i += 3; continue }
            $inString = $true; $multi = $false; $i++; continue
        }
        if ($c -eq '(' -or $c -eq '[' -or $c -eq '{') { $stack.Push($c); $i++; continue }
        if ($c -eq ')' -or $c -eq ']' -or $c -eq '}') {
            if ($stack.Count -eq 0) { return "línea ${line}: '$c' sin apertura" }
            $top = $stack.Pop()
            if ($top -ne $pairs[[string]$c]) { return "línea ${line}: '$c' no cierra '$top'" }
            # ¿cerró una interpolación?
            if ($c -eq ')' -and $strStack.Count -gt 0 -and $stack.Count -eq $strStack.Peek().depth) {
                $ctx = $strStack.Pop(); $inString = $true; $multi = $ctx.multi
                $rawHashes = if ($ctx.ContainsKey('raw')) { $ctx.raw } else { 0 }
            }
            $i++; continue
        }
        $i++
    }
    if ($inString) { return "cadena sin cerrar al final del archivo" }
    if ($blockDepth -gt 0) { return "comentario de bloque sin cerrar" }
    if ($stack.Count -gt 0) { return "delimitador '$($stack.Peek())' sin cerrar" }
    return $null
}

Write-Host "`n[1] Delimitadores balanceados"
$checks++
$balanceErrors = 0
foreach ($f in $swiftFiles) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    $err = Test-SwiftBalance $text
    if ($err) { Fail "$($f.FullName.Substring($root.Length + 1)): $err"; $balanceErrors++ }
}
if ($balanceErrors -eq 0) { Ok "todos los archivos Swift tienen delimitadores y cadenas balanceados" }

# ---------------------------------------------------------------- 2. El core es portable (solo Foundation)
Write-Host "`n[2] ViernesCore solo importa Foundation"
$checks++
$coreBad = 0
foreach ($f in $swiftFiles | Where-Object { $_.FullName -match '[\\/]Sources[\\/]ViernesCore[\\/]' }) {
    foreach ($m in [regex]::Matches([System.IO.File]::ReadAllText($f.FullName), '(?m)^\s*import\s+(\w+)')) {
        if ($m.Groups[1].Value -ne 'Foundation') { Fail "$($f.Name) importa $($m.Groups[1].Value)"; $coreBad++ }
    }
}
if ($coreBad -eq 0) { Ok "ningún framework de Apple fuera de Foundation en el core" }

# ---------------------------------------------------------------- 3. Nada prohibido en el código
Write-Host "`n[3] Sin claves ni endpoints de Anthropic, sin modos de fondo"
$checks++
$forbidden = @('api.anthropic.com', 'x-api-key', 'anthropic-version', 'ANTHROPIC_API_KEY')
$secretRegex = 'sk-ant-[A-Za-z0-9_\-]{10,}'
$bad = 0
foreach ($f in $swiftFiles | Where-Object { $_.FullName -notmatch '[\\/]Tests[\\/]|[\\/]ViernesTests[\\/]|[\\/]ViernesUITests[\\/]' }) {
    $text = [System.IO.File]::ReadAllText($f.FullName)
    foreach ($p in $forbidden) { if ($text.Contains($p)) { Fail "$($f.Name) contiene '$p'"; $bad++ } }
    if ($text -match $secretRegex) { Fail "$($f.Name) contiene algo con forma de clave de Anthropic"; $bad++ }
}
$yml = [System.IO.File]::ReadAllText((Join-Path $root 'project.yml'))
if ($yml -match '(?m)^\s*UIBackgroundModes\s*:') { Fail 'project.yml declara UIBackgroundModes (Viernes no escucha en segundo plano)'; $bad++ }
if ($bad -eq 0) { Ok "ningún endpoint/clave de Anthropic; sin UIBackgroundModes" }

# ---------------------------------------------------------------- 4. Info.plist: descripciones de uso
Write-Host "`n[4] Textos de permisos en project.yml"
$checks++
$missing = 0
foreach ($key in 'NSMicrophoneUsageDescription','NSSpeechRecognitionUsageDescription','NSRemindersFullAccessUsageDescription','NSCalendarsWriteOnlyAccessUsageDescription','NSCalendarsFullAccessUsageDescription','NSContactsUsageDescription','NSFaceIDUsageDescription','CFBundleURLSchemes') {
    if ($yml -notmatch [regex]::Escape($key)) { Fail "falta $key en project.yml"; $missing++ }
}
if ($missing -eq 0) { Ok "todas las claves de privacidad y el esquema viernes:// están declaradas" }

# ---------------------------------------------------------------- 5. Cada herramienta del catálogo tiene ejecutor
Write-Host "`n[5] Herramientas: catálogo ↔ ejecutor ↔ validador"
$checks++
$toolsFile = [System.IO.File]::ReadAllText((P 'Sources/ViernesCore/Tools.swift'))
$toolNames = [regex]::Matches($toolsFile, 'ToolDefinition\(\s*name:\s*"([a-z_]+)"') | ForEach-Object { $_.Groups[1].Value }
$memoryTools = @('save_memory', 'forget_memory', 'search_memory')
$executor = [System.IO.File]::ReadAllText((P 'App/Viernes/Tools/DeviceToolExecutor.swift'))
$engine = [System.IO.File]::ReadAllText((P 'Sources/ViernesCore/ConversationEngine.swift'))
$validator = [System.IO.File]::ReadAllText((P 'Sources/ViernesCore/ToolValidator.swift'))
$toolBad = 0
foreach ($t in $toolNames) {
    if ($memoryTools -contains $t) {
        if ($engine -notmatch "case `"$t`"") { Fail "herramienta de memoria '$t' sin implementación en ConversationEngine"; $toolBad++ }
    } elseif ($executor -notmatch "case `"$t`"") { Fail "herramienta '$t' sin case en DeviceToolExecutor"; $toolBad++ }
    if ($engine -notmatch "case `"$t`"" -and $t -notin $memoryTools) { }
}
foreach ($m in [regex]::Matches($executor, 'case "([a-z_]+)":\s*return')) {
    if ($toolNames -notcontains $m.Groups[1].Value) { Fail "DeviceToolExecutor maneja '$($m.Groups[1].Value)' que no está en el catálogo"; $toolBad++ }
}
if ($toolBad -eq 0) { Ok "$($toolNames.Count) herramientas: todas implementadas y sin huérfanas" }

# ---------------------------------------------------------------- 6. Identificadores de las pruebas de UI existen en la app
Write-Host "`n[6] Identificadores de pruebas de UI ↔ código de la app"
$checks++
$appText = ($swiftFiles | Where-Object { $_.FullName -match '[\\/]App[\\/]Viernes[\\/]' } | ForEach-Object { [System.IO.File]::ReadAllText($_.FullName) }) -join "`n"
$uiTests = [System.IO.File]::ReadAllText((P 'App/ViernesUITests/ViernesUITests.swift'))
$literals = [regex]::Matches($uiTests, '(?:buttons|textFields|switches|otherElements|staticTexts|navigationBars)\["([^"]+)"\]') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
$literals += [regex]::Matches($uiTests, '\(id: "([^"]+)", title: "([^"]+)"\)|\("(settings-[a-z]+)", "([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value, $_.Groups[4].Value } | Where-Object { $_ }
$literals += [regex]::Matches($uiTests, 'field\(app, "([^"]+)"\)') | ForEach-Object { $_.Groups[1].Value }
$literals += [regex]::Matches($uiTests, 'for id in \[([^\]]+)\]') | ForEach-Object { [regex]::Matches($_.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } }
$typed = [regex]::Matches($uiTests, 'typeText\("([^"]+)"[,)]') | ForEach-Object { $_.Groups[1].Value }   # texto que la prueba escribe, no identificadores
$literals = $literals | Where-Object { $typed -notcontains $_ }
$uiBad = 0
foreach ($lit in ($literals | Sort-Object -Unique)) {
    $found = $appText.Contains("`"$lit`"")
    if (-not $found -and $lit -match '^(.+-)[A-Za-z]+$') { $found = $appText.Contains("`"$($Matches[1])\(") }
    if (-not $found) { Fail "las pruebas de UI usan '$lit' pero no existe en App/Viernes"; $uiBad++ }
}
if ($uiBad -eq 0) { Ok "$(($literals | Sort-Object -Unique).Count) identificadores/textos de UI verificados contra el código" }

# ---------------------------------------------------------------- 7. Los 9 documentos obligatorios
Write-Host "`n[7] Documentación requerida"
$checks++
$docBad = 0
foreach ($d in 'README','PLAN','ARCHITECTURE','SECURITY','INSTALL','VOICE','CLAUDE_INTEGRATION','LOCAL_MODELS','CHANGELOG') {
    $p = Join-Path $root "$d.md"
    if (-not (Test-Path $p)) { Fail "falta $d.md"; $docBad++ } elseif ((Get-Item $p).Length -lt 800) { Fail "$d.md es demasiado corto"; $docBad++ }
}
if ($docBad -eq 0) { Ok "los 9 documentos existen y tienen contenido" }

# ---------------------------------------------------------------- Resumen
$testCount = ($swiftFiles | Where-Object { $_.FullName -match 'Tests' } | ForEach-Object { ([regex]::Matches([System.IO.File]::ReadAllText($_.FullName), '(?m)^\s*func test\w+')).Count } | Measure-Object -Sum).Sum
Write-Host "`nPruebas declaradas: $testCount (NO ejecutadas aquí: requieren Xcode/Swift)"
if ($failures.Count -gt 0) {
    Write-Host "`n$($failures.Count) fallo(s) en $checks comprobaciones." -ForegroundColor Red
    exit 1
}
Write-Host "`nTodas las comprobaciones estáticas pasaron ($checks)." -ForegroundColor Green
