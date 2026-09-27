# Resilience4j in quiz-service

Every guard here protects **quiz-service** from **question-service**. None of them
make question-service work. That is the whole idea: turn a dependency you do not
control into a dependency with a **budget** — how long, how many, and when to stop trying.

All configuration lives in `quiz-service/src/main/resources/application.yaml`.
Instance names are all `QUESTION-SERVICE`, matching the Feign client name.

---

## The six, in one line each

| Module | Limits | Rejects with |
|---|---|---|
| **TimeLimiter** | how **long** one call may take | `TimeoutException` |
| **Bulkhead** | how **many** calls run at once | `BulkheadFullException` |
| **RateLimiter** | how many calls per **period** | `RequestNotPermitted` |
| **CircuitBreaker** | whether to call **at all** | `CallNotPermittedException` |
| **Retry** | how many **attempts** per request | original exception |
| **Cache** | whether to call **again** | — (returns the stored value) |

## Nesting order

From the Resilience4j docs:

```
Retry ( CircuitBreaker ( RateLimiter ( TimeLimiter ( Bulkhead ( call ) ) ) ) )
```

Because this project keeps Spring Cloud's Feign-level circuit breaker, the
effective order for `QuizService` methods is:

```
Retry ( RateLimiter ( Bulkhead ( Feign[ CircuitBreaker ( TimeLimiter ( call ) ) ] ) ) )
```

Retry outermost is the part that matters: when the breaker is OPEN, retrying is
pointless, so `CallNotPermittedException` is in retry's `ignore-exceptions`.

Override the order with `resilience4j.<module>.<module>AspectOrder` (higher = outer).

---

## 1. TimeLimiter

**Essence.** A dead service is easy — TCP refuses instantly. A **slow** service is
the dangerous one: it accepts the connection and never answers, holding one of your
threads for Feign's default 60 seconds. TimeLimiter converts *hanging* into *failed*
so the other guards have something to count. Without it the circuit breaker can
never open on a hang.

```yaml
timelimiter:
  configs:
    default:
      timeout-duration: 3s
      cancel-running-future: true      # release the thread, do not leak it
```

**Code.** Applied automatically by Spring Cloud CircuitBreaker around every Feign
call. The `@TimeLimiter` annotation only works on methods returning
`CompletableFuture`, so it is not used on the blocking service methods here.

**Demo.** Make question-service slow rather than dead:

```java
@GetMapping("generate")
public ResponseEntity<List<Integer>> getQuestionsForQuiz(...) throws InterruptedException {
    Thread.sleep(10000);        // TEMPORARY
    ...
}
```

Each call now takes exactly **3.0s** instead of 10s. Remove the sleep afterwards.

---

## 2. Bulkhead

**Essence.** Named after ship compartments: flood one, the ship still floats.
Tomcat has ~200 threads. If a slow dependency is allowed to consume all of them,
endpoints that never touch that dependency also stop responding — one sick service
takes the whole app down. Bulkhead caps how many threads a dependency may hold.

```yaml
bulkhead:
  configs:
    default:
      max-concurrent-calls: 5
      max-wait-duration: 0       # 0 = reject at once instead of queueing
```

Semaphore type (the default) counts permits. The thread-pool type
(`resilience4j.thread-pool-bulkhead`) runs calls on its own pool and needs a
`CompletableFuture` return type.

`resilience4j-bulkhead` is **optional** inside the Spring Cloud starter — it must be
declared explicitly in `pom.xml`.

```java
@Bulkhead(name = "QUESTION-SERVICE")
public ResponseEntity<String> createQuiz(...) { ... }
```

**Demo.** Needs concurrency, so a sequential loop will not show it:

```powershell
1..10 | ForEach-Object -Parallel {
  curl.exe -s -o NUL -w "%{http_code}`n" -X POST http://127.0.0.1:8090/quiz/create `
    -H "Content-Type: application/json" -d '{\"category\":\"java\",\"numQ\":2,\"title\":\"b\"}'
} -ThrottleLimit 10
```

(`-Parallel` needs PowerShell 7.) Expect ~5 × `201` and ~5 × `429`. Then:

```
curl.exe http://localhost:8090/actuator/bulkheads
```

---

## 3. RateLimiter

**Essence.** The other guards protect **you** from **them**. RateLimiter protects
**them** from **you** — or protects a quota you must not exceed. A partner API that
allows 100 requests a minute will start returning 429 or ban your key; better to
throttle yourself deliberately than be throttled unpredictably.

```yaml
ratelimiter:
  configs:
    default:
      limit-for-period: 5          # 5 calls...
      limit-refresh-period: 10s    # ...per 10 seconds
      timeout-duration: 0          # 0 = reject now; >0 = queue and wait for a permit
      register-health-indicator: true
```

Defaults are wide open (`limitForPeriod: 50`, `limitRefreshPeriod: 500ns`,
`timeoutDuration: 5s`) so this module does nothing until configured.

```java
@RateLimiter(name = "QUESTION-SERVICE")
public ResponseEntity<String> createQuiz(...) { ... }
```

**Demo.** With question-service **up**, six quick calls:

```powershell
.\demo-breaker.ps1 6
```

The first five return `201`, the sixth `429`. Wait ten seconds and it works again.

```
curl.exe http://localhost:8090/actuator/ratelimiters
```

---

## 4. CircuitBreaker

**Essence.** Not "fail faster" — it exists because **when a dependency is really
down, retrying makes things worse**. 100 requests × 3 retries × 3s timeout burns
900 seconds of thread time and buries a service that is trying to restart. The
breaker notices "this failure is sustained", stops calling entirely for a while,
then probes.

```yaml
circuitbreaker:
  configs:
    default:
      sliding-window-type: COUNT_BASED
      sliding-window-size: 10
      minimum-number-of-calls: 5                    # below this, never decide
      failure-rate-threshold: 50
      slow-call-rate-threshold: 50                  # slow counts as broken too
      slow-call-duration-threshold: 2s
      wait-duration-in-open-state: 10s              # production: 30-60s
      permitted-number-of-calls-in-half-open-state: 3
      automatic-transition-from-open-to-half-open-enabled: true
      register-health-indicator: true
      allow-health-indicator-to-fail: false         # THEIR outage must not mark US down
      ignore-exceptions:
        - io.github.resilience4j.ratelimiter.RequestNotPermitted
        - io.github.resilience4j.bulkhead.BulkheadFullException
```

**States.**

```
CLOSED ── rate > 50% ──► OPEN ── after 10s ──► HALF_OPEN
 (calling,                (rejecting          (3 probe calls)
  recording)               instantly)               │
    ▲                                               │
    └────────── probes succeed, counters reset ─────┘
```

**Code.** Applied by Spring Cloud inside Feign. The name is forced to the client
name by `FeignCircuitBreakerConfig` — without that, the id is per-method and every
tuned value above is ignored.

**Demo.** Stop question-service, then:

```powershell
.\demo-breaker.ps1 8
```

Read the columns: `failed` climbs to 5 → `state=OPEN` → `failed` freezes while
`notPermitted` climbs. That pair is the proof: rejected without touching the network.

Restart question-service, wait 10s, run again: `OPEN → HALF_OPEN → CLOSED`.

---

## 5. Retry

**Essence.** Retry assumes failure is **transient** — a network blip, one node
restarting. The circuit breaker assumes failure is **sustained**. They are opposite
bets, which is why they belong together: retry handles the blip, the breaker stops
retry from making a real outage worse.

```yaml
retry:
  configs:
    default:
      max-attempts: 3                  # 1 original + 2 retries
      wait-duration: 300ms
      enable-exponential-backoff: true
      exponential-backoff-multiplier: 2
      ignore-exceptions:
        - io.github.resilience4j.circuitbreaker.CallNotPermittedException
        - io.github.resilience4j.ratelimiter.RequestNotPermitted
        - io.github.resilience4j.bulkhead.BulkheadFullException
```

```java
@Retry(name = "QUESTION-SERVICE", fallbackMethod = "createQuizFallback")
public ResponseEntity<String> createQuiz(String category, int numQ, String title) { ... }

// same parameters, plus Throwable last - resolved by name and shape at RUNTIME
private ResponseEntity<String> createQuizFallback(String category, int numQ, String title, Throwable ex) { ... }
```

**Safe here** because all three remote calls only read or compute. Retrying
`createOrder` or `chargePayment` would double-charge — those need an idempotency
key first.

**Demo.** Stop question-service, then just two calls:

```powershell
.\demo-breaker.ps1 2
```

Watch `buffered` jump to **3 after one request** — one user request now produces
three recorded failures, so the breaker opens after 2 requests instead of 5, and
each request takes ~9.8s instead of 2s.

That cost is the lesson: **against a sustained outage, retry only makes it worse.**

---

## 6. Cache

**Essence.** The strongest protection is not calling at all. A cache hit removes
the network, the timeout, the thread and the failure mode in one step.

Resilience4j has a `resilience4j-cache` module, but it needs a JSR-107 provider and
has **no Spring Boot annotation** — it is programmatic only. In a Spring
application the standard answer is **Spring Cache + Caffeine**.

```yaml
spring:
  cache:
    type: caffeine
    cache-names: questions
    caffeine:
      spec: maximumSize=500,expireAfterWrite=60s
```

```java
@EnableCaching                                   // on the application class

@Cacheable(cacheNames = "questions", key = "#id", unless = "#result == null")
public ResponseEntity<List<QuestionWrapper>> getQuizQuestion(Integer id) { ... }

@CacheEvict(cacheNames = "questions", key = "#id")
public void evictQuizQuestions(Integer id) { }
```

Cache only what is safe to serve stale. A quiz's question list never changes, so it
is ideal; a score must never be cached.

**Demo.** Call `POST /quiz/get/{id}` twice and compare timing — second call skips
the network. Then `curl.exe http://localhost:8090/actuator/caches`.

---

## Traps that cost real time here

| Symptom | Cause |
|---|---|
| Tuned config has no effect | Breaker id is per-method and does not match `instances.<name>`. Fix with `CircuitBreakerNameResolver`. |
| `minimumNumberOfCalls` behaves as 100 | Same cause — global defaults applied silently. |
| Retry never fires | The Feign fallback **returned** a 503 instead of **throwing**. Retry triggers on exceptions. |
| `ignore-exceptions` ignored | The fallback wrapped `CallNotPermittedException` in a custom exception, so the class never matched. |
| Fallback not found at runtime | Fallback method missing the trailing `Throwable` parameter. |
| Counters reset mid-run | `spring-boot-devtools` restarted the app. Set `spring.devtools.restart.enabled: false`. |
| Health goes DOWN when breaker opens | Add `allow-health-indicator-to-fail: false`, or Eureka deregisters a healthy service. |
| Rate limiting opens the breaker | Add `RequestNotPermitted` to the breaker's `ignore-exceptions`. |

## Actuator

```
/actuator/circuitbreakers      /actuator/circuitbreakerevents
/actuator/retries              /actuator/retryevents
/actuator/ratelimiters         /actuator/ratelimiterevents
/actuator/bulkheads            /actuator/bulkheadevents
/actuator/timelimiters         /actuator/timelimiterevents
/actuator/caches
```

`demo-breaker.ps1` reads the first two. `state`, `events` or a call count are its
arguments.

## Demo runbook

Restart quiz-service first so every counter starts at zero.

| Scene | Setup | Command | Shows |
|---|---|---|---|
| 1 | question-service **up** | `.\demo-breaker.ps1 6` | RateLimiter: 5 × 201, then 429 |
| 2 | question-service **down** | `.\demo-breaker.ps1 8` | Breaker: CLOSED → OPEN, `notPermitted` climbing |
| 3 | still down, wait 10s | `.\demo-breaker.ps1 10` | HALF_OPEN probes fail → back to OPEN |
| 4 | question-service **up** | `.\demo-breaker.ps1 10` | HALF_OPEN → CLOSED, self-healed |
| 5 | down, retry enabled | `.\demo-breaker.ps1 2` | Retry: 1 request = 3 failures, ~9.8s |

Scene 5 is the strongest argument for why both retry and the breaker exist.
