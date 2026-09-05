# 홀덤 코치 중계 서버
# holdem.html 의 채팅을 받아 Claude Code CLI(claude -p)로 전달하고 답변을 돌려준다.
# 실행: 코치서버시작.bat 더블클릭 (또는 powershell -ExecutionPolicy Bypass -File coach-server.ps1)

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
Write-Host "  이 창을 닫으면 코치 채팅이 중단됩니다. (게임 자체는 계속 가능)"
Write-Host ""

$script:sessionId = $null
# 세션 누적 호출 수. 이 횟수를 넘으면 세션을 새로 시작해 응답 속도를 되돌린다.
# (대화가 길어질수록 --resume 이 실어 나르는 양이 커져 느려지기 때문)
$script:turnCount = 0
$script:sessionMaxTurns = 20

# 코치가 사용할 모델. 빠르고 가벼운 코칭엔 sonnet 추천.
# 더 깊은 분석을 원하면 'claude-opus-4-8' 등으로 바꾸세요.
$coachModel = 'claude-sonnet-5'

$claudeExe = (Get-Command claude).Source

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

function Start-ClaudeJob([string]$message, [string]$resumeId, [string]$model, [bool]$fast) {
    if (-not $model) { $model = $coachModel }
    Start-Job -ScriptBlock {
        param($msg, $resume, $mdl, $exe, $fastMode)
        $argLine = '-p --output-format json --model ' + $mdl
        if ($resume) { $argLine += ' --resume ' + $resume }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $argLine
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
    } -ArgumentList $message, $resumeId, $model, $claudeExe, $fast
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
    if ($wasNew) { $send = Add-ProfilePrefix $rawMsg }
    $script:turnCount++
    $job = Start-ClaudeJob $send $script:sessionId $model $fast
    $id = [guid]::NewGuid().ToString('N')
    $script:jobs[$id] = @{
        job = $job; kind = $kind; msg = $rawMsg; started = (Get-Date); retried = $false; model = $model
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
    $header = "시각`t종류`t모델`t세션`t세션내순번`t보낸글자`t받은글자`t걸린초`t결과"
    [System.IO.File]::WriteAllText($logFile, $header + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
}
function Write-CoachLog([string]$kind, [string]$model, [string]$sessState, [int]$turn,
                        [int]$inLen, [int]$outLen, [double]$sec, [string]$result) {
    try {
        $line = "{0}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7:N1}`t{8}" -f `
            (Get-Date -Format 'MM-dd HH:mm:ss'), $kind, ($model -replace 'claude-',''),
            $sessState, $turn, $inLen, $outLen, $sec, $result
        [System.IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

# 전체 타임라인 로그 — 게임 액션 + 코치 호출을 한 파일에 시간순으로
$gameLogFile = Join-Path $PSScriptRoot 'game-log.txt'
function Write-GameLog([string]$text) {
    try {
        $line = (Get-Date -Format 'HH:mm:ss.fff') + '  ' + $text
        [System.IO.File]::AppendAllText($gameLogFile, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

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
    $req = $ctx.Request
    $res = $ctx.Response
    $res.Headers.Add('Access-Control-Allow-Origin', '*')
    $res.Headers.Add('Access-Control-Allow-Headers', 'Content-Type')
    $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')

    if ($req.HttpMethod -eq 'OPTIONS') {
        $res.StatusCode = 204
        $res.Close()
        continue
    }

    if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/ping') {
        Send-Json $res 200 '{"ok":true}'
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
                $reqStream = $hwr.GetRequestStream()
                $req.InputStream.CopyTo($reqStream)
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
            try { Send-Json $res 502 '{"ok":false,"error":"기록 서버 중계 실패"}' } catch {}
        }
        continue
    }

    # 게임에서 보내는 이벤트를 타임라인 로그에 기록
    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/gamelog') {
        try {
            $rd = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $b = $rd.ReadToEnd() | ConvertFrom-Json
            # 게임이 보낸 '발생 시각'이 있으면 그걸 쓴다 (전송 지연에 순서가 흔들리지 않게)
            if ($b.text) {
                if ($b.t) {
                    [System.IO.File]::AppendAllText($gameLogFile,
                        ([string]$b.t + '  ' + [string]$b.text + "`r`n"),
                        (New-Object System.Text.UTF8Encoding($false)))
                } else {
                    Write-GameLog ([string]$b.text)
                }
            }
        } catch {}
        Send-Json $res 200 '{"ok":true}'
        continue
    }

    # 행동 음성 안내 (Windows TTS로 즉시 발화)
    if ($req.HttpMethod -eq 'POST' -and $req.Url.AbsolutePath -eq '/say') {
        try {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $b = $reader.ReadToEnd() | ConvertFrom-Json
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
        try {
            $existing = '(아직 없음)'
            if (Test-Path $profileFile) {
                $e = [System.IO.File]::ReadAllText($profileFile, (New-Object System.Text.UTF8Encoding($false)))
                if ($e.Trim()) { $existing = $e }
            }
            # 게임이 보낸 실제 핸드 기록 (없으면 대화 기억에만 의존 → 근거 없는 노트가 됨)
            $handsText = ''
            try {
                $reader2 = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $raw2 = $reader2.ReadToEnd()
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
            try { Send-Json $res 500 (@{ ok = $false; reply = "프로필 갱신 실패: $_" } | ConvertTo-Json -Depth 3) } catch {}
        }
        continue
    }

    # 게임 페이지 서빙 (http://localhost:8765/ 로 접속하면 게임이 열림)
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
        try {
            $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
            $body = $reader.ReadToEnd() | ConvertFrom-Json
            $q = [string]$body.message
            # 화면에서 선택한 코치 모델 (허용 목록만)
            $mdl = [string]$body.model
            if ($mdl -notin @('claude-haiku-4-5', 'claude-sonnet-5')) { $mdl = $coachModel }
            # fast=true : 선행 분석 전용. 모델은 사용자가 고른 것(정밀)을 그대로 쓰고,
            # 답 전에 과도하게 생각하는 것만 줄인다 (측정: 같은 형식으로 68초 → 15.9초).
            # 모델을 낮추면 카드·상황을 잘못 읽을 수 있어 정확도를 포기하지 않는다.
            $fast = [bool]$body.fast
            $id = New-ClaudeTicket $q $(if ($fast) { 'pre' } else { 'chat' }) $mdl $fast
            Write-Host ("[{0}] 질문 수신 ({1}자, {2}) → Claude 백그라운드 호출 시작" -f (Get-Date -Format 'HH:mm:ss'), $q.Length, $mdl)
            Send-Json $res 200 (@{ ticket = $id } | ConvertTo-Json -Compress)
        } catch {
            Write-Host "오류: $_" -ForegroundColor Red
            try { Send-Json $res 500 (@{ reply = "서버 오류: $_" } | ConvertTo-Json -Depth 3) } catch {}
        }
        continue
    }

    # 비동기 결과 조회 (게임이 2초마다 폴링)
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
                $e.job = Start-ClaudeJob (Add-ProfilePrefix $e.msg) $null $e.model
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
            $(if ($e.retried) { '성공(재시도)' } else { '성공' })
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
}
