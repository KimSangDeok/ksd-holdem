# 홀덤 코치 중계 서버
# holdem.html 의 채팅을 받아 Claude Code CLI(claude -p)로 전달하고 답변을 돌려준다.
# 실행: 배포 서버(리눅스)에서 서비스로 상시 구동한다. 집 PC에서 .bat으로 실행하던 방식은 더 이상 쓰지 않는다.

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

# 게임 행동 음성 안내용 Windows TTS (Microsoft Heami)
# 리눅스(오라클 VM)에는 System.Speech가 없으므로 윈도우에서만 로드.
# 원격 접속 시 게임(speak, 871행대)이 브라우저 TTS를 우선 쓰므로 서버 음성 없어도 동작 동일.
$script:tts = $null
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') {
    Add-Type -AssemblyName System.Speech
    $script:tts = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $script:tts.Volume = 100
    $script:tts.Rate = 2
    try { $script:tts.SelectVoiceByHints([System.Speech.Synthesis.VoiceGender]::NotSet, [System.Speech.Synthesis.VoiceAge]::NotSet, 0, [System.Globalization.CultureInfo]::new('ko-KR')) } catch {}
}

$port = 8765
# 모든 인터페이스에 바인딩 시도 (모바일 접속 허용) → 권한 없으면 localhost 전용 폴백
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://+:$port/")
$lanMode = $true
try {
    $listener.Start()
} catch {
    $lanMode = $false
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add("http://localhost:$port/")
    try {
        $listener.Start()
    } catch {
        Write-Host "포트 $port 를 열 수 없습니다." -ForegroundColor Yellow
        Write-Host "이미 서버가 켜져 있다는 뜻이므로, 이 창은 닫아도 됩니다."
        Start-Sleep -Seconds 5
        exit 0
    }
}

Write-Host ""
Write-Host "  🃏 홀덤 코치 서버 시작됨  (http://localhost:$port)" -ForegroundColor Green
Write-Host "  브라우저에서 http://localhost:$port 를 열면 게임이 나옵니다."
if ($lanMode) {
    # Get-NetIPAddress는 윈도우 전용 — 리눅스에서는 hostname -I 로 대체 (표시용이라 실패해도 무해)
    $ip = $null
    try {
        if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
            $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1 -ExpandProperty IPAddress)
        } elseif (Get-Command hostname -ErrorAction SilentlyContinue) {
            $hostOut = & hostname -I 2>$null
            $ip = ("$hostOut" -split '\s+' | Where-Object { $_ -match '^\d+\.' } | Select-Object -First 1)
        }
    } catch {}
    if ($ip) { Write-Host "  📱 원격 접속: http://${ip}:$port" -ForegroundColor Cyan }
} else {
    Write-Host "  (모바일 접속 비활성 — localhost 전용 모드)" -ForegroundColor Yellow
}
Write-Host "  이 서버 프로세스가 멈추면 코치 채팅이 중단됩니다. (게임 자체는 계속 가능)"
Write-Host ""

$script:sessionId = $null
# 서명된 /status 로 보는 서버 정보. 서버 화면 출력은 밖에서 볼 수 없어서 오류는 따로 모아 둔다(최근 100건)
$script:startedAt = Get-Date
$script:selfSha = '?'
try { $script:selfSha = (Get-FileHash -Algorithm SHA1 -LiteralPath $PSCommandPath).Hash.Substring(0, 12).ToLower() } catch {}
$script:recentErrors = New-Object System.Collections.Generic.Queue[string]
function Add-ServerError([string]$msg) {
    try {
        # 인증 없는 요청이 보낸 글이 오류 문구에 섞일 수 있다(예: JSON 해석 오류에 키 이름이 그대로 실림).
        # 한 줄·120자로 줄이고, JSON 해석 오류는 내용 없이 적는다
        if ($msg -match 'JSON') { $msg = ($msg -split ':')[0] + ': 본문 JSON 형식 오류' }
        $msg = $msg -replace '\s+', ' '
        if ($msg.Length -gt 120) { $msg = $msg.Substring(0, 120) + '…' }
        $script:recentErrors.Enqueue((Get-Date -Format 'MM-dd HH:mm:ss') + '  ' + $msg)
        while ($script:recentErrors.Count -gt 100) { [void]$script:recentErrors.Dequeue() }
    } catch {}
}
# 세션 누적 호출 수. 이 횟수를 넘으면 세션을 새로 시작해 응답 속도를 되돌린다.
# (대화가 길어질수록 --resume 이 실어 나르는 양이 커져 느려지기 때문)
$script:turnCount = 0
$script:sessionMaxTurns = 20

# 코치가 사용할 모델. 빠르고 가벼운 코칭엔 sonnet 추천.
# 더 깊은 분석을 원하면 'claude-opus-4-8' 등으로 바꾸세요.
$coachModel = 'claude-sonnet-5'

$claudeExe = (Get-Command claude).Source

# 설치된 claude 가 이 서버가 쓰는 플래그를 아는지 시작할 때 한 번 확인한다 (API 호출 없음).
# 모르는 플래그를 넘기면 코치 호출이 전부 실패하므로, 없는 플래그는 빼고 돈다.
$script:cliHelp = ''
$script:cliVersion = ''
try {
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $script:cliHelp = (& $claudeExe --help 2>$null | Out-String)
    $script:cliVersion = ((& $claudeExe --version 2>$null | Out-String).Trim())
    $ErrorActionPreference = $prevEap
} catch { $ErrorActionPreference = 'Stop' }
$script:canSystemPromptFile = [bool]($script:cliHelp -match '--system-prompt-file')
$script:canTools = [bool]($script:cliHelp -match '--tools')
Write-Host ("  claude {0} / 시스템 프롬프트 파일 {1} / 도구 끄기 {2}" -f
    $(if ($script:cliVersion) { $script:cliVersion } else { '(버전 확인 실패)' }),
    $(if ($script:canSystemPromptFile) { '지원' } else { '미지원 → 역할문을 메시지로 보냄' }),
    $(if ($script:canTools) { '지원' } else { '미지원' }))

# ===== 인증 기관 키 유출(eMudhra, 2026-10) 대응 =====
# claude 는 기본으로 '자기 안에 든 인증서 목록(번들)'과 '우분투 목록'을 함께 믿는다. 2.1.302 이하는 키가 유출된 emSign 루트를
# 번들에 넣은 채 그대로 믿고(검증 실측: npm 2.1.260 바이너리 안에 인증서 원본), 2.1.303 부터 자체 거부 목록으로 막으며
# 2.1.304 부터 번들에서도 뺐다. 이 서버는 claude 를 -p 로만 써서 자동 업데이트가 돌지 않았다(9월 판 그대로였음 — 자동 업데이트는 대화형 화면에만 있음).
# 1) 임시 조치: 코치 호출은 우분투 목록만 믿게 한다(CLAUDE_CODE_CERT_STORE=system). 우분투 목록은 자동 보안 업데이트가 켜져 있으면
#    매일 갱신되지만(ca-certificates 20260816ubuntu0.22.04.1 부터 G3 제외), 번들은 claude 를 올려야만 바뀐다.
#    단, 우분투는 G3 하나만 뺐고 같은 회사의 G1·C1·C3 는 남았다 — claude 2.1.303 이상은 넷 다 막는다. 근본 해결은 업데이트다.
#    2.1.260 도 이 설정을 알아듣고, 우분투 목록이 비었거나 못 읽으면 조용히 번들로 되돌아간다(바이너리 코드 확인) →
#    켜진 뒤 첫 코치 호출 한 번만 디버그 기록을 남겨 실제로 읽은 목록을 /status 의 security.caProbe 로 보여 준다.
#    서버 환경파일에 이미 값이 있으면 그 값을 따른다. NODE_USE_SYSTEM_CA=1 은 플래그가 있어야 우분투 목록을 읽는 실행 엔진 판을 위한 보험이다.
# 2) 2.1.304 보다 낮으면 'claude update' 를 백그라운드로 한 번 돌린다. 업데이트 다운로드도 인증서로 보호되므로
#    우분투 목록에서 G3 가 빠진 것을 확인한 뒤에만 시작한다(아니면 '대기' — /status 를 볼 때 다시 확인).
#    (네이티브 설치판의 다운로드가 코치 호출과 같은 인증서 목록을 쓰는 것은 바이너리 코드로만 확인했다. npm 설치판은 npm 이 받는다)
#    결과는 서명된 /status 의 security.claudeUpdate 에 나온다.
$script:claudeCertStore = if ($env:CLAUDE_CODE_CERT_STORE) { $env:CLAUDE_CODE_CERT_STORE } else { 'system' }
$script:claudeUseSystemCa = if ($env:NODE_USE_SYSTEM_CA) { $env:NODE_USE_SYSTEM_CA } else { '1' }
$script:minSafeClaude = [version]'2.1.304'
$script:claudeUpdateTimeoutSec = 300
$script:caBundleFile = '/etc/ssl/certs/ca-certificates.crt'
$script:dpkgStatusFile = '/var/lib/dpkg/status'
$script:claudeUpdate = [ordered]@{ state = '안 함'; reason = ''; startedAt = $null; finishedAt = $null; exitCode = $null; output = ''; versionAfter = $null }
$script:claudeUpdateJob = $null
$script:caProbePending = $true
# 점검 기록은 다른 계정이 못 읽는 전용 폴더에 둔다(권한 700). 지난번 실행이 거두기 전에 끝났으면 남은 파일을 지운다
$script:caProbeDir = Join-Path $PSScriptRoot 'claude-probe'
$script:caProbeFile = Join-Path $script:caProbeDir ('ca-probe-' + [guid]::NewGuid().ToString('N') + '.log')
try {
    if (-not (Test-Path -LiteralPath $script:caProbeDir)) { [void](New-Item -ItemType Directory -Path $script:caProbeDir) }
    if (-not $IsWindows) { [System.IO.File]::SetUnixFileMode($script:caProbeDir, [System.IO.UnixFileMode]'UserRead, UserWrite, UserExecute') }
    Get-ChildItem -LiteralPath $script:caProbeDir -Filter 'ca-probe-*.log' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
} catch { $script:caProbePending = $false }
$script:caProbeJob = $null
$script:caProbe = $null

# /status 로 내보내는 글: 색·커서 제어열과 제어·방향 문자를 지우고, 홈 폴더 이름을 가린다(평문 http 로 오감)
function Clear-OutText([string]$t) {
    $t = $t -replace '\x1b(\[[0-?]*[ -/]*[@-~]|\][^\x07\x1b]*(\x07|\x1b\\)|[()][0-9A-Za-z])', ''
    $t = $t -replace '[\x00-\x08\x0b-\x1f\x7f-\x9f\u200e\u200f\u202a-\u202e\u2066-\u2069]', ' '
    $t = $t -replace '/home/[^/\s''"]+', '/home/~' -replace '/root(?=/|\s|$)', '/~root'
    return ($t -replace '\s+', ' ').Trim()
}
function Get-VersionNumber([string]$s) {
    if ($s -notmatch '^\s*v?(\d+)\.(\d+)\.(\d+)') { return $null }
    $v = $null
    if ([version]::TryParse(('{0}.{1}.{2}' -f $Matches[1], $Matches[2], $Matches[3]), [ref]$v)) { return $v }
    return $null
}
# 시스템 인증서 묶음 파일의 emSign 루트 (우분투는 /etc/ssl/certs 폴더도 같은 내용으로 맞춘다)
function Get-CaBundleInfo {
    try {
        $col = [System.Security.Cryptography.X509Certificates.X509Certificate2Collection]::new()
        $col.ImportFromPemFile($script:caBundleFile)
        $em = @($col | Where-Object { $_.Subject -match 'emSign' } | ForEach-Object { $_.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) })
        $g3 = $(if ($col.Count -gt 0) { [bool]($em -contains 'emSign ECC Root CA - G3') } else { $null })   # 0개면 판정 불가
        return [ordered]@{ certs = $col.Count; emSign = $em; emSignEccG3 = $g3 }
    } catch { return [ordered]@{ certs = $null; error = (Clear-OutText $_.Exception.Message); emSignEccG3 = $null } }
}
# 설치된 패키지 전체(이름 → 판). 아키텍처가 여럿이면 함께 적는다
function Get-DpkgInstalled {
    $all = [ordered]@{}
    if (-not (Test-Path -LiteralPath $script:dpkgStatusFile)) { return $all }
    foreach ($stanza in ([System.IO.File]::ReadAllText($script:dpkgStatusFile) -split "\n\s*\n")) {
        if ($stanza -notmatch '(?m)^Package: (\S+)\s*$') { continue }
        $pkg = $Matches[1]
        if ($stanza -notmatch '(?m)^Status: \S+ ok installed\s*$') { continue }
        if ($stanza -notmatch '(?m)^Version: (\S+)\s*$') { continue }
        $v = $Matches[1]
        if ($stanza -match '(?m)^Architecture: (\S+)\s*$' -and $Matches[1] -ne 'all') { $v = "$v ($($Matches[1]))" }
        $all[$pkg] = $(if ($all.Contains($pkg)) { $all[$pkg] + ', ' + $v } else { $v })
    }
    return $all
}
function Get-DpkgVersions([string[]]$names, $all = $null) {
    if ($null -eq $all) { $all = Get-DpkgInstalled }
    $out = [ordered]@{}
    foreach ($n in $names) { $out[$n] = $(if ($all.Contains($n)) { $all[$n] } else { $null }) }
    return $out
}
# 열려 있는 TCP 포트 (/proc/net/tcp·tcp6 의 LISTEN). 모든 주소에 열린 것(바깥에서 닿을 수 있음)과 이 서버 안에서만 열린 것을 나눈다
function Get-ListeningPorts {
    $pub = New-Object System.Collections.Generic.SortedSet[int]
    $loc = New-Object System.Collections.Generic.SortedSet[int]
    foreach ($f in @('/proc/net/tcp', '/proc/net/tcp6')) {
        if (-not (Test-Path -LiteralPath $f)) { continue }
        foreach ($line in ([System.IO.File]::ReadAllLines($f) | Select-Object -Skip 1)) {
            $c = $line.Trim() -split '\s+'
            if ($c.Count -lt 4 -or $c[3] -ne '0A') { continue }
            $ipHex, $portHex = $c[1] -split ':'
            $port = [Convert]::ToInt32($portHex, 16)
            # 127.x.x.x(리틀 엔디언이라 끝 두 자리가 7F) 와 ::1 은 서버 안에서만 닿는다
            $isLocal = ($ipHex.Length -eq 8 -and $ipHex.EndsWith('7F')) -or ($ipHex -eq '00000000000000000000000001000000')
            if ($isLocal) { [void]$loc.Add($port) } else { [void]$pub.Add($port) }
        }
    }
    return [ordered]@{ public = @($pub); localOnly = @($loc) }
}
function Get-ClaudeInstallKind {
    try {
        $lt = [System.IO.File]::ResolveLinkTarget($claudeExe, $true)
        $p = $(if ($lt) { $lt.FullName } else { $claudeExe })
        $kind = $(if ($p -match '/\.local/share/claude/versions/') { 'native' } elseif ($p -match 'node_modules') { 'npm' } else { 'other' })
        return "$kind ($([System.IO.Path]::GetFileName($p)))"
    } catch { return '?' }
}
function Start-ClaudeUpdateIfNeeded {
    if ($script:claudeUpdateJob) { return }
    if ($script:claudeUpdate.state -notin @('안 함', '대기', '건너뜀(다른 업데이트 진행 중)')) { return }
    $cv = Get-VersionNumber $script:cliVersion
    if (-not $cv) { $script:claudeUpdate.reason = '버전 확인 실패'; return }
    if ($cv -ge $script:minSafeClaude) { $script:claudeUpdate.reason = "$cv 은 $($script:minSafeClaude) 이상"; return }
    $ca = Get-CaBundleInfo
    if ($ca.emSignEccG3 -ne $false) {
        $script:claudeUpdate.state = '대기'
        $script:claudeUpdate.reason = "$cv 이 $($script:minSafeClaude) 보다 낮지만, 우분투 인증서 목록에 아직 G3 가 있거나 확인 불가 — ca-certificates 갱신 뒤 진행"
        return
    }
    $startedDt = Get-Date
    try {
    $job = Start-Job -ScriptBlock {
        param($exe, $store, $useSys, $timeoutSec)
        # 시간 제한이 있는 실행. 끝나지 않으면 프로세스 묶음째 끊는다
        function Invoke-Timed([string]$file, [string[]]$argv, [int]$ms) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $file
            foreach ($a in $argv) { $psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.EnvironmentVariables['CLAUDE_CODE_CERT_STORE'] = $store
            $psi.EnvironmentVariables['NODE_USE_SYSTEM_CA'] = $useSys
            $p = [System.Diagnostics.Process]::Start($psi)
            $p.StandardInput.Close()
            $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
            $to = -not $p.WaitForExit($ms)
            if ($to) { try { $p.Kill($true) } catch {}; [void]$p.WaitForExit(5000) }
            # 손자 프로세스가 출력 관을 쥐고 있으면 끝까지 못 읽는다 → 그때는 그 출력은 비운다(최대 5초씩만 기다림)
            [pscustomobject]@{ timedOut = $to; exitCode = $(if ($to) { -1 } else { $p.ExitCode })
                out = $(if ($o.Wait(5000)) { $o.Result } else { '' }); err = $(if ($e.Wait(5000)) { $e.Result } else { '' }) }
        }
        $u = Invoke-Timed $exe @('update') ($timeoutSec * 1000)
        $v = Invoke-Timed $exe @('--version') 30000
        $h = Invoke-Timed $exe @('--help') 30000
        [pscustomobject]@{
            exitCode = $u.exitCode; timedOut = $u.timedOut; output = ($u.out + ' ' + $u.err)
            versionAfter = $(if (-not $v.timedOut) { $v.out.Trim() } else { '' })   # 버전·도움말은 표준 출력만 (경고가 섞이지 않게)
            helpAfter = $(if (-not $h.timedOut) { $h.out } else { '' })
            finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        }
    } -ArgumentList $claudeExe, $script:claudeCertStore, $script:claudeUseSystemCa, $script:claudeUpdateTimeoutSec
    } catch {
        $script:claudeUpdate.state = '실패(작업 시작 실패)'
        Add-ServerError ('claude 업데이트 작업 시작 실패: ' + $_.Exception.Message)
        return
    }
    $script:claudeUpdateJob = $job
    $script:claudeUpdateStartedDt = $startedDt
    $script:claudeUpdate.state = '진행 중'
    $script:claudeUpdate.reason = "$cv 이 $($script:minSafeClaude) 보다 낮음"
    $script:claudeUpdate.startedAt = $startedDt.ToString('yyyy-MM-dd HH:mm:ss zzz')
}
try { Start-ClaudeUpdateIfNeeded } catch { Add-ServerError ('claude 업데이트 확인: ' + $_.Exception.Message) }
Write-Host ("  코치 호출 인증서 목록: {0} / claude 업데이트: {1} ({2})" -f $script:claudeCertStore, $script:claudeUpdate.state, $script:claudeUpdate.reason)

# 업데이트 작업이 끝났으면 결과를 거둬 상태에 반영한다 (요청이 올 때마다 확인 — 끝나기 전에는 아무것도 안 함)
function Update-ClaudeUpdateState {
    $j = $script:claudeUpdateJob
    if (-not $j) { return }
    if ($j.State -eq 'Running') {
        # 작업 자체가 응답하지 않을 때의 마지막 안전장치 (안쪽 제한 + 여유)
        if (((Get-Date) - $script:claudeUpdateStartedDt).TotalSeconds -le $script:claudeUpdateTimeoutSec + 120) { return }
        Stop-Job $j -ErrorAction SilentlyContinue
    }
    $script:claudeUpdateJob = $null
    $r = $null
    try { $r = Receive-Job $j -ErrorAction SilentlyContinue | Select-Object -Last 1 } catch {}
    Remove-Job $j -Force -ErrorAction SilentlyContinue
    if (-not $r) {
        $script:claudeUpdate.finishedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz')
        $script:claudeUpdate.state = '실패(작업 응답 없음)'
        Add-ServerError 'claude 업데이트 실패(작업 응답 없음)'
        return
    }
    # 색·커서 제어열과 제어 문자를 지우고 끝부분 400자만 남긴다 (오류 문장은 보통 끝에 있다)
    $o = Clear-OutText ([string]$r.output)
    if ($o.Length -gt 400) { $o = '…' + $o.Substring($o.Length - 400) }
    $script:claudeUpdate.output = $o
    $script:claudeUpdate.finishedAt = [string]$r.finishedAt
    $script:claudeUpdate.exitCode = $r.exitCode
    $script:claudeUpdate.versionAfter = [string]$r.versionAfter
    $after = Get-VersionNumber ([string]$r.versionAfter)
    if ($after) { $script:cliVersion = [string]$r.versionAfter }
    else { Add-ServerError 'claude 업데이트 뒤 버전 확인 실패 — 실행 파일 상태를 직접 확인 필요' }
    if ($r.helpAfter) {
        $script:cliHelp = [string]$r.helpAfter
        $script:canSystemPromptFile = [bool]($script:cliHelp -match '--system-prompt-file')
        $script:canTools = [bool]($script:cliHelp -match '--tools')
    }
    if ($after -and $after -ge $script:minSafeClaude) { $script:claudeUpdate.state = '완료' }
    elseif ($r.timedOut) { $script:claudeUpdate.state = "실패(시간 초과 $($script:claudeUpdateTimeoutSec)초)" }
    elseif ($o -match 'Another Claude process|currently installing') { $script:claudeUpdate.state = '건너뜀(다른 업데이트 진행 중)' }   # /status 볼 때 다시 시도
    else { $script:claudeUpdate.state = "실패(종료 코드 $($r.exitCode))" }
    if ($script:claudeUpdate.state -ne '완료') { Add-ServerError ('claude 업데이트 ' + $script:claudeUpdate.state + ' (자세한 내용: /status security.claudeUpdate)') }
    Write-Host ("  claude 업데이트 {0}: {1}" -f $script:claudeUpdate.state, $script:cliVersion)
}

# 첫 코치 호출의 디버그 기록에서 인증서 목록 줄만 뽑고 기록 파일은 지운다 (질문 내용 등 다른 줄은 남기지 않음)
function Update-CaProbe {
    $j = $script:caProbeJob
    if (-not $j -or $j.State -eq 'Running') { return }
    $script:caProbeJob = $null
    $lines = @()
    try {
        if (Test-Path -LiteralPath $script:caProbeFile) {
            $lines = @([System.IO.File]::ReadAllLines($script:caProbeFile) | Where-Object { $_ -match 'CA certs:' -and $_ -notmatch 'Config fallback' } |
                ForEach-Object { $s = Clear-OutText ($_ -replace '^.*?CA certs:', 'CA certs:'); if ($s.Length -gt 160) { $s.Substring(0, 160) } else { $s } } | Select-Object -First 12)
        }
    } catch {}
    try { Remove-Item -LiteralPath $script:caProbeFile -Force -ErrorAction SilentlyContinue } catch {}
    $script:caProbe = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'); lines = $lines }
}

# 서버 보안 점검 (서명된 /status 의 security). 서버 셸에 들어가지 않고 확인하려고 만든 읽기 전용 정보다.
# 파일만 읽고 다른 프로그램을 기다리지 않는다(루프가 멈추지 않게 — 업데이트 대기 중이면 작업만 백그라운드로 띄움).
# 응답은 평문 http 로 오가므로 사용자 이름·홈 폴더 이름은 넣지 않는다.
function Get-SecurityInfo {
    $info = [ordered]@{}
    # 기다리던 중이면 다시 확인한다: 그사이 우분투 목록이 갱신됐으면 업데이트 작업을 백그라운드로 시작한다
    if ($script:claudeUpdate.state -in @('대기', '건너뜀(다른 업데이트 진행 중)')) {
        try { Start-ClaudeUpdateIfNeeded } catch { Add-ServerError ('claude 업데이트 확인: ' + $_.Exception.Message) }
    }
    try { $info.runAsRoot = ([Environment]::UserName -eq 'root') } catch { $info.runAsRoot = $null }
    $info.claudeInstall = Get-ClaudeInstallKind
    $info.claudeHasOwnBlocklist = [bool]((Get-VersionNumber $script:cliVersion) -ge [version]'2.1.303')
    $info.claudeCertStore = $script:claudeCertStore
    $info.claudeUpdate = $script:claudeUpdate
    $info.caProbe = $(if ($script:caProbe) { $script:caProbe } elseif ($script:caProbeJob) { '첫 코치 호출 진행 중' }
        elseif ($script:cliHelp -notmatch '--debug-file') { '이 claude 판은 --debug-file 미지원' } else { '아직 코치 호출 없음' })
    $info.caBundle = Get-CaBundleInfo
    $dp = $null
    try { $dp = Get-DpkgInstalled } catch {}
    try { $info.packages = Get-DpkgVersions @('ca-certificates', 'libnss3', 'unattended-upgrades') $dp } catch { $info.packages = '읽기 실패' }
    # PHP·웹 서버 (2026-10 PHP2Shell 같은 웹 런타임 경보가 이 서버에 해당하는지 셸 없이 보려고)
    try {
        $web = [ordered]@{}
        if ($dp) { foreach ($k in $dp.Keys) { if ($k -match '^(php[0-9.]*(-\S+)?|libapache2-mod-php\S*|apache2|nginx\S*|lighttpd|caddy)$') { $web[$k] = $dp[$k] } } }
        $info.webPackages = $(if ($dp) { $web } else { '읽기 실패' })
        $info.phpOnPath = [bool](Get-Command php -ErrorAction SilentlyContinue)
        $procs = New-Object System.Collections.Generic.SortedSet[string]
        foreach ($d in [System.IO.Directory]::GetDirectories('/proc')) {
            if ((Split-Path -Leaf $d) -notmatch '^\d+$') { continue }
            try { $n = ([System.IO.File]::ReadAllText("$d/comm")).Trim(); if ($n -match '^(php|apache2|httpd|nginx|lighttpd|caddy)') { [void]$procs.Add($n) } } catch {}
        }
        $info.webProcesses = @($procs)
    } catch { $info.webPackages = '읽기 실패' }
    try { $info.listeningTcp = Get-ListeningPorts } catch { $info.listeningTcp = '읽기 실패' }
    try {
        $au = '/etc/apt/apt.conf.d/20auto-upgrades'
        if (Test-Path -LiteralPath $au) {
            $al = @([System.IO.File]::ReadAllLines($au) | Where-Object { $_ -match '^\s*APT::Periodic' } | ForEach-Object { $_.Trim() })
            $info.autoUpgrades = $(if ($al.Count) { ,$al } else { '(APT::Periodic 설정 없음)' })
        } else { $info.autoUpgrades = '(파일 없음)' }
    } catch { $info.autoUpgrades = '읽기 실패' }
    try { $info.java = [bool](Get-Command java -ErrorAction SilentlyContinue); $info.javaCacerts = (Test-Path -LiteralPath '/etc/ssl/certs/java/cacerts') } catch { $info.java = $null }
    try { $info.ociAgentSnap = (Test-Path -LiteralPath '/snap/oracle-cloud-agent') } catch { $info.ociAgentSnap = $null }
    return $info
}

# 코치 역할문(PRIME_TEXT)은 게임 화면이 /chat 마다 함께 보내고, 서버가 파일로 두어
# claude 의 시스템 프롬프트(--system-prompt-file)로 매 호출에 고정한다.
# 이전에는 첫 호출 메시지 앞에만 붙여서, 서버가 세션을 새로 열면(20회마다·노트 저장 뒤)
# 역할·말투 규칙 없이 코칭이 나가는 문제가 있었다. 원문은 holdem.html 의 PRIME_TEXT 하나다.
$primeFile = Join-Path $PSScriptRoot 'coach-prime.txt'
$script:primeText = ''
if (Test-Path $primeFile) {
    try { $script:primeText = [System.IO.File]::ReadAllText($primeFile, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
function Set-PrimeText([string]$text) {
    if (-not $text) { return }
    if ($text -eq $script:primeText) { return }
    [System.IO.File]::WriteAllText($primeFile, $text, (New-Object System.Text.UTF8Encoding($false)))
    $script:primeText = $text
}

# 플레이어 프로필 파일: 코치가 관찰한 나의 성향/실수/개선점을 축적
$profileFile = Join-Path $PSScriptRoot 'player-profile.md'

# 코치 대화를 서버 재시작 후에도 이어가기 위해 세션 ID를 파일로 보존
# (처음부터 다시 시작하고 싶으면 coach-session.txt 를 삭제하세요)
$sessionFile = Join-Path $PSScriptRoot 'coach-session.txt'
if (Test-Path $sessionFile) {
    $saved = (Get-Content $sessionFile -Raw -ErrorAction SilentlyContinue)
    if ($saved) { $script:sessionId = $saved.Trim() }
    if ($script:sessionId) {
        # 재시작 전 얼마나 쌓였는지 알 수 없으므로 절반쯤 찬 것으로 보고 시작
        $script:turnCount = [int]($script:sessionMaxTurns / 2)
        Write-Host "  이전 코치 대화를 이어서 진행합니다." -ForegroundColor Cyan
    }
}

# ===== 비동기 Claude 호출 =====
# Claude 호출은 백그라운드 잡으로 돌리고, 서버는 티켓을 즉시 반환.
# 게임이 /result?id= 로 폴링해서 결과를 받아간다.
# (이전 동기 방식은 Claude가 오래 걸리면 서버 전체가 멈추는 문제가 있었음)
$script:jobs = @{}   # 티켓ID → @{ job; kind; msg; started; retried }

function Add-ProfilePrefix([string]$message) {
    # 새 대화 시작 시 축적된 플레이어 프로필을 자동 주입
    if (Test-Path $profileFile) {
        $prof = [System.IO.File]::ReadAllText($profileFile, (New-Object System.Text.UTF8Encoding($false)))
        if ($prof.Trim()) {
            return "참고 - 지금까지 축적된 플레이어(나)의 프로필이야. 코칭에 반영해줘:`n" + $prof + "`n---`n" + $message
        }
    }
    return $message
}

function Add-SessionPrefix([string]$message, [string]$kind) {
    # 새 대화의 첫 메시지: 코칭 노트를 앞에 붙이고,
    # 설치된 claude 가 --system-prompt-file 을 모르는 경우에만 역할문도 메시지 앞에 붙인다 (구형 CLI 대비).
    $send = Add-ProfilePrefix $message
    if ($kind -ne 'profile' -and -not $script:canSystemPromptFile -and $script:primeText) {
        $send = $script:primeText + "`n`n" + $send
    }
    return $send
}

function Start-ClaudeJob([string]$message, [string]$resumeId, [string]$model, [bool]$fast, [bool]$useSystemPrompt = $true) {
    if (-not $model) { $model = $coachModel }
    $certStore = $script:claudeCertStore
    $useSysCa = $script:claudeUseSystemCa
    $probeFile = $null
    if ($script:caProbePending -and $script:cliHelp -match '--debug-file') { $script:caProbePending = $false; $probeFile = $script:caProbeFile }
    # 코칭 노트 작성(kind=profile)은 긴 마크다운을 내야 하므로 '250자 이내' 같은 코치 말투 규칙을 걸지 않는다.
    $sysFile = $null
    if ($useSystemPrompt -and $script:canSystemPromptFile -and $script:primeText) { $sysFile = $primeFile }
    $noTools = $script:canTools
    $job = Start-Job -ScriptBlock {
        param($msg, $resume, $mdl, $exe, $fastMode, $sysFile, $noTools, $certStore, $useSysCa, $probeFile)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        # 인자는 한 줄 문자열이 아니라 목록으로 넘긴다. 빈 문자열("")이나 공백이 든 경로도 그대로 전달된다.
        $psi.ArgumentList.Add('-p')
        $psi.ArgumentList.Add('--output-format'); $psi.ArgumentList.Add('json')
        $psi.ArgumentList.Add('--model'); $psi.ArgumentList.Add($mdl)
        if ($resume) { $psi.ArgumentList.Add('--resume'); $psi.ArgumentList.Add($resume) }
        # 코치는 파일·명령 도구가 필요 없다. 도구를 끄면 무인증 /chat 으로 들어온 글이
        # 서버 파일을 읽히는 통로가 닫히고, 호출마다 도구 설명 토큰도 빠진다.
        if ($noTools) { $psi.ArgumentList.Add('--tools'); $psi.ArgumentList.Add('') }
        if ($sysFile) { $psi.ArgumentList.Add('--system-prompt-file'); $psi.ArgumentList.Add($sysFile) }
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
        $psi.CreateNoWindow = $true
        # 선행 분석은 각 선택지별 한 줄 평가를 채우는 기계적인 작업이라
        # 답 전에 길게 생각할 이유가 없다 → 생각 예산만 줄인다 (모델은 그대로).
        # 최종 평가·핸드 리뷰·코칭 노트에는 적용하지 않는다.
        if ($fastMode) { $psi.EnvironmentVariables['MAX_THINKING_TOKENS'] = '0' }
        # 우분투 인증서 목록만 믿게 한다 (위 '인증 기관 키 유출 대응' 참고)
        if ($certStore) { $psi.EnvironmentVariables['CLAUDE_CODE_CERT_STORE'] = $certStore }
        if ($useSysCa) { $psi.EnvironmentVariables['NODE_USE_SYSTEM_CA'] = $useSysCa }
        if ($probeFile) { $psi.ArgumentList.Add('--debug-file'); $psi.ArgumentList.Add($probeFile) }
        $proc = [System.Diagnostics.Process]::Start($psi)
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($msg)
        $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $proc.StandardInput.BaseStream.Flush()
        $proc.StandardInput.Close()
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $t = $stdout.Trim()
        if ($t) { return $t }
        return 'ERR:' + $stderr
    } -ArgumentList $message, $resumeId, $model, $claudeExe, $fast, $sysFile, $noTools, $certStore, $useSysCa, $probeFile
    if ($probeFile) { $script:caProbeJob = $job }
    return $job
}

function New-ClaudeTicket([string]$rawMsg, [string]$kind, [string]$model, [bool]$fast) {
    # 세션을 무한정 이어가면 --resume 이 매번 전체 대화를 다시 실어 나른다 → 갈수록 느려짐.
    # 기억은 코칭 노트가 담당하므로, 일정 횟수마다 세션을 끊어 속도를 되돌린다.
    if ($script:sessionId -and $script:turnCount -ge $script:sessionMaxTurns) {
        Write-Host ("  ↻ 코치 세션 새로 시작 (누적 {0}회 — 속도 유지, 기억은 코칭 노트가 이어감)" -f $script:turnCount) -ForegroundColor DarkCyan
        $script:sessionId = $null
        $script:turnCount = 0
        Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue
    }
    $send = $rawMsg
    $wasNew = (-not $script:sessionId)
    if ($wasNew) { $send = Add-SessionPrefix $rawMsg $kind }
    $script:turnCount++
    $job = Start-ClaudeJob $send $script:sessionId $model $fast ($kind -ne 'profile')
    $id = [guid]::NewGuid().ToString('N')
    $script:jobs[$id] = @{
        job = $job; kind = $kind; msg = $rawMsg; started = (Get-Date); retried = $false; model = $model; fast = $fast
        sessState = $(if ($wasNew) { '새세션' } else { '이어감' })   # 이 값이 속도 비교의 핵심
        turn = $script:turnCount
        inLen = $send.Length
    }
    return $id
}

# ===== 성능 로그 =====
# 호출마다 "몇 초 걸렸는지 + 그때 세션이 몇 번째였는지"를 남긴다.
# 이 둘이 같이 있어야 '세션이 쌓이면 느려진다'를 숫자로 검증할 수 있다.
$logFile = Join-Path $PSScriptRoot 'coach-log.txt'
if (-not (Test-Path $logFile)) {
    $header = "시각`t종류`t모델`t세션`t세션내순번`t보낸글자`t받은글자`t걸린초`t결과`t사용량"
    [System.IO.File]::WriteAllText($logFile, $header + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
}
# 사용량 열: claude 가 돌려주는 토큰 수와 추정 비용(in=입력 cr=캐시읽기 cw=캐시쓰기 out=출력 cost=달러).
# 구독으로 쓰는 동안은 청구액이 아니라 참고값이다. 이어가는 호출은 CLI 버전에 따라 세션 누적값일 수 있다.
function Write-CoachLog([string]$kind, [string]$model, [string]$sessState, [int]$turn,
                        [int]$inLen, [int]$outLen, [double]$sec, [string]$result, [string]$usage = '') {
    try {
        $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7:N1}`t{8}`t{9}" -f `
            (Get-Date -Format 'MM-dd HH:mm:ss'), $kind, ($model -replace 'claude-',''),
            $sessState, $turn, $inLen, $outLen, $sec, $result, $usage
        [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}
function Get-UsageText($obj) {
    # --output-format json 응답에서 사용량 필드만 뽑는다. 없으면 빈 문자열.
    try {
        $u = $obj.usage
        if ($null -eq $u) { return '' }
        $cost = $obj.total_cost_usd
        return ('in={0} cr={1} cw={2} out={3} cost={4}' -f
            [int64]$u.input_tokens, [int64]$u.cache_read_input_tokens, [int64]$u.cache_creation_input_tokens,
            [int64]$u.output_tokens, $(if ($null -ne $cost) { ('{0:N4}' -f [double]$cost) } else { '?' }))
    } catch { return '' }
}

# 전체 타임라인 로그 — 게임 액션 + 코치 호출을 한 파일에 시간순으로
$gameLogFile = Join-Path $PSScriptRoot 'game-log.txt'
function Write-GameLog([string]$text) {
    try {
        $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $text
        [System.IO.File]::AppendAllText($gameLogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

# ===== 로그 읽기 서명 확인 =====
# 저장소가 공개라 서버 코드에 비밀번호를 둘 수 없다(규칙 9). 그래서 서버에는 '공개 키'만 둔다.
# 요청은 서버 밖(Claude 작업 환경의 HOLDEM_LOG_KEY)에만 있는 개인 키로 서명한다.
# 공개 키로는 확인만 되고 서명을 만들 수는 없다 → 코드를 다 봐도 로그를 읽을 수 없다.
# 서명 방식: ECDSA P-256 + SHA-256, DER 서명을 base64url로. 읽는 쪽 스크립트는 read-logs.sh
$logReaderPubKey = 'MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEDIicPqtRhjxoJp2gv6UWIgGrTBbnT+Hewep8IpNe4AZhfoHRUVYHZrACNmQWahFKRm+BqAh2emP2Q/OfPi41Iw=='
$script:usedLogT = @{}   # 최근에 받은 /logs 요청의 시각(t) — 엿본 주소를 다시 보내도 받지 않는다
function Test-LogSignature([string]$text, [string]$sigB64Url) {
    try {
        if (-not $sigB64Url) { return $false }
        $s = $sigB64Url.Replace('-', '+').Replace('_', '/')
        switch ($s.Length % 4) { 2 { $s += '==' } 3 { $s += '=' } }
        $ec = [System.Security.Cryptography.ECDsa]::Create()
        $read = 0
        $ec.ImportSubjectPublicKeyInfo([Convert]::FromBase64String($logReaderPubKey), [ref]$read)
        return $ec.VerifyData([System.Text.Encoding]::UTF8.GetBytes($text), [Convert]::FromBase64String($s),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.DSASignatureFormat]::Rfc3279DerSequence)
    } catch { return $false }
}

# 로그 파일의 끝 N줄. 끝에서부터 최대 4MB만 읽는다.
# Get-Content -Tail 은 마지막 줄 길이의 제곱에 비례해 느려져, 긴 줄 하나(인증 없는 /gamelog로 남길 수 있다)로
# 서버 전체가 멈췄다(검증 실측: 800KB 줄 13.5초, 50MB 한 줄은 5분 넘게 응답 없음).
function Read-LogTail([string]$path, [int]$lines) {
    $max = 4MB
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $start = [math]::Max([int64]0, $fs.Length - $max)
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ([int]($fs.Length - $start))
        $got = 0
        while ($got -lt $buf.Length) { $n = $fs.Read($buf, $got, $buf.Length - $got); if ($n -le 0) { break }; $got += $n }
    } finally { $fs.Dispose() }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $got)
    if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
    $arr = [System.Collections.Generic.List[string]]::new([string[]]($text -split "`r?`n"))
    if ($start -gt 0 -and $arr.Count -gt 0) { $arr.RemoveAt(0) }                    # 중간에서 잘린 첫 줄은 버린다
    if ($arr.Count -gt 0 -and $arr[$arr.Count - 1] -eq '') { $arr.RemoveAt($arr.Count - 1) }
    $from = [math]::Max(0, $arr.Count - $lines)
    return ($arr.GetRange($from, $arr.Count - $from) -join "`n")
}

# 지금 디스크에 받아 둔 커밋(배포 반영 확인용). git을 실행하면 느릴 때 루프 전체가 멈춰서(검증 실측 20초) .git 파일을 직접 읽는다
function Get-DeployCommit {
    try {
        $gitDir = Join-Path $PSScriptRoot '.git'
        $head = ([System.IO.File]::ReadAllText((Join-Path $gitDir 'HEAD'))).Trim()
        if ($head -notmatch '^ref: (.+)$') { return $head.Substring(0, [math]::Min(12, $head.Length)) }
        $ref = $Matches[1]
        $rf = Join-Path $gitDir $ref
        if (Test-Path -LiteralPath $rf) { return ([System.IO.File]::ReadAllText($rf)).Trim().Substring(0, 12) + ' ' + $ref }
        $packed = Join-Path $gitDir 'packed-refs'
        if (Test-Path -LiteralPath $packed) {
            foreach ($l in [System.IO.File]::ReadAllLines($packed)) { if ($l.EndsWith(' ' + $ref)) { return $l.Substring(0, 12) + ' ' + $ref } }
        }
        return '?'
    } catch { return '' }
}

# 서명된 요청 공통 확인: 시각(60초 전~10초 뒤), 이미 받은 시각 거절(재사용 방지), 서명
function Test-SignedRequest([string]$text, [string]$tStr, [string]$sig) {
    $tms = [int64]0
    if (-not [int64]::TryParse($tStr, [ref]$tms)) { return $false }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if (($now - $tms) -gt 60000 -or ($tms - $now) -gt 10000) { return $false }
    if ($script:usedLogT.ContainsKey($tms)) { return $false }
    if (-not (Test-LogSignature $text $sig)) { return $false }
    $script:usedLogT[$tms] = $now
    foreach ($k in @($script:usedLogT.Keys)) { if ($now - $script:usedLogT[$k] -gt 120000) { $script:usedLogT.Remove($k) } }
    return $true
}

# 요청 본문 읽기 — 2MB까지, 3초 동안 아무것도 안 오면 끊고, 계속 오더라도 전체 8초에서 끊는다.
# 요청을 한 번에 하나씩 처리하는 구조라, 본문을 덜 보내고 붙잡는 연결 하나가 서버 전체(게임 화면 포함)를
# 무기한 멈췄다(검증 실측: 그동안 /ping·GET / 모두 응답 없음). 느리지만 계속 들어오는 폰 업로드는 8초까지 기다린다.
# 끊을 때는 상태 코드(408 시간 초과 / 413 너무 큼)를 먼저 정한다. 그냥 끊으면 클라이언트가 '200 빈 응답'을 받아
# 게임이 저장 안 된 판을 '기록됨'으로 표시했다(검증 실측).
# 남은 한계: 붙잡는 연결이 여럿이면 하나씩 차례로 기다린다(연결당 최대 8초). 없애려면 요청을 동시에 처리하는 구조가 필요하다.
function Read-Body($context, [int]$maxBytes = 2MB, [int]$idleMs = 3000, [int]$totalMs = 8000) {
    $request = $context.Request
    if (-not $request.HasEntityBody) { return ,([byte[]]@()) }
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    $deadline = [DateTime]::UtcNow.AddMilliseconds($totalMs)
    while ($true) {
        $left = [int][math]::Min($idleMs, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $task = $null
        if ($left -gt 0) { $task = $request.InputStream.ReadAsync($buf, 0, $buf.Length) }
        $done = $false
        if ($task) { try { $done = $task.Wait($left) } catch { try { $context.Response.StatusCode = 400; $context.Response.Abort() } catch {}; throw '요청 본문 읽기 실패(연결 끊김)' } }
        if (-not $done) {
            try { $context.Response.StatusCode = 408; $context.Response.Abort() } catch {}
            throw '요청 본문 읽기 시간 초과'
        }
        $n = $task.Result
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        if ($ms.Length -gt $maxBytes) {
            try { $context.Response.StatusCode = 413; $context.Response.Abort() } catch {}
            throw '요청 본문이 너무 큼'
        }
    }
    return ,($ms.ToArray())
}
function Read-BodyText($context) { return [System.Text.Encoding]::UTF8.GetString((Read-Body $context)) }

function Send-Json($response, [int]$code, [string]$json) {
    $buf = [System.Text.Encoding]::UTF8.GetBytes($json)
    $response.StatusCode = $code
    $response.ContentType = 'application/json; charset=utf-8'
    $response.ContentLength64 = $buf.Length
    $response.OutputStream.Write($buf, 0, $buf.Length)
    $response.Close()
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    # 요청 하나에서 난 예외로 서버 프로세스가 끝나지 않게 루프 본문 전체를 try로 감싼다(아래 catch, 들여쓰기는 그대로 둠).
    # 실측: 본문 없는 POST 한 번이면 응답 객체가 이미 닫혀 있어 끝의 404 설정에서 예외 → 서버 종료(게임 화면까지 멈춤).
    # 본문을 덜 보내고 붙잡는 연결처럼 '멈춤'은 예외가 아니라서 이 try로는 못 막는다 → Read-Body의 시간 제한과 아래 KeepAlive로 막는다.
    try {
    # 백그라운드 작업 결과 거두기 — 여기서 난 오류가 요청 처리를 막지 않게 따로 감싼다
    try { Update-ClaudeUpdateState; Update-CaProbe } catch { Add-ServerError ('작업 결과 거두기: ' + $_.Exception.Message) }
    $req = $ctx.Request
    $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
    # 본문이 있는 요청은 연결을 유지하지 않는다. 본문을 안 읽는 경로(404·/ping 등)에서 응답을 닫을 때 HttpListener가
    # 남은 본문을 끝까지 읽느라(시간 상한 없음) 천천히 보내는 연결 하나에 서버가 무기한 멈췄다(원래 있던 문제, 검증 실측)
    if ($req.HasEntityBody) { $res.KeepAlive = $false }

    if ($req.HttpMethod -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        continue
    }

    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/ping') {
        Send-Json $res 200 '{"ok":true}'
        continue
    }

    # ===== 로그 읽기 (서명된 요청만) =====
    # GET /logs?file=game|coach&tail=줄수(1~20000)&t=유닉스시각(ms)&sig=서명
    # 서명 대상 글: "logs|{file}|{tail}|{t}". 평문 http라 주소를 엿볼 수 있으므로, 60초가 지났거나(미래 10초까지만 허용)
    # 이미 받은 t로 온 요청은 거절한다. 서명 문자열은 같은 뜻의 다른 모양이 있을 수 있어(ECDSA) t로 막는다.
    # 루프 전체를 감싼 바깥 try도 있지만, 이 블록은 403/500을 직접 돌려주려고 따로 감싼다.
    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/logs') {
        try {
            $lf = [string]$req.QueryString['file']
            $lt = [string]$req.QueryString['tail']
            $lts = [string]$req.QueryString['t']
            $lsig = [string]$req.QueryString['sig']
            $lpath = $null
            if ($lf -eq 'game') { $lpath = $gameLogFile } elseif ($lf -eq 'coach') { $lpath = $logFile }
            $ln = 0
            $okReq = $lpath -and [int]::TryParse($lt, [ref]$ln) -and $ln -ge 1 -and $ln -le 20000 -and
                     (Test-SignedRequest ("logs|$lf|$lt|$lts") $lts $lsig)
            if (-not $okReq) {
                Send-Json $res 403 '{"ok":false,"error":"서명이 없거나 맞지 않습니다"}'
                continue
            }
            $ltext = ''
            if (Test-Path -LiteralPath $lpath) { $ltext = Read-LogTail $lpath $ln }
            $lbuf = [System.Text.Encoding]::UTF8.GetBytes($ltext)
            $res.StatusCode = 200
            $res.ContentType = 'text/plain; charset=utf-8'
            $res.ContentLength64 = $lbuf.Length
            $res.OutputStream.Write($lbuf, 0, $lbuf.Length)
            $res.Close()
        } catch {
            Add-ServerError ('/logs: ' + $_.Exception.Message)
            try { Send-Json $res 500 '{"ok":false,"error":"로그 읽기 실패"}' } catch {}
        }
        continue
    }

    # ===== 서버 상태 (서명된 요청만) =====
    # GET /status?t=&sig=   서명 대상 글: "status|{t}"
    # 서버 밖에서는 이 프로그램의 화면 출력·켜진 시간·실제로 돌고 있는 버전을 볼 수 없어서 만든 읽기 전용 창구
    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/status') {
        try {
            $sts = [string]$req.QueryString['t']
            if (-not (Test-SignedRequest ("status|$sts") $sts ([string]$req.QueryString['sig']))) {
                Send-Json $res 403 '{"ok":false,"error":"서명이 없거나 맞지 않습니다"}'
                continue
            }
            $deploy = Get-DeployCommit
            $htmlFile = Join-Path $PSScriptRoot 'holdem.html'
            $size = { param($f) if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).Length } else { $null } }
            $sha = { param($f) try { (Get-FileHash -Algorithm SHA1 -LiteralPath $f).Hash.Substring(0, 12).ToLower() } catch { '?' } }
            $running = 0
            foreach ($j in @($script:jobs.Values)) { if ($j.job.State -eq 'Running') { $running++ } }
            $st = [ordered]@{
                ok = $true
                startedAt = $script:startedAt.ToString('yyyy-MM-dd HH:mm:ss zzz')
                uptimeMin = [math]::Round(((Get-Date) - $script:startedAt).TotalMinutes, 1)
                runningScriptSha1 = $script:selfSha
                diskScriptSha1 = (& $sha $PSCommandPath)
                holdemHtmlSha1 = (& $sha $htmlFile)
                deploy = $deploy
                powershell = $PSVersionTable.PSVersion.ToString()
                dotnet = [System.Environment]::Version.ToString()
                os = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
                claude = $script:cliVersion
                coachSession = [ordered]@{ turn = $script:turnCount; max = $script:sessionMaxTurns; hasSession = [bool]$script:sessionId }
                jobs = [ordered]@{ total = $script:jobs.Count; running = $running }
                fileBytes = [ordered]@{ gameLog = (& $size $gameLogFile); coachLog = (& $size $logFile); coachingNote = (& $size $profileFile) }
                recentErrors = @($script:recentErrors.ToArray())
                security = (Get-SecurityInfo)
            }
            Send-Json $res 200 ($st | ConvertTo-Json -Depth 5 -Compress)
        } catch {
            Add-ServerError ('/status: ' + $_.Exception.Message)
            try { Send-Json $res 500 '{"ok":false,"error":"상태 조회 실패"}' } catch {}
        }
        continue
    }

    # ===== 기록 서버 읽기 (서명된 요청만, 읽기 두 종류만) =====
    # GET /dbread?kind=get&ns=&name=&t=&sig=         → 기록 서버 /get?ns=&key=       (서명 글 "dbread|get|{ns}|{name}||{t}")
    # GET /dbread?kind=log&ns=&name=&tail=&t=&sig=   → 기록 서버 /log?ns=&log=&tail= (서명 글 "dbread|log|{ns}|{name}|{tail}|{t}")
    # 쓰기(/set·/append)는 열지 않는다.
    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/dbread') {
        try {
            $dk = [string]$req.QueryString['kind']; $dns = [string]$req.QueryString['ns']; $dname = [string]$req.QueryString['name']
            $dtail = [string]$req.QueryString['tail']; $dts = [string]$req.QueryString['t']
            $dn = 0
            $okReq = ($dns -cmatch '^[A-Za-z0-9_-]{1,64}\z') -and ($dname -cmatch '^[A-Za-z0-9_-]{1,64}\z') -and
                     (($dk -ceq 'get' -and $dtail -eq '') -or
                      ($dk -ceq 'log' -and [int]::TryParse($dtail, [ref]$dn) -and $dn -ge 1 -and $dn -le 2000 -and $dtail -ceq [string]$dn)) -and
                     (Test-SignedRequest ("dbread|$dk|$dns|$dname|$dtail|$dts") $dts ([string]$req.QueryString['sig']))
            if (-not $okReq) {
                Send-Json $res 403 '{"ok":false,"error":"서명이 없거나 맞지 않습니다"}'
                continue
            }
            $target = if ($dk -ceq 'get') { "http://127.0.0.1:8770/get?ns=$dns&key=$dname" } else { "http://127.0.0.1:8770/log?ns=$dns&log=$dname&tail=$dn" }
            $hwr = [System.Net.HttpWebRequest]::Create($target)
            $hwr.Method = 'GET'; $hwr.Timeout = 10000; $hwr.ReadWriteTimeout = 10000
            $resp = $hwr.GetResponse()
            try {
                $rs = $resp.GetResponseStream()
                $ms2 = New-Object System.IO.MemoryStream
                $b2 = New-Object byte[] 65536
                while (($n2 = $rs.Read($b2, 0, $b2.Length)) -gt 0) {
                    $ms2.Write($b2, 0, $n2)
                    if ($ms2.Length -gt 8MB) { throw '기록 서버 응답이 너무 큼' }
                }
                $out = $ms2.ToArray()
                $res.StatusCode = [int]$resp.StatusCode
                if ($resp.ContentType) { $res.ContentType = $resp.ContentType }
                $res.ContentLength64 = $out.Length
                $res.OutputStream.Write($out, 0, $out.Length)
                $res.Close()
            } finally { $resp.Close() }
        } catch {
            Add-ServerError ('/dbread: ' + $_.Exception.Message)
            try { Send-Json $res 502 '{"ok":false,"error":"기록 서버 읽기 실패"}' } catch {}
        }
        continue
    }

    # ===== 기록 서버 중계 (/db/* → 127.0.0.1:8770) =====
    # 기록 서버는 인증이 없어 인터넷에 직접 열지 않는다.
    # 원격 게임은 이 경로로만 기록에 접근한다 (holdem.html 2635행대 DB_URL 참고).
    if ($req.Url.AbsolutePath.StartsWith('/db/')) {
        try {
            $target = 'http://127.0.0.1:8770' + $req.Url.AbsolutePath.Substring(3) + $req.Url.Query
            $hwr = [System.Net.HttpWebRequest]::Create($target)
            $hwr.Method = $req.HttpMethod
            $hwr.Timeout = 10000
            if ($req.HasEntityBody) {
                if ($req.ContentType) { $hwr.ContentType = $req.ContentType }
                $bodyBytes = Read-Body $ctx
                $reqStream = $hwr.GetRequestStream()
                $reqStream.Write($bodyBytes, 0, $bodyBytes.Length)
                $reqStream.Close()
            }
            $resp = $hwr.GetResponse()
            $ms = New-Object System.IO.MemoryStream
            $resp.GetResponseStream().CopyTo($ms)
            $bytes = $ms.ToArray()
            $res.StatusCode = [int]$resp.StatusCode
            if ($resp.ContentType) { $res.ContentType = $resp.ContentType }
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.Close()
            $resp.Close()
        } catch {
            Add-ServerError ('/db 중계: ' + $_.Exception.Message)
            try { Send-Json $res 502 '{"ok":false,"error":"기록 서버 중계 실패"}' } catch {}
        }
        continue
    }

    # 게임에서 보내는 이벤트를 타임라인 로그에 기록
    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/gamelog') {
        try { $graw = Read-BodyText $ctx } catch { Add-ServerError ('/gamelog: ' + $_.Exception.Message); try { $res.Abort() } catch {}; continue }
        try {
            $b = $graw | ConvertFrom-Json
            # 게임이 보낸 '발생 시각'이 있으면 그걸 쓴다 (전송 지연에 순서가 흔들리지 않게)
            if ($b.text) {
                # 인증 없는 주소라 한 줄 길이에 상한을 둔다 (정상 기록은 코치 답변을 포함해도 수천 자)
                $gtext = [string]$b.text
                if ($gtext.Length -gt 20000) { $gtext = $gtext.Substring(0, 20000) + ' …(잘림)' }
                if ($b.t) {
                    $gt = [string]$b.t
                    if ($gt.Length -gt 40) { $gt = $gt.Substring(0, 40) }
                    [System.IO.File]::AppendAllText($gameLogFile,
                        ($gt + '  ' + $gtext + "`r`n"),
                        (New-Object System.Text.UTF8Encoding($false)))
                } else {
                    Write-GameLog $gtext
                }
            }
        } catch {}
        Send-Json $res 200 '{"ok":true}'
        continue
    }

    # 행동 음성 안내 (Windows TTS로 즉시 발화)
    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/say') {
        try { $sraw = Read-BodyText $ctx } catch { Add-ServerError ('/say: ' + $_.Exception.Message); try { $res.Abort() } catch {}; continue }
        try {
            $b = $sraw | ConvertFrom-Json
            if ($b.text -and $script:tts) {
                # 음량 슬라이더 값(0~100) 반영. 없으면 100
                if ($null -ne $b.vol) { try { $script:tts.Volume = [Math]::Max(0, [Math]::Min(100, [int]$b.vol)) } catch {} }
                $script:tts.SpeakAsync([string]$b.text) | Out-Null
            }
        } catch {}
        Send-Json $res 200 '{"ok":true}'
        continue
    }

    # 플레이어 프로필 조회
    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/profile') {
        $prof = ''
        if (Test-Path $profileFile) {
            $prof = [System.IO.File]::ReadAllText($profileFile, (New-Object System.Text.UTF8Encoding($false)))
        }
        Send-Json $res 200 (@{ profile = $prof } | ConvertTo-Json -Depth 3)
        continue
    }

    # 플레이어 프로필 갱신: 지금까지의 대화를 바탕으로 코치가 프로필을 다시 작성
    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/profile-update') {
        # 게임은 늘 핸드 기록을 본문에 담아 보낸다. 본문이 없으면 코치(claude) 호출을 띄우지 않는다
        # (예전엔 본문 없는 요청에도 코칭 노트 작성 호출이 실제로 나갔다 — 검증 실측)
        if (-not $req.HasEntityBody) { try { Send-Json $res 400 '{"ok":false,"reply":"본문이 없습니다"}' } catch {}; continue }
        try {
            $raw2 = Read-BodyText $ctx
            # 길이 표시 없이 빈 본문(chunked 0바이트)이 와도 호출하지 않는다 (검증 실측: 이 경우 호출이 나갔다)
            if (-not $raw2.Trim()) { Send-Json $res 400 '{"ok":false,"reply":"본문이 없습니다"}'; continue }
            $existing = '(아직 없음)'
            if (Test-Path $profileFile) {
                $e = [System.IO.File]::ReadAllText($profileFile, (New-Object System.Text.UTF8Encoding($false)))
                if ($e.Trim()) { $existing = $e }
            }
            # 게임이 보낸 실제 핸드 기록 (없으면 대화 기억에만 의존 → 근거 없는 노트가 됨)
            $handsText = ''
            try {
                if ($raw2) { $handsText = [string](($raw2 | ConvertFrom-Json).hands) }
            } catch {}

            $today = Get-Date -Format 'yyyy-MM-dd'
            $evidence = if ($handsText) {
                "아래는 실제로 기록된 최근 핸드들이야. 노트의 모든 항목은 반드시 이 기록에서 근거를 찾아 써.`n" +
                "===== 핸드 기록 시작 =====`n$handsText`n===== 핸드 기록 끝 =====`n`n" +
                "규칙: 기록에서 확인되지 않는 습관은 절대 지어내지 마. 근거가 부족한 항목은 '아직 판단하기 이름'이라고 써.`n" +
                "각 지적에는 '핸드 #N에서 ~했음'처럼 근거 핸드 번호를 함께 적어.`n`n"
            } else {
                "주의: 이번엔 핸드 기록이 첨부되지 않았어. 대화에서 확실히 관찰된 것만 쓰고, 근거 없는 추측은 절대 쓰지 마.`n`n"
            }

            $pmsg = "플레이어(나)의 포커 코칭 노트를 갱신해줘.`n`n" + $evidence +
                    "기존 노트:`n$existing`n`n" +
                    "요구사항: 기존 내용에 새로운 관찰을 반영해서 갱신하고, 새 근거가 없는 항목은 그대로 유지해. 오늘 날짜는 $today.`n" +
                    "아래 마크다운 형식의 프로필 본문만 출력하고, 그 외의 문장은 절대 붙이지 마:`n" +
                    "# 플레이어 프로필 (갱신: 날짜)`n## 성향`n## 반복되는 실수`n## 잘하는 점`n## 개선 과제`n## 현재 이해 수준 (설명 난이도 조절용 - 어떤 개념을 이해했고 어떤 건 아직 낯설어하는지)`n## 다음 코칭 포인트"
            # 코칭 노트는 품질이 중요하므로 항상 기본 모델(Sonnet)로 작성
            $id = New-ClaudeTicket $pmsg 'profile' $coachModel
            Write-Host ("[{0}] 코칭 노트 갱신 요청 → Claude 백그라운드 호출 시작" -f (Get-Date -Format 'HH:mm:ss'))
            Send-Json $res 200 (@{ ticket = $id } | ConvertTo-Json -Compress)
        } catch {
            Write-Host "프로필 갱신 오류: $_" -ForegroundColor Red
            Add-ServerError ('/profile-update: ' + $_.Exception.Message)
            try { Send-Json $res 500 (@{ ok = $false; reply = "프로필 갱신 실패: $_" } | ConvertTo-Json -Depth 3) } catch {}
        }
        continue
    }

    # 게임 페이지 서빙 (서버주소:8765/ 로 접속하면 게임이 열림. 폰도 같은 주소를 쓴다)
    # /old = 예전 UI 백업본 (문제 생기면 여기로 대피)
    if ($req.HttpMethod -eq 'GET' -and ($req.Url.AbsolutePath -eq '/old' -or $req.Url.AbsolutePath -eq '/holdem-old.html')) {
        try {
            $htmlPathOld = Join-Path $PSScriptRoot 'holdem-old.html'
            $buf = [System.IO.File]::ReadAllBytes($htmlPathOld)
            $res.StatusCode = 200
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
            $res.Close()
        } catch {
            $res.StatusCode = 500
            $res.Close()
        }
        continue
    }

    if ($req.HttpMethod -eq 'GET' -and ($req.Url.AbsolutePath -eq '/' -or $req.Url.AbsolutePath -eq '/holdem.html')) {
        try {
            $htmlPath = Join-Path $PSScriptRoot 'holdem.html'
            $buf = [System.IO.File]::ReadAllBytes($htmlPath)
            $res.StatusCode = 200
            $res.ContentType = 'text/html; charset=utf-8'
            $res.ContentLength64 = $buf.Length
            $res.OutputStream.Write($buf, 0, $buf.Length)
            $res.Close()
        } catch {
            $res.StatusCode = 500
            $res.Close()
        }
        continue
    }

    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/chat') {
        # 본문이 없거나 질문이 비면 코치(claude) 호출을 띄우지 않는다 (예전엔 본문 없는 요청에도 호출이 나갔다)
        if (-not $req.HasEntityBody) { try { Send-Json $res 400 '{"reply":"질문이 없습니다"}' } catch {}; continue }
        try {
            $body = (Read-BodyText $ctx) | ConvertFrom-Json
            $q = [string]$body.message
            if (-not $q.Trim()) { Send-Json $res 400 '{"reply":"질문이 없습니다"}'; continue }
            # 화면에서 선택한 코치 모델 (허용 목록만)
            $mdl = [string]$body.model
            if ($mdl -notin @('claude-haiku-4-5', 'claude-sonnet-5')) { $mdl = $coachModel }
            # fast=true : 선행 분석 전용. 모델은 사용자가 고른 것(정밀)을 그대로 쓰고,
            # 답 전에 과도하게 생각하는 것만 줄인다 (측정: 같은 형식으로 68초 → 15.9초).
            # 모델을 낮추면 카드·상황을 잘못 읽을 수 있어 정확도를 포기하지 않는다.
            $fast = [bool]$body.fast
            # 화면이 보낸 역할문(PRIME_TEXT)을 파일로 두어 시스템 프롬프트로 쓴다 (내용이 바뀔 때만 다시 씀)
            if ($body.prime) { Set-PrimeText ([string]$body.prime) }
            $id = New-ClaudeTicket $q $(if ($fast) { 'pre' } else { 'chat' }) $mdl $fast
            Write-Host ("[{0}] 질문 수신 ({1}자, {2}) → Claude 백그라운드 호출 시작" -f (Get-Date -Format 'HH:mm:ss'), $q.Length, $mdl)
            Send-Json $res 200 (@{ ticket = $id } | ConvertTo-Json -Compress)
        } catch {
            Write-Host "오류: $_" -ForegroundColor Red
            Add-ServerError ('/chat: ' + $_.Exception.Message)
            try { Send-Json $res 500 (@{ reply = "서버 오류: $_" } | ConvertTo-Json -Depth 3) } catch {}
        }
        continue
    }

    # 비동기 결과 조회 (게임이 0.5초마다 폴링)
    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/result') {
        $id = $req.QueryString['id']
        $e = $script:jobs[$id]
        if ($null -eq $e) {
            Send-Json $res 200 '{"done":true,"ok":false,"reply":"알 수 없는 요청입니다 (서버가 재시작됐을 수 있어요). 다시 시도하세요."}'
            continue
        }
        if ($e.job.State -eq 'Running') {
            if (((Get-Date) - $e.started).TotalSeconds -gt 150) {
                Stop-Job $e.job -ErrorAction SilentlyContinue
                Remove-Job $e.job -Force -ErrorAction SilentlyContinue
                Write-CoachLog $e.kind $e.model $e.sessState $e.turn $e.inLen 0 `
                    ((Get-Date) - $e.started).TotalSeconds '시간초과'
                $script:jobs.Remove($id)
                Write-Host "  응답 시간 초과(150초) — 작업 중단" -ForegroundColor Yellow
                Send-Json $res 200 (@{ done = $true; ok = $false; reply = 'Claude 응답이 150초를 넘어 중단했습니다. 사용량 한도이거나 일시적 문제일 수 있어요 — 잠시 후 다시 시도해보세요.' } | ConvertTo-Json -Compress)
            } else {
                Send-Json $res 200 '{"done":false}'
            }
            continue
        }
        $out = (Receive-Job $e.job -ErrorAction SilentlyContinue | Out-String).Trim()
        Remove-Job $e.job -Force -ErrorAction SilentlyContinue
        $obj = $null
        if ($out -and -not $out.StartsWith('ERR:')) {
            try { $obj = $out | ConvertFrom-Json } catch { $obj = $null }
        }
        if ($null -eq $obj) {
            if (-not $e.retried -and $script:sessionId) {
                # 이전 세션 이어가기 실패 → 새 대화로 자동 재시도
                Write-Host "  이전 세션 이어가기 실패 — 새 대화로 재시도" -ForegroundColor Yellow
                $script:sessionId = $null
                $e.job = Start-ClaudeJob (Add-SessionPrefix $e.msg $e.kind) $null $e.model $e.fast ($e.kind -ne 'profile')
                $e.retried = $true
                $e.started = Get-Date
                Send-Json $res 200 '{"done":false}'
            } else {
                Write-CoachLog $e.kind $e.model $e.sessState $e.turn $e.inLen 0 `
                    ((Get-Date) - $e.started).TotalSeconds '실패'
                $script:jobs.Remove($id)
                Write-Host "  Claude 호출 실패: $out" -ForegroundColor Red
                Send-Json $res 200 (@{ done = $true; ok = $false; reply = ('Claude 호출 실패: ' + $out) } | ConvertTo-Json -Compress)
            }
            continue
        }
        $script:jobs.Remove($id)
        if ($obj.session_id) {
            $script:sessionId = $obj.session_id
            Set-Content -Path $sessionFile -Value $obj.session_id -Encoding ASCII
        }
        $reply = [string]$obj.result
        $took = ((Get-Date) - $e.started).TotalSeconds
        Write-CoachLog $e.kind $e.model $e.sessState $e.turn $e.inLen $reply.Length $took `
            $(if ($e.retried) { '성공(재시도)' } else { '성공' }) (Get-UsageText $obj)
        # 정확도 검증용 — 코치가 무엇을 보고 무엇이라 답했는지 전문 보관
        Write-GameLog ("┌─ 코치에게 보낸 내용 (" + $e.kind + ", " + ($e.model -replace 'claude-','') + ", " + $e.sessState + " " + $e.turn + "번째)")
        Write-GameLog ($e.msg)
        Write-GameLog ("├─ 코치 답변 (" + ("{0:N1}" -f $took) + "초)")
        Write-GameLog ($reply)
        Write-GameLog "└────────────────────────────"
        Write-Host ("[{0}] 답변 완료 ({1}자, {2:N1}초, {3} {4}번째)" -f `
            (Get-Date -Format 'HH:mm:ss'), $reply.Length, $took, $e.sessState, $e.turn) -ForegroundColor Cyan
        if ($e.kind -eq 'profile') {
            if ($reply.TrimStart().StartsWith('#')) {
                [System.IO.File]::WriteAllText($profileFile, $reply, (New-Object System.Text.UTF8Encoding($false)))
                # 기억이 노트에 압축 저장됐으므로 무거운 대화 세션은 리셋
                # → 다음 질문부터 새 대화 + 노트 자동 주입 = 속도 유지, 기억 유지
                $script:sessionId = $null
                Remove-Item $sessionFile -Force -ErrorAction SilentlyContinue
                Write-Host "  코칭 노트 저장 + 대화 세션 리셋 (속도 최적화)" -ForegroundColor Cyan
                Send-Json $res 200 (@{ done = $true; ok = $true; profile = $reply } | ConvertTo-Json -Depth 5 -Compress)
            } else {
                Write-Host "  관찰 데이터 부족 — 프로필 저장 안 함" -ForegroundColor Yellow
                Send-Json $res 200 (@{ done = $true; ok = $false; reply = $reply } | ConvertTo-Json -Compress)
            }
        } else {
            Send-Json $res 200 (@{ done = $true; ok = $true; reply = $reply } | ConvertTo-Json -Compress)
        }
        continue
    }

    $res.StatusCode = 404
    $res.Close()
    } catch {
        Write-Host ("  ⚠ 요청 처리 오류 (서버는 계속 동작): " + $_.Exception.Message) -ForegroundColor Yellow
        try { Add-ServerError ($ctx.Request.HttpMethod + ' ' + $ctx.Request.Url.AbsolutePath + ': ' + $_.Exception.Message) } catch {}
        # 가능하면 500을 보낸다. Abort만 하면 클라이언트는 '200 빈 본문'을 받아 성공처럼 보였다(검증 실측)
        try { Send-Json $ctx.Response 500 '{"ok":false,"error":"서버 오류"}' } catch { try { $ctx.Response.Abort() } catch {} }
    }
}
