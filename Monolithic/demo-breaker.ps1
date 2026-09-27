<#
.SYNOPSIS
    Drive and observe every Resilience4j guard in quiz-service.
.DESCRIPTION
        .\demo-breaker.ps1              8 sequential calls   (CircuitBreaker, Retry, RateLimiter)
        .\demo-breaker.ps1 12           12 sequential calls
        .\demo-breaker.ps1 parallel 10  10 CONCURRENT calls  (Bulkhead)
        .\demo-breaker.ps1 cache 1      read quiz 1 twice    (Cache)
        .\demo-breaker.ps1 state        current state, calls nothing
        .\demo-breaker.ps1 events       state-transition log

    From cmd.exe, which cannot run .ps1 directly:
        powershell -ExecutionPolicy Bypass -File demo-breaker.ps1 state

    Which mode needs which setup:
        question-service UP     -> RateLimiter, Cache
        question-service DOWN   -> CircuitBreaker, Retry
        question-service SLOW   -> TimeLimiter, Bulkhead
        (SLOW = Thread.sleep in QuestionController.getQuestionsForQuiz, the
         "generate" endpoint - that is the one /quiz/create actually calls)
.NOTES
    Works on Windows PowerShell 5.1 and PowerShell 7.
    Concurrency uses HttpClient tasks, so no -Parallel / PS7 requirement.
#>
param(
    [string]$Mode = "8",
    [string]$Arg2 = ""
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # no progress bar - much faster calls

$BASE   = "http://127.0.0.1:8090"
$NAME   = "QUESTION-SERVICE"
$BODY   = '{"category":"java","numQ":2,"title":"demo"}'

# ---------------------------------------------------------------- readers

function Read-Json($path) {
    try { return Invoke-RestMethod -Uri "$BASE$path" -TimeoutSec 5 }
    catch { return $null }
}

function Get-State {
    $r = Read-Json "/actuator/circuitbreakers"
    if ($null -eq $r) {
        Write-Host "      [!] cannot read /actuator/circuitbreakers - is quiz-service running?" -ForegroundColor Red
        return
    }
    $prop = $r.circuitBreakers.PSObject.Properties[$NAME]
    if ($null -eq $prop) {
        $names = ($r.circuitBreakers.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
        Write-Host "      [!] no breaker named $NAME. Present: $names" -ForegroundColor Yellow
        Write-Host "          -> CircuitBreakerNameResolver is not being picked up" -ForegroundColor Yellow
        return
    }
    $d = $prop.Value
    $colour = "Gray"
    if ($d.state -eq "OPEN")      { $colour = "Red" }
    if ($d.state -eq "HALF_OPEN") { $colour = "Yellow" }
    Write-Host ("      state={0,-10} buffered={1,-3} failed={2,-3} notPermitted={3,-3} rate={4}" `
        -f $d.state, $d.bufferedCalls, $d.failedCalls, $d.notPermittedCalls, $d.failureRate) -ForegroundColor $colour
}

function Get-Guards {
    $b = Read-Json "/actuator/bulkheads"
    $l = Read-Json "/actuator/ratelimiters"
    $parts = @()
    if ($b) {
        $bd = $b.bulkheads.PSObject.Properties[$NAME]
        if ($bd) { $parts += ("bulkhead free={0}/{1}" -f $bd.Value.availableConcurrentCalls, $bd.Value.maxAllowedConcurrentCalls) }
    }
    if ($l) {
        $ld = $l.rateLimiters.PSObject.Properties[$NAME]
        if ($ld) { $parts += ("ratelimiter permits={0}" -f $ld.Value.availablePermissions) }
    }
    if ($parts.Count -gt 0) { Write-Host ("      " + ($parts -join "   ")) -ForegroundColor DarkCyan }
}

function Get-Events {
    Write-Host ""
    Write-Host "=== State transition log ===" -ForegroundColor Cyan
    $r = Read-Json "/actuator/circuitbreakerevents"
    if ($null -eq $r) { Write-Host "  (cannot read /actuator/circuitbreakerevents)" -ForegroundColor Red; return }
    $tr = @($r.circuitBreakerEvents | Where-Object { $_.stateTransition })
    if ($tr.Count -gt 0) {
        foreach ($e in $tr) {
            Write-Host ("  {0}  {1}" -f $e.creationTime.Substring(11, 8), $e.stateTransition) -ForegroundColor Green
        }
    } else {
        Write-Host "  (no state transition yet)"
    }
    Write-Host ("  total events: {0}" -f @($r.circuitBreakerEvents).Count)
}

# ---------------------------------------------------------------- callers

function Invoke-Call($n) {
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $code = "ERR"
    try {
        $resp = Invoke-WebRequest -Uri "$BASE/quiz/create" -Method Post `
                    -ContentType "application/json" -Body $BODY -TimeoutSec 60 -UseBasicParsing
        $code = [int]$resp.StatusCode
    } catch {
        # 429 / 503 from a fallback throw on PS 5.1 - read the status code here
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    $sw.Stop()
    Write-Host ("  call {0,-3} http={1}  {2:N3}s" -f $n, $code, $sw.Elapsed.TotalSeconds) -ForegroundColor (Get-Colour $code)
}

function Get-Colour($code) {
    switch ($code) {
        201     { "Green" }
        429     { "Magenta" }   # OUR OWN limit: rate limiter or bulkhead
        503     { "Yellow" }    # THEIR outage: breaker open or retries exhausted
        default { "Gray" }
    }
}

# ---------------------------------------------------------------- modes

function Invoke-Sequential($n) {
    Write-Host "POST /quiz/create x $n  (sequential)"
    Write-Host "-----------------------------------------------------------"
    for ($i = 1; $i -le $n; $i++) {
        Invoke-Call $i
        Get-State
    }
    Write-Host "-----------------------------------------------------------"
    Get-Guards
    Get-Events
}

<#
  Bulkhead limits CONCURRENT calls, so a sequential loop can never trip it -
  one call finishes before the next starts. Every request here is fired before
  any of them completes.

  Needs question-service SLOW. If it answers in 20ms the calls never overlap
  long enough to reach the limit of 5.
#>
function Invoke-Parallel($n) {
    Write-Host "POST /quiz/create x $n  (all at once - Bulkhead)"
    Write-Host "-----------------------------------------------------------"
    Write-Host "  before:"
    Get-Guards

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]'
    for ($i = 1; $i -le $n; $i++) {
        $content = New-Object System.Net.Http.StringContent($BODY, [System.Text.Encoding]::UTF8, "application/json")
        $tasks.Add($client.PostAsync("$BASE/quiz/create", $content))
    }
    try { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray()) } catch { }
    $sw.Stop()

    $counts = @{}
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        # A faulted task returns $null for .Result in PowerShell rather than
        # throwing, and [int]$null is 0 - so check the status explicitly.
        $t    = $tasks[$i]
        $code = "ERR"
        if ($t.Status -eq 'RanToCompletion' -and $null -ne $t.Result) {
            $code = [int]$t.Result.StatusCode
        }
        Write-Host ("  call {0,-3} http={1}" -f ($i + 1), $code) -ForegroundColor (Get-Colour $code)
        if (-not $counts.ContainsKey($code)) { $counts[$code] = 0 }
        $counts[$code]++
    }
    $client.Dispose()

    Write-Host "-----------------------------------------------------------"
    Write-Host ("  wall clock: {0:N3}s" -f $sw.Elapsed.TotalSeconds)
    foreach ($k in ($counts.Keys | Sort-Object)) {
        Write-Host ("  http {0} x {1}" -f $k, $counts[$k]) -ForegroundColor (Get-Colour $k)
    }
    Write-Host ""
    Write-Host "  Expect roughly 5 accepted and the rest 429: max-concurrent-calls is 5." -ForegroundColor DarkGray
    Write-Host "  All 201 means the calls were too fast to overlap - make question-service slow." -ForegroundColor DarkGray
    Get-Guards
    Get-State
}

<#
  Cache sits on the READ path (/quiz/get/{id}), not on create.
  The strongest evidence is not the timing - it is question-service's console:
  the first read logs, the second logs NOTHING, because no request arrives.
#>
function Invoke-Cache($quizId) {
    Write-Host "POST /quiz/get/$quizId  x2  (Cache)"
    Write-Host "-----------------------------------------------------------"

    for ($i = 1; $i -le 2; $i++) {
        $sw   = [System.Diagnostics.Stopwatch]::StartNew()
        $code = "ERR"
        try {
            $resp = Invoke-WebRequest -Uri "$BASE/quiz/get/$quizId" -Method Post -TimeoutSec 60 -UseBasicParsing
            $code = [int]$resp.StatusCode
        } catch {
            if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
        }
        $sw.Stop()
        $label = if ($i -eq 1) { "miss (goes to question-service)" } else { "hit  (served from Caffeine)" }
        Write-Host ("  read {0}  http={1}  {2,7:N1} ms   {3}" -f $i, $code, $sw.Elapsed.TotalMilliseconds, $label) `
            -ForegroundColor (Get-Colour $code)
    }

    Write-Host "-----------------------------------------------------------"
    $c = Read-Json "/actuator/caches"
    if ($c) {
        $names = @()
        foreach ($p in $c.cacheManagers.PSObject.Properties) {
            foreach ($cc in $p.Value.caches.PSObject.Properties) { $names += $cc.Name }
        }
        if ($names.Count -gt 0) { Write-Host ("  caches: " + ($names -join ", ")) -ForegroundColor DarkCyan }
    }
    Write-Host "  Now look at the question-service console: only the FIRST read logged." -ForegroundColor DarkGray
    Write-Host "  404/500 here means quiz id $quizId does not exist - create one first." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- dispatch

switch ($Mode) {
    "events"   { Get-Events; exit 0 }
    "state"    { Write-Host "Current state:"; Get-State; Get-Guards; Get-Events; exit 0 }
    "reset"    { Write-Host "Current state:"; Get-State; Get-Guards; Get-Events; exit 0 }
    "parallel" {
        $n = 10
        if ($Arg2 -match '^\d+$') { $n = [int]$Arg2 }
        Invoke-Parallel $n; exit 0
    }
    "cache"    {
        $id = 1
        if ($Arg2 -match '^\d+$') { $id = [int]$Arg2 }
        Invoke-Cache $id; exit 0
    }
}

$n = 8
if ($Mode -match '^\d+$') { $n = [int]$Mode }
Invoke-Sequential $n
