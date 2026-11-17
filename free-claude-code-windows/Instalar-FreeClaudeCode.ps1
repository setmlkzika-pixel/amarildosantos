#Requires -Version 5.1
<#
  Instalar-FreeClaudeCode.ps1
  Instala e configura o Free Claude Code (FCC) no Windows 11, preservando o Claude Code original.

  Etapas:
    1. Verifica pre-requisitos
    2. Faz BACKUP de ~/.claude, ~/.claude.json, ~/.fcc e config do Claude Desktop (+ script de restauracao)
    3. Executa o instalador OFICIAL (com RTK + Headroom)
    4. Inicia o servidor FCC
    5. Configura provedores GRATUITOS (NVIDIA NIM obrigatorio; OpenRouter/Groq/Cerebras/Gemini opcionais)
       - as chaves sao digitadas de forma oculta e NUNCA aparecem no log
    6. Testa tudo (servidor, chaves, chamada real ao modelo, Claude Code via FCC, RTK, Headroom, Claude original)
    7. Cria atalho "Free Claude Code (Terminal)" na Area de Trabalho
    8. Gera relatorio

  Como executar (PowerShell normal, NAO precisa ser administrador):
    powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\Instalar-FreeClaudeCode.ps1"

  Opcoes:
    -PularInstalacao   Nao roda o instalador oficial (so configura/testa/cria atalho)
    -SomenteTestes     Apenas roda os testes e gera relatorio
#>
param(
    [switch] $PularInstalacao,
    [switch] $SomenteTestes
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$InstallerUrl = "https://raw.githubusercontent.com/Alishahryar1/free-claude-code/main/scripts/install.ps1"
$Base = "http://127.0.0.1:8082"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$Root = Join-Path $env:USERPROFILE "FreeClaudeCode-Setup"
$BackupDir = Join-Path $Root "backup-$Stamp"
$LogFile = Join-Path $Root "setup-$Stamp.log"
$ReportFile = Join-Path $Root "RELATORIO-$Stamp.txt"
New-Item -ItemType Directory -Force -Path $Root | Out-Null

$script:Resultados = New-Object System.Collections.Generic.List[object]
$script:Relatorio = New-Object System.Collections.Generic.List[string]

function Etapa([string] $t) { Write-Host ""; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Info([string] $t)  { Write-Host "  $t" }
function Aviso([string] $t) { Write-Host "  [AVISO] $t" -ForegroundColor Yellow }
function Registrar([string] $teste, [bool] $ok, [string] $detalhe) {
    $script:Resultados.Add([pscustomobject]@{ Teste = $teste; OK = $ok; Detalhe = $detalhe })
    if ($ok) { Write-Host "  [OK]    $teste - $detalhe" -ForegroundColor Green }
    else     { Write-Host "  [FALHA] $teste - $detalhe" -ForegroundColor Red }
}
function Atualizar-Path {
    $m = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $u = [Environment]::GetEnvironmentVariable("Path", "User")
    $extra = Join-Path $env:USERPROFILE ".local\bin"
    $env:Path = "$m;$u;$extra"
}
function Texto-Seguro([Security.SecureString] $s) {
    $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Hash-Arquivo([string] $p) {
    if (Test-Path -LiteralPath $p) { return (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
    return "(inexistente)"
}
function Rodar-Nativo([string] $exe, [string[]] $argumentos) {
    # PowerShell 5.1 + ErrorActionPreference=Stop transforma stderr de comando nativo em erro fatal; evita isso.
    $old = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    try { $o = & $exe @argumentos 2>&1 | Out-String; return [pscustomobject]@{ Saida = $o.Trim(); Codigo = $LASTEXITCODE } }
    finally { $ErrorActionPreference = $old }
}
function Servidor-Ativo {
    try { Invoke-RestMethod -Uri "$Base/admin/api/status" -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
}
function Obter-Config { return Invoke-RestMethod -Uri "$Base/admin/api/config" -TimeoutSec 30 }
function Aplicar-Config([hashtable] $values) {
    $body = ConvertTo-Json -InputObject @{ values = $values } -Depth 10 -Compress
    return Invoke-RestMethod -Uri "$Base/admin/api/config/apply" -Method Post -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60
}

Start-Transcript -Path $LogFile -Append | Out-Null
try {
# ---------------------------------------------------------------- 1. PRE-REQUISITOS
Etapa "1/8 Verificando pre-requisitos"
Atualizar-Path
$os = Get-CimInstance Win32_OperatingSystem
Info "Sistema: $($os.Caption) build $($os.BuildNumber) ($env:PROCESSOR_ARCHITECTURE)"
Info "PowerShell: $($PSVersionTable.PSVersion)"
if ([int]$os.BuildNumber -lt 22000) { Aviso "Este nao parece ser o Windows 11 (build < 22000). Continuando mesmo assim." }
if ($env:PROCESSOR_ARCHITECTURE -ne "AMD64") { Aviso "Arquitetura $($env:PROCESSOR_ARCHITECTURE) - RTK oficial para Windows e x86_64." }
$disco = Get-PSDrive -Name ($env:USERPROFILE.Substring(0,1))
Info ("Espaco livre em {0}: {1:N1} GB" -f $disco.Name, ($disco.Free / 1GB))
if ($disco.Free -lt 3GB) { Aviso "Pouco espaco livre (< 3 GB)." }
foreach ($cmd in @("claude", "uv", "python", "git", "winget", "node")) {
    $c = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($c) { Info ("{0,-7} encontrado: {1}" -f $cmd, $c.Source) } else { Info ("{0,-7} nao encontrado (o instalador cuida do que for necessario)" -f $cmd) }
}
$claudeOriginal = Get-Command claude -ErrorAction SilentlyContinue
if (-not $claudeOriginal) { Aviso "Claude Code nao encontrado no PATH. O instalador oficial vai instala-lo." }
foreach ($h in @("raw.githubusercontent.com", "integrate.api.nvidia.com")) {
    try { Invoke-WebRequest -Uri "https://$h" -Method Head -TimeoutSec 15 -UseBasicParsing | Out-Null; Info "Rede OK: $h" }
    catch { if ($_.Exception.Response) { Info "Rede OK: $h" } else { Aviso "Sem acesso a $h : $($_.Exception.Message)" } }
}
foreach ($v in @("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY")) {
    if ([Environment]::GetEnvironmentVariable($v, "User")) { Aviso "Variavel de usuario $v ja existe (valor nao exibido). O FCC NAO a altera." }
}

# ---------------------------------------------------------------- 2. BACKUP
$claudeDir = Join-Path $env:USERPROFILE ".claude"
$claudeJson = Join-Path $env:USERPROFILE ".claude.json"
$settingsJson = Join-Path $claudeDir "settings.json"
$hashAntesSettings = Hash-Arquivo $settingsJson
if (-not $SomenteTestes) {
    Etapa "2/8 Backup da configuracao atual (nada sera sobrescrito sem copia)"
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $itens = @(
        @{ Src = $claudeDir; Nome = ".claude" },
        @{ Src = $claudeJson; Nome = ".claude.json" },
        @{ Src = "$claudeJson.backup"; Nome = ".claude.json.backup" },
        @{ Src = (Join-Path $env:USERPROFILE ".fcc"); Nome = ".fcc" },
        @{ Src = (Join-Path $env:APPDATA "Claude\claude_desktop_config.json"); Nome = "claude_desktop_config.json" }
    )
    foreach ($i in $itens) {
        if (Test-Path -LiteralPath $i.Src) {
            $dest = Join-Path $BackupDir $i.Nome
            if ((Get-Item -LiteralPath $i.Src).PSIsContainer) {
                robocopy $i.Src $dest /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Falha no backup de $($i.Src) (robocopy $LASTEXITCODE)" }
            } else { Copy-Item -LiteralPath $i.Src -Destination $dest -Force }
            Info "Copiado: $($i.Src)"
        } else { Info "Nao existe (ok): $($i.Src)" }
    }
    $restaurar = @"
# Restaura a configuracao do Claude Code salva em $Stamp
# Feche o Claude Code, o Claude Desktop e o Free Claude Code antes de executar.
`$b = '$BackupDir'
if (Test-Path "`$b\.claude") { robocopy "`$b\.claude" "`$env:USERPROFILE\.claude" /E /R:1 /W:1 | Out-Null }
if (Test-Path "`$b\.claude.json") { Copy-Item "`$b\.claude.json" "`$env:USERPROFILE\.claude.json" -Force }
if (Test-Path "`$b\claude_desktop_config.json") { Copy-Item "`$b\claude_desktop_config.json" "`$env:APPDATA\Claude\claude_desktop_config.json" -Force }
Write-Host 'Configuracao original do Claude Code restaurada.'
"@
    Set-Content -Path (Join-Path $BackupDir "Restaurar-ClaudeCode.ps1") -Value $restaurar -Encoding UTF8
    Registrar "Backup" $true $BackupDir
}

# ---------------------------------------------------------------- 3. INSTALADOR OFICIAL
if (-not $PularInstalacao -and -not $SomenteTestes) {
    Etapa "3/8 Executando o instalador OFICIAL do Free Claude Code (com RTK + Headroom)"
    Write-Host "  O instalador vai perguntar quais agentes instalar." -ForegroundColor Yellow
    Write-Host "  - Claude Code: ja instalado -> sera apenas verificado (sua instalacao e preservada)." -ForegroundColor Yellow
    Write-Host "  - Para os DEMAIS agentes (Codex, Pi, OpenCode...), apenas aperte ENTER (= Nao)." -ForegroundColor Yellow
    Write-Host "  - Se o Claude Code NAO estiver instalado, responda 'y' para ele." -ForegroundColor Yellow
    Write-Host ""
    & ([scriptblock]::Create((Invoke-RestMethod $InstallerUrl))) -RtkHeadroom
    Atualizar-Path
}

# ---------------------------------------------------------------- 4. SERVIDOR
Etapa "4/8 Iniciando o servidor FCC"
Atualizar-Path
$fccServer = Get-Command fcc-server -ErrorAction SilentlyContinue
if (-not $fccServer) { throw "fcc-server nao encontrado apos a instalacao. Veja o log: $LogFile" }
$ver = Rodar-Nativo $fccServer.Source @("--version")
Registrar "fcc-server --version" ($ver.Codigo -eq 0) $ver.Saida
if (-not (Servidor-Ativo)) {
    $desktopApp = Get-Command fcc-desktop -ErrorAction SilentlyContinue
    if ($desktopApp) {
        Info "Abrindo o app oficial (icone na bandeja do Windows)..."
        Start-Process -FilePath $desktopApp.Source | Out-Null
    } else {
        $srvLog = Join-Path $Root "fcc-server-$Stamp.log"
        Start-Process -FilePath $fccServer.Source -WindowStyle Hidden -RedirectStandardOutput $srvLog -RedirectStandardError "$srvLog.err" | Out-Null
    }
    for ($i = 0; $i -lt 90 -and -not (Servidor-Ativo); $i++) { Start-Sleep -Seconds 1 }
}
Registrar "Servidor em $Base" (Servidor-Ativo) "Admin UI: $Base/admin"
if (-not (Servidor-Ativo)) { throw "O servidor FCC nao respondeu em 90 s." }

# ---------------------------------------------------------------- 5. PROVEDORES GRATUITOS
$provedores = @(
    @{ Id = "nvidia_nim";  Key = "NVIDIA_NIM_API_KEY"; Nome = "NVIDIA NIM";  Url = "https://build.nvidia.com/settings/api-keys"; Modelo = "nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b"; Obrig = $true;  Obs = "gratuito para membros do NVIDIA Developer Program" },
    @{ Id = "open_router"; Key = "OPENROUTER_API_KEY"; Nome = "OpenRouter";  Url = "https://openrouter.ai/keys";                  Modelo = "open_router/openrouter/free";                  Obrig = $false; Obs = "use SO o roteador 'openrouter/free' (modelos :free). Nao compre creditos." },
    @{ Id = "groq";        Key = "GROQ_API_KEY";       Nome = "Groq";        Url = "https://console.groq.com/keys";               Modelo = "groq/llama-3.3-70b-versatile";                 Obrig = $false; Obs = "plano Free, sem cartao" },
    @{ Id = "cerebras";    Key = "CEREBRAS_API_KEY";   Nome = "Cerebras";    Url = "https://cloud.cerebras.ai/";                  Modelo = "cerebras/gpt-oss-120b";                        Obrig = $false; Obs = "plano Free, sem cartao" },
    @{ Id = "gemini";      Key = "GEMINI_API_KEY";     Nome = "Google AI Studio (Gemini)"; Url = "https://aistudio.google.com/apikey"; Modelo = "gemini/models/gemini-3.1-flash-lite";   Obrig = $false; Obs = "SO e gratis se o projeto Google NAO tiver faturamento ativado" }
)
if (-not $SomenteTestes) {
    Etapa "5/8 Configurando provedores GRATUITOS (as chaves ficam ocultas)"
    Info "Nenhum provedor pago (Anthropic, OpenAI API etc.) sera configurado."
    $cfg = Obter-Config
    foreach ($p in $provedores) {
        $campo = $cfg.fields | Where-Object { $_.key -eq $p.Key }
        $jaTem = [bool]$campo.configured
        Write-Host ""
        Write-Host "  $($p.Nome) - chave em: $($p.Url)" -ForegroundColor White
        Write-Host "  ($($p.Obs))"
        $sufixo = if ($jaTem) { " [ENTER = manter a chave ja salva]" } elseif ($p.Obrig) { " [obrigatorio]" } else { " [ENTER = pular]" }
        $seg = Read-Host -AsSecureString "  Cole a chave $($p.Nome)$sufixo"
        $chave = (Texto-Seguro $seg).Trim()
        if (-not $chave) {
            if ($p.Obrig -and -not $jaTem) { throw "A chave NVIDIA NIM e necessaria. Gere em $($p.Url) e rode o script de novo." }
            continue
        }
        $r = Aplicar-Config @{ $p.Key = @{ revision = $campo.value.revision; entries = @(@{ value = $chave }) } }
        $chave = $null
        if ($r.applied) { Info "$($p.Nome): chave salva (mascarada em ~/.fcc/.env)." } else { Aviso "$($p.Nome): nao aplicado: $(($r.errors | ConvertTo-Json -Compress))" }
        $cfg = Obter-Config
    }

    # Modelo principal + fallbacks (somente provedores gratuitos configurados)
    $cfg = Obter-Config
    $configurados = @($provedores | Where-Object { $k = $_.Key; ($cfg.fields | Where-Object { $_.key -eq $k }).configured })
    $fallbacks = @($configurados | Where-Object { $_.Id -ne "nvidia_nim" } | ForEach-Object { @{ model = $_.Modelo } })
    $vals = @{ MODEL = "nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b" }
    if ($fallbacks.Count -gt 0) { $vals.MODEL_FALLBACKS = $fallbacks }
    $r = Aplicar-Config $vals
    Registrar "Modelo padrao + fallbacks" ([bool]$r.applied) ("MODEL=nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b; fallbacks: " + (($fallbacks | ForEach-Object { $_.model }) -join ", "))
}

# ---------------------------------------------------------------- 6. TESTES
Etapa "6/8 Testes"
$cfg = Obter-Config
$configurados = @($provedores | Where-Object { $k = $_.Key; ($cfg.fields | Where-Object { $_.key -eq $k }).configured })
foreach ($p in $configurados) {
    try {
        $t = Invoke-RestMethod -Uri "$Base/admin/api/providers/$($p.Id)/test" -Method Post -ContentType "application/json" -Body "{}" -TimeoutSec 90
        Registrar "Chave $($p.Nome)" ([bool]$t.ok) ([string]$t.message)
    } catch { Registrar "Chave $($p.Nome)" $false $_.Exception.Message }
}
# Pagos nao configurados?
foreach ($pago in @("ANTHROPIC_API_KEY", "OPENAI_API_KEY")) {
    $f = $cfg.fields | Where-Object { $_.key -eq $pago }
    Registrar "Sem provedor pago ($pago)" (-not ($f -and $f.configured)) "garante que nada sera cobrado"
}
# Lista de modelos
$modelos = @()
try {
    $lista = Invoke-RestMethod -Uri "$Base/v1/models?view=messages" -TimeoutSec 60
    $ids = @($configurados | ForEach-Object { $_.Id + "/" })
    $modelos = @($lista.data | ForEach-Object { $_.id } | Where-Object { $m = $_; @($ids | Where-Object { $m.StartsWith($_) }).Count -gt 0 } | Sort-Object)
    Registrar "Lista de modelos" ($modelos.Count -gt 0) "$($modelos.Count) modelos gratuitos disponiveis"
} catch { Registrar "Lista de modelos" $false $_.Exception.Message }
# Chamada real ao modelo
try {
    $req = @{ model = "nvidia_nim/nvidia/nemotron-3-ultra-550b-a55b"; max_tokens = 200; messages = @(@{ role = "user"; content = "Responda somente: FCC OK" }) }
    $resp = Invoke-RestMethod -Uri "$Base/v1/messages" -Method Post -ContentType "application/json" -Body (ConvertTo-Json $req -Depth 6 -Compress) -TimeoutSec 180
    $txt = (@($resp.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join " ").Trim()
    Registrar "Chamada /v1/messages (NIM)" ($txt.Length -gt 0) "resposta: $txt"
} catch { Registrar "Chamada /v1/messages (NIM)" $false $_.Exception.Message }
# Claude Code via FCC (modo nao interativo)
$fccClaude = Get-Command fcc-claude -ErrorAction SilentlyContinue
if ($fccClaude) {
    $tmp = Join-Path $env:TEMP "fcc-teste-$Stamp"; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $job = Start-Job -ScriptBlock { param($exe, $dir) Set-Location $dir; & $exe -p "Responda somente: CLAUDE VIA FCC OK" 2>&1 | Out-String } -ArgumentList $fccClaude.Source, $tmp
    if (Wait-Job $job -Timeout 240) { $out = (Receive-Job $job | Out-String).Trim() } else { Stop-Job $job; $out = "(tempo esgotado)" }
    Remove-Job $job -Force
    Registrar "fcc-claude -p (Claude Code usando modelo gratuito)" ($out -match "OK") ($out.Substring(0, [Math]::Min(200, $out.Length)))
} else { Registrar "fcc-claude" $false "comando nao encontrado" }
# RTK e Headroom
foreach ($t in @(@("rtk", "--version"), @("headroom", "--version"))) {
    $c = Get-Command $t[0] -ErrorAction SilentlyContinue
    if ($c) { $o = Rodar-Nativo $c.Source @($t[1]); Registrar "Otimizacao $($t[0])" ($o.Codigo -eq 0) $o.Saida }
    else { Registrar "Otimizacao $($t[0])" $false "nao instalado" }
}
# Claude Code original preservado
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) { $o = Rodar-Nativo $claudeCmd.Source @("--version"); Registrar "Claude Code original (claude --version)" ($o.Codigo -eq 0) $o.Saida }
$envOk = -not [Environment]::GetEnvironmentVariable("ANTHROPIC_BASE_URL", "User")
Registrar "Comando 'claude' continua na sua conta Anthropic" $envOk "ANTHROPIC_BASE_URL nao foi fixado no usuario; so o fcc-claude usa o proxy"
$hashDepois = Hash-Arquivo $settingsJson
if ($hashDepois -ne $hashAntesSettings) { Info "~/.claude/settings.json foi alterado (esperado: hooks do RTK). Original no backup: $BackupDir" }
else { Info "~/.claude/settings.json inalterado." }

# ---------------------------------------------------------------- 7. ATALHOS
if (-not $SomenteTestes) {
    Etapa "7/8 Criando atalhos"
    $sh = New-Object -ComObject WScript.Shell
    $desk = [Environment]::GetFolderPath("Desktop")
    $lnk = $sh.CreateShortcut((Join-Path $desk "Free Claude Code (Terminal).lnk"))
    $lnk.TargetPath = (Get-Command powershell.exe).Source
    $lnk.Arguments = '-NoExit -NoLogo -Command "Set-Location $env:USERPROFILE; fcc-claude"'
    $lnk.WorkingDirectory = $env:USERPROFILE
    $lnk.Description = "Claude Code usando modelos gratuitos (Free Claude Code)"
    $ico = Get-ChildItem -Path (Join-Path $env:USERPROFILE ".fcc") -Filter *.ico -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($ico) { $lnk.IconLocation = $ico.FullName }
    $lnk.Save()
    Registrar "Atalho 'Free Claude Code (Terminal)'" (Test-Path (Join-Path $desk "Free Claude Code (Terminal).lnk")) "Area de Trabalho"
    $oficial = Join-Path $desk "Free Claude Code.lnk"
    Registrar "Atalho oficial 'Free Claude Code' (servidor + bandeja)" (Test-Path $oficial) "criado pelo instalador oficial"
}

# ---------------------------------------------------------------- 8. RELATORIO
Etapa "8/8 Relatorio"
$script:Relatorio.Add("FREE CLAUDE CODE - RELATORIO $Stamp")
$script:Relatorio.Add("Backup: $BackupDir  (restaurar: Restaurar-ClaudeCode.ps1)")
$script:Relatorio.Add("Log: $LogFile")
$script:Relatorio.Add("")
$script:Relatorio.Add("TESTES:")
foreach ($r in $script:Resultados) { $script:Relatorio.Add(("  [{0}] {1} - {2}" -f $(if ($r.OK) { "OK" } else { "FALHA" }), $r.Teste, $r.Detalhe)) }
$script:Relatorio.Add("")
$script:Relatorio.Add("PROVEDORES GRATUITOS CONFIGURADOS: " + (($configurados | ForEach-Object { $_.Nome }) -join ", "))
$script:Relatorio.Add("")
$script:Relatorio.Add("MODELOS DISPONIVEIS ($($modelos.Count)):")
foreach ($m in $modelos) { $script:Relatorio.Add("  $m") }
$script:Relatorio.Add("")
$script:Relatorio.Add("COMO USAR:")
$script:Relatorio.Add("  - Duplo clique em 'Free Claude Code (Terminal)' na Area de Trabalho, ou digite: fcc-claude")
$script:Relatorio.Add("  - Trocar modelo: dentro do Claude Code use /model, ou abra $Base/admin")
$script:Relatorio.Add("  - 'claude' (sem fcc-) continua usando sua conta Anthropic normal.")
$script:Relatorio | Set-Content -Path $ReportFile -Encoding UTF8
$falhas = @($script:Resultados | Where-Object { -not $_.OK }).Count
Write-Host ""
if ($falhas -eq 0) { Write-Host "TUDO OK. Relatorio: $ReportFile" -ForegroundColor Green }
else { Write-Host "$falhas teste(s) falharam. Relatorio: $ReportFile" -ForegroundColor Red }
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Log completo: $LogFile"
    if (Test-Path $BackupDir) { Write-Host "Backup da sua configuracao original: $BackupDir" }
}
finally {
    Stop-Transcript | Out-Null
}
