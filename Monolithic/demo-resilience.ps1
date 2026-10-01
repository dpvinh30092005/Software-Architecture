<#
.SYNOPSIS
    Drive and observe every Resilience4j guard in quiz-service.
.DESCRIPTION
        .\demo-resilience.ps1 guide        narrated walkthrough, pauses between steps
        .\demo-resilience.ps1              8 sequential calls   (CircuitBreaker, Retry)
        .\demo-resilience.ps1 12           12 sequential calls
        .\demo-resilience.ps1 limit        fast burst           (RateLimiter)
        .\demo-resilience.ps1 parallel 10  10 concurrent calls  (Bulkhead)
        .\demo-resilience.ps1 cache 1      read quiz 1 twice    (Cache)
        .\demo-resilience.ps1 state        current state, calls nothing
        .\demo-resilience.ps1 events       state-transition log

    Calls go through api-gateway :8765 by default so Zipkin shows the full chain.
    Add -Direct to hit quiz-service :8090 and skip the gateway.

    From cmd.exe:
        powershell -ExecutionPolicy Bypass -File demo-resilience.ps1 guide

    Which mode needs which setup:
        question-service UP     -> RateLimiter, Cache
        question-service DOWN   -> CircuitBreaker, Retry
        question-service SLOW   -> TimeLimiter, Bulkhead
.NOTES
    Windows PowerShell 5.1 and PowerShell 7. Concurrency uses HttpClient tasks.
    This is the narrated rewrite of demo-breaker.ps1, which still works as before.
#>
param(
    [string]$Mode = "8",
    [string]$Arg2 = "",
    [switch]$Direct
)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$ADMIN   = "http://127.0.0.1:8090"
$GATEWAY = "http://127.0.0.1:8765/quiz-service"

if ($Direct) { $APP = $ADMIN; $ROUTE = "direct to quiz-service :8090" }
else         { $APP = $GATEWAY; $ROUTE = "via api-gateway :8765 -> quiz-service" }

$NAME = "QUESTION-SERVICE"
$BODY = '{"category":"java","numQ":2,"title":"demo"}'

$SEC_PER_CHAR = 0.1
$MAX_BAR      = 24

# ---------------------------------------------------------------- output

function Write-Rule { Write-Host ("-" * 72) -ForegroundColor DarkGray }

function Write-Title($text) {
    Write-Host ""
    Write-Host ("=== " + $text + " ===") -ForegroundColor Cyan
    Write-Host ("  route: " + $ROUTE) -ForegroundColor DarkCyan
}

function Write-Note($text) { Write-Host ("  " + $text) -ForegroundColor DarkGray }

function Get-Bar($seconds) {
    $w = [int][Math]::Round($seconds / $SEC_PER_CHAR)
    if ($w -lt 1)        { $w = 1 }
    if ($w -gt $MAX_BAR) { $w = $MAX_BAR }
    return ("#" * $w)
}

function Get-Colour($code) {
    switch ("$code") {
        "201"   { "Green" }
        "200"   { "Green" }
        "429"   { "Magenta" }
        "503"   { "Yellow" }
        default { "Gray" }
    }
}

function Wait-Step($prompt = "Press Enter to continue") {
    Write-Host ""
    Write-Host ("  >> " + $prompt + " ") -ForegroundColor Cyan -NoNewline
    [void](Read-Host)
}

# ---------------------------------------------------------------- readers

function Read-Json($path) {
    try { return Invoke-RestMethod -Uri "$ADMIN$path" -TimeoutSec 5 }
    catch { return $null }
}

function Get-BreakerData {
    $r = Read-Json "/actuator/circuitbreakers"
    if ($null -eq $r) { return $null }
    $p = $r.circuitBreakers.PSObject.Properties[$NAME]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-Gateway {
    if ($Direct) { return $true }
    try {
        $h = Invoke-WebRequest -Uri "http://127.0.0.1:8765/actuator/health" -TimeoutSec 4 -UseBasicParsing
        if ([int]$h.StatusCode -eq 200) { return $true }
    } catch { }
    Write-Host "  [!] api-gateway :8765 is not responding." -ForegroundColor Red
    Write-Host "      Start it, or add -Direct to bypass it:" -ForegroundColor Yellow
    Write-Host "        .\demo-resilience.ps1 $Mode $Arg2 -Direct" -ForegroundColor Yellow
    return $false
}

function Test-ServiceUp {
    if (-not (Test-Gateway)) { return $false }
    if ($null -ne (Get-BreakerData)) { return $true }
    $r = Read-Json "/actuator/circuitbreakers"
    if ($null -eq $r) {
        Write-Host "  [!] cannot reach $ADMIN - is quiz-service running?" -ForegroundColor Red
    } else {
        $names = ($r.circuitBreakers.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
        Write-Host "  [!] no breaker named $NAME. Present: $names" -ForegroundColor Yellow
        Write-Host "      CircuitBreakerNameResolver is not being picked up." -ForegroundColor Yellow
    }
    return $false
}

function Show-State {
    $d = Get-BreakerData
    if ($null -eq $d) { return }
    $colour = "Gray"
    if ($d.state -eq "OPEN")      { $colour = "Red" }
    if ($d.state -eq "HALF_OPEN") { $colour = "Yellow" }
    Write-Host ("  breaker {0,-10} calls={1,-3} failed={2,-3} blocked={3,-3} rate={4}" `
        -f $d.state, $d.bufferedCalls, $d.failedCalls, $d.notPermittedCalls, $d.failureRate) -ForegroundColor $colour
}

function Show-Guards {
    $b = Read-Json "/actuator/bulkheads"
    $l = Read-Json "/actuator/ratelimiters"
    $parts = @()
    if ($b) {
        $bd = $b.bulkheads.PSObject.Properties[$NAME]
        if ($bd) { $parts += ("bulkhead free {0}/{1}" -f $bd.Value.availableConcurrentCalls, $bd.Value.maxAllowedConcurrentCalls) }
    }
    if ($l -and @($l.rateLimiters) -contains $NAME) {
        $parts += "ratelimiter registered (permit count not exposed by this build)"
    }
    if ($parts.Count -gt 0) { Write-Host ("  " + ($parts -join "   ")) -ForegroundColor DarkCyan }
}

function Show-Events {
    Write-Title "State transitions"
    $r = Read-Json "/actuator/circuitbreakerevents"
    if ($null -eq $r) { Write-Host "  (cannot read /actuator/circuitbreakerevents)" -ForegroundColor Red; return }
    $tr = @($r.circuitBreakerEvents | Where-Object { $_.stateTransition })
    if ($tr.Count -gt 0) {
        foreach ($e in $tr) {
            Write-Host ("  {0}  {1}" -f $e.creationTime.Substring(11, 8), $e.stateTransition) -ForegroundColor Green
        }
    } else {
        Write-Host "  (none yet)" -ForegroundColor DarkGray
    }
    Write-Host ("  {0} events recorded" -f @($r.circuitBreakerEvents).Count) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- caller

function Invoke-Call($path = "/quiz/create", $method = "Post", $body = $BODY) {
    $sw   = [System.Diagnostics.Stopwatch]::StartNew()
    $code = "ERR"
    try {
        if ($body) {
            $resp = Invoke-WebRequest -Uri "$APP$path" -Method $method -ContentType "application/json" `
                        -Body $body -TimeoutSec 60 -UseBasicParsing
        } else {
            $resp = Invoke-WebRequest -Uri "$APP$path" -Method $method -TimeoutSec 60 -UseBasicParsing
        }
        $code = [int]$resp.StatusCode
    } catch {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
    }
    $sw.Stop()
    return [pscustomobject]@{ Code = $code; Seconds = $sw.Elapsed.TotalSeconds }
}

# ---------------------------------------------------------------- modes

function Invoke-Sequential($n) {
    Write-Title "CIRCUIT BREAKER + RETRY"
    Write-Note "Opens when failures reach 50% of the last 10 calls, minimum 5 calls."
    Write-Note "Retry turns one request into 3 attempts, so one request counts as 3 failures."
    Write-Rule

    if (-not (Test-ServiceUp)) { return }

    $slow = @()
    $fast = @()
    $announced = $false

    for ($i = 1; $i -le $n; $i++) {
        $before  = Get-BreakerData
        $wasOpen = ($null -ne $before -and $before.state -eq "OPEN")

        $r     = Invoke-Call
        $after = Get-BreakerData

        if ($wasOpen) {
            $tag = "blocked, nothing left the process"
            $fast += $r.Seconds
        } else {
            $tag = "failed {0}/5" -f $after.failedCalls
            $slow += $r.Seconds
        }

        Write-Host ("  #{0,-3} {1}  {2,7:N3}s  {3,-24}  {4}" -f $i, $r.Code, $r.Seconds, (Get-Bar $r.Seconds), $tag) `
            -ForegroundColor (Get-Colour $r.Code)

        if (-not $announced -and $null -ne $after -and $after.state -eq "OPEN") {
            Write-Host ""
            Write-Host "  *** BREAKER OPEN - calls rejected instantly, no network involved ***" -ForegroundColor Red
            Write-Host ""
            $announced = $true
        }
    }

    Write-Rule
    if ($slow.Count -gt 0 -and $fast.Count -gt 0) {
        $avgSlow = ($slow | Measure-Object -Average).Average
        $avgFast = ($fast | Measure-Object -Average).Average
        $sumSlow = ($slow | Measure-Object -Sum).Sum
        $sumFast = ($fast | Measure-Object -Sum).Sum
        Write-Host ("  before open   {0,2} calls x {1,6:N3}s = {2,7:N2}s" -f $slow.Count, $avgSlow, $sumSlow) -ForegroundColor Yellow
        Write-Host ("  after open    {0,2} calls x {1,6:N3}s = {2,7:N2}s" -f $fast.Count, $avgFast, $sumFast) -ForegroundColor Green
        if ($avgFast -gt 0) {
            Write-Host ("  {0:N0}x faster - that is what a circuit breaker buys you" -f ($avgSlow / $avgFast)) -ForegroundColor Cyan
        }
    } else {
        Write-Note "Breaker never opened. Stop question-service and run this again."
    }
    Write-Host ""
    Show-State
    Show-Guards
}

function Invoke-RateLimit($n) {
    Write-Title "RATE LIMITER"
    Write-Note "5 calls per 10 seconds. timeout-duration 0 means rejected at once, never queued."
    Write-Rule

    if (-not (Test-ServiceUp)) { return }

    $ok = 0; $limited = 0
    for ($i = 1; $i -le $n; $i++) {
        $r = Invoke-Call
        if ($r.Code -eq 429) { $mark = "quota exhausted"; $limited++ } else { $mark = "accepted"; $ok++ }
        Write-Host ("  #{0,-3} {1}  {2,7:N3}s  {3}" -f $i, $r.Code, $r.Seconds, $mark) -ForegroundColor (Get-Colour $r.Code)
    }

    Write-Rule
    Write-Host ("  {0} accepted, {1} rejected with 429" -f $ok, $limited) -ForegroundColor Cyan
    Write-Note "429 is OUR limit. The remote service is healthy - that is why it is not 503."
    Show-Guards
}

function Get-BulkheadRejections {
    $r = Read-Json "/actuator/bulkheadevents"
    if ($null -eq $r) { return -1 }
    return @($r.bulkheadEvents | Where-Object { $_.type -eq "CALL_REJECTED" }).Count
}

function Invoke-Parallel($n) {
    Write-Title "BULKHEAD"
    Write-Note "max-concurrent-calls 5, max-wait-duration 0 - the 6th concurrent call is rejected."
    Write-Note "A sequential loop can never trip this. Every call below is fired before any finishes."
    Write-Note "Both guards answer 429, so the bulkhead event log is what tells them apart."
    Write-Rule

    if (-not (Test-ServiceUp)) { return }
    Write-Host "  before:" -ForegroundColor DarkGray
    Show-Guards

    Write-Host "  waiting 11s so the rate limiter is not the thing that rejects..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 11
    $rej0 = Get-BulkheadRejections

    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(60)

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task[System.Net.Http.HttpResponseMessage]]'
    for ($i = 1; $i -le $n; $i++) {
        $content = New-Object System.Net.Http.StringContent($BODY, [System.Text.Encoding]::UTF8, "application/json")
        $tasks.Add($client.PostAsync("$APP/quiz/create", $content))
    }
    try { [System.Threading.Tasks.Task]::WaitAll($tasks.ToArray()) } catch { }
    $sw.Stop()

    $counts = @{}
    for ($i = 0; $i -lt $tasks.Count; $i++) {
        $t = $tasks[$i]
        $code = "ERR"
        if ($t.Status -eq 'RanToCompletion' -and $null -ne $t.Result) { $code = [int]$t.Result.StatusCode }
        Write-Host ("  #{0,-3} {1}" -f ($i + 1), $code) -ForegroundColor (Get-Colour $code)
        if (-not $counts.ContainsKey("$code")) { $counts["$code"] = 0 }
        $counts["$code"]++
    }
    $client.Dispose()

    $rej1 = Get-BulkheadRejections
    $byBulkhead = 0
    if ($rej0 -ge 0 -and $rej1 -ge 0) { $byBulkhead = $rej1 - $rej0 }
    $r429 = 0
    if ($counts.ContainsKey("429")) { $r429 = $counts["429"] }
    $byLimiter = $r429 - $byBulkhead
    if ($byLimiter -lt 0) { $byLimiter = 0 }

    Write-Rule
    foreach ($k in ($counts.Keys | Sort-Object)) {
        Write-Host ("  http {0} x {1}" -f $k, $counts[$k]) -ForegroundColor (Get-Colour $k)
    }
    Write-Host ("  wall clock {0:N3}s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  who rejected what (from the bulkhead event log):" -ForegroundColor White
    Write-Host ("    bulkhead      {0}" -f $byBulkhead) -ForegroundColor Magenta
    Write-Host ("    rate limiter  {0}" -f $byLimiter) -ForegroundColor Yellow
    Write-Host ""

    if ($byBulkhead -eq 0) {
        Write-Note "The bulkhead rejected nothing. With max-concurrent-calls 5 and the rate"
        Write-Note "limiter at 5 per 10s, at most 5 calls can ever be in flight - exactly the"
        Write-Note "bulkhead limit, so it can never reject. To make it reachable, either set"
        Write-Note "max-concurrent-calls to 2, or raise limit-for-period well above 5."
        Write-Note "A slow question-service also works: calls then span several limiter windows."
    } else {
        Write-Note "Rejected, not queued - that is the difference from a rate limiter."
    }
    Show-Guards
}

function Get-CacheCount($result) {
    $r = Read-Json "/actuator/metrics/cache.gets?tag=result:$result"
    if ($null -eq $r) { return -1 }
    $m = $r.measurements | Where-Object { $_.statistic -eq "COUNT" } | Select-Object -First 1
    if ($null -eq $m) { return -1 }
    return [int]$m.value
}

function Invoke-Cache($quizId) {
    Write-Title "CACHE"
    Write-Note "Caffeine, maximumSize 500, expireAfterWrite 60s, on the READ path only."
    Write-Note "The clock cannot prove this - the HTTP hop to quiz-service costs more than"
    Write-Note "the lookup it saves. Caffeine's own hit/miss counters can."
    Write-Rule

    $h0 = Get-CacheCount "hit"
    $m0 = Get-CacheCount "miss"
    if ($h0 -lt 0) {
        Write-Host "  [!] cache.gets not exposed - add recordStats to the Caffeine spec." -ForegroundColor Red
        return
    }
    Write-Host ("  start        hits={0,-4} misses={1}" -f $h0, $m0) -ForegroundColor DarkGray
    Write-Host ""

    $prevH = $h0; $prevM = $m0
    $waited = $false
    for ($i = 1; $i -le 2; $i++) {
        $r  = Invoke-Call "/quiz/get/$quizId" "Post" $null
        $ms = $r.Seconds * 1000
        $h  = Get-CacheCount "hit"
        $m  = Get-CacheCount "miss"
        $dh = $h - $prevH
        $dm = $m - $prevM

        if ($dh -eq 0 -and $dm -eq 0 -and -not $waited) {
            Write-Host ("  read {0}  {1}  rejected before the cache - rate limiter quota is spent" -f $i, $r.Code) -ForegroundColor Magenta
            Write-Host "  waiting 11s for the 10s window to refill, then starting over" -ForegroundColor DarkGray
            Start-Sleep -Seconds 11
            $waited = $true
            $h0 = Get-CacheCount "hit"; $m0 = Get-CacheCount "miss"
            $prevH = $h0; $prevM = $m0
            Write-Host ""
            $i = 0
            continue
        }

        if ($dm -gt 0)     { $verdict = "MISS - went to question-service"; $colour = "Yellow" }
        elseif ($dh -gt 0) { $verdict = "HIT  - served from memory, no call made"; $colour = "Green" }
        else               { $verdict = "never reached the cache - see diagnosis below"; $colour = "Red" }

        Write-Host ("  read {0}  {1}  {2,8:N1} ms   hit+{3} miss+{4}   {5}" -f $i, $r.Code, $ms, $dh, $dm, $verdict) `
            -ForegroundColor $colour
        $prevH = $h; $prevM = $m
    }

    Write-Rule
    $totalH = $prevH - $h0
    $totalM = $prevM - $m0
    if ($totalM -eq 1 -and $totalH -eq 1) {
        Write-Host "  1 miss then 1 hit - the cache did its job." -ForegroundColor Cyan
        Write-Note "Second read never reached question-service. Its console logged nothing."
    } elseif ($totalM -eq 0 -and $totalH -eq 2) {
        Write-Host "  2 hits, 0 misses - quiz $quizId was ALREADY cached from an earlier run." -ForegroundColor Yellow
        Write-Note "expireAfterWrite is 60s. Wait a minute, or use a quiz id you have not read yet."
    } elseif ($totalM -eq 2) {
        Write-Host "  2 misses - nothing was cached between the reads." -ForegroundColor Red
        Write-Note "Check @Cacheable is on getQuizQuestion and that the result was not null."
    } else {
        Write-Host ("  hits +{0}, misses +{1} - a read never reached the cache." -f $totalH, $totalM) -ForegroundColor Red
        Write-Host ""
        Write-Host "  diagnosis:" -ForegroundColor White

        $qs = "unreachable"
        try {
            $h = Invoke-WebRequest -Uri "http://127.0.0.1:8081/actuator/health" -TimeoutSec 4 -UseBasicParsing
            if ([int]$h.StatusCode -eq 200) { $qs = "UP" }
        } catch { }
        Write-Host ("    question-service :8081   {0}" -f $qs) -ForegroundColor DarkGray

        $d = Get-BreakerData
        if ($null -ne $d) {
            Write-Host ("    breaker                  {0}, failed={1}, blocked={2}" -f $d.state, $d.failedCalls, $d.notPermittedCalls) -ForegroundColor DarkGray
        }
        $rl = Read-Json "/actuator/ratelimiterevents"
        if ($null -ne $rl) {
            Write-Host ("    ratelimiter events       {0}" -f @($rl.rateLimiterEvents).Count) -ForegroundColor DarkGray
        }
        $bh = Read-Json "/actuator/bulkheadevents"
        $rej = -1
        if ($null -ne $bh) {
            $rej = @($bh.bulkheadEvents | Where-Object { $_.type -eq "CALL_REJECTED" }).Count
            Write-Host ("    bulkhead rejections      {0}" -f $rej) -ForegroundColor DarkGray
        }
        Write-Host ""

        $breakerQuiet = ($null -eq $d -or ($d.state -eq "CLOSED" -and $d.notPermittedCalls -eq 0))
        if ($qs -eq "UP" -and $breakerQuiet) {
            Write-Host "  >> Almost certainly the RATE LIMITER." -ForegroundColor Magenta
            Write-Note "5 calls per 10 seconds. Every read spends a permit - even a cache HIT,"
            Write-Note "because the limiter sits OUTSIDE the cache in the aspect chain."
            Write-Note "It reports nothing: this app publishes no ratelimiter metrics or events."
            Write-Note "Prove it: wait 12s, then fire 8 reads. Exactly 5 will pass."
        } else {
            Write-Note "question-service down or the breaker is open - see the numbers above."
        }
    }
    Write-Note "404 or 500 means quiz id $quizId does not exist - create one first."
}

# ---------------------------------------------------------------- guide

function Invoke-Guide {
    Clear-Host
    Write-Host ""
    Write-Host "  RESILIENCE4J - GUIDED WALKTHROUGH" -ForegroundColor Cyan
    Write-Host "  quiz-service :8090  ->  question-service" -ForegroundColor DarkGray
    Write-Rule
    Write-Host ""
    Write-Host "  Five guards wrap every call quiz-service makes to question-service:" -ForegroundColor White
    Write-Host ""
    Write-Host "    Retry ( CircuitBreaker ( RateLimiter ( TimeLimiter ( Bulkhead ( call ) ) ) ) )" -ForegroundColor Yellow
    Write-Host ""
    Write-Note "Retry is outermost, so it retries the whole stack below it."
    Write-Note "Bulkhead is innermost, so it counts threads actually in flight."

    Wait-Step "Enter to read the current state"

    Write-Title "STEP 0 - where we are now"
    if (-not (Test-ServiceUp)) {
        Write-Host ""
        Write-Host "  Start quiz-service first, then run this again." -ForegroundColor Red
        return
    }
    Show-State
    Show-Guards
    Show-Events

    Wait-Step "STOP question-service now, then press Enter"

    Write-Title "STEP 1 - CircuitBreaker"
    Write-Note "Every request below fails. Watch the time column, not just the status code."
    Invoke-Sequential 8

    Wait-Step "Enter to see what the breaker recorded"
    Show-Events
    Write-Host ""
    Write-Note "One user request produced THREE failures, because Retry fires 3 attempts."
    Write-Note "That is why the breaker opened after 2 requests instead of 5."

    Wait-Step "Enter to watch it try to recover"

    Write-Title "STEP 2 - HALF_OPEN"
    Write-Note "wait-duration-in-open-state is 10s, then a few trial calls are allowed through."
    Write-Host ""
    for ($i = 10; $i -ge 1; $i--) {
        Write-Host ("`r  waiting {0,2}s ..." -f $i) -NoNewline -ForegroundColor DarkGray
        Start-Sleep -Seconds 1
    }
    Write-Host "`r                      "
    Show-State
    Write-Note "HALF_OPEN permits 3 trial calls. Still failing -> OPEN again. Healthy -> CLOSED."

    Wait-Step "START question-service again, then press Enter"

    Write-Title "STEP 3 - recovery"
    Invoke-Sequential 6
    Show-Events

    Wait-Step "Enter for the RateLimiter"

    Write-Title "STEP 4 - RateLimiter"
    Write-Note "The remote service is healthy now, so anything rejected here is OUR decision."
    Invoke-RateLimit 8
    Write-Host ""
    Write-Note "429 vs 503 is the whole point: 429 we throttled you, 503 they are down."

    Wait-Step "Enter for the Cache"

    Write-Title "STEP 5 - Cache"
    Invoke-Cache 1

    Write-Host ""
    Write-Rule
    Write-Host "  Not covered here - these need question-service made SLOW:" -ForegroundColor White
    Write-Note "Bulkhead     .\demo-resilience.ps1 parallel 10"
    Write-Note "TimeLimiter  add Thread.sleep(10000) to QuestionController.getQuestionsForQuiz"
    Write-Host ""
}

# ---------------------------------------------------------------- dispatch

switch ($Mode) {
    "guide"    { Invoke-Guide; exit 0 }
    "events"   { Show-Events; exit 0 }
    "state"    { Write-Title "Current state"; Show-State; Show-Guards; Show-Events; exit 0 }
    "limit"    {
        $n = 8
        if ($Arg2 -match '^\d+$') { $n = [int]$Arg2 }
        Invoke-RateLimit $n; exit 0
    }
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
