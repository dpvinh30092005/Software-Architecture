# Observability stack

Prometheus scrapes the four Spring services, Grafana draws them, Zipkin collects
the traces the services were already sending to a port with nothing behind it.

## Start

```powershell
cd "D:\Software Architecture\Monolithic"
docker compose -f observability/compose.yml up -d
```

| | URL | Notes |
|---|---|---|
| Prometheus | http://127.0.0.1:9090 | Status → Targets should show 4 UP |
| Grafana | http://127.0.0.1:3000 | No login, datasource already wired |
| Zipkin | http://127.0.0.1:9411 | Stops the "Dropped N spans" log noise |

> Use **127.0.0.1**, not `localhost`. On this machine `localhost` resolves to the
> IPv6 address first and the published ports are not reachable that way - the same
> thing that made Postman time out against a service that was plainly running.

Stop with `docker compose -f observability/compose.yml down`, add `-v` to wipe
the stored metrics too.

## First check

Start the Spring services, then open **http://127.0.0.1:9090/targets**.
All four must be `UP`. If a target is `DOWN`:

| Cause | Fix |
|---|---|
| Service not running | Start it |
| Wrong port | `prometheus.yml` expects quiz 8090, question 8081, gateway 8765, eureka 8761 |
| `connection refused` to `host.docker.internal` | Docker Desktop must be running; on Linux the `extra_hosts` line in compose.yml provides it |
| 404 on `/actuator/prometheus` | `prometheus` missing from that service's `management.endpoints.web.exposure.include` |

## A dashboard

Grafana → Dashboards → New → Import → search grafana.com for **"Resilience4j"**
and import a community dashboard, or build panels from the queries below.
Community dashboards often assume older metric names, so check the panels
against `http://127.0.0.1:8090/actuator/prometheus` if one comes up empty.

## The queries that matter

Circuit breaker state. One series per state, value 1 for the state it is in:

```promql
resilience4j_circuitbreaker_state{application="quiz-service", name="QUESTION-SERVICE"}
```

Failure rate as Resilience4j itself computes it (-1 means not enough calls yet):

```promql
resilience4j_circuitbreaker_failure_rate{name="QUESTION-SERVICE"}
```

Calls per second, split by outcome — successful / failed / ignored:

```promql
rate(resilience4j_circuitbreaker_calls_seconds_count{name="QUESTION-SERVICE"}[1m])
```

Calls the breaker refused outright. This is the one that proves it is working:

```promql
rate(resilience4j_circuitbreaker_not_permitted_calls_total{name="QUESTION-SERVICE"}[1m])
```

Rate limiter permits left in the current window — watch it walk down 5→0:

```promql
resilience4j_ratelimiter_available_permissions{name="QUESTION-SERVICE"}
```

Bulkhead slots free:

```promql
resilience4j_bulkhead_available_concurrent_calls{name="QUESTION-SERVICE"}
```

Retries, by outcome. `failed_with_retry` climbing means retry is burning
attempts without helping:

```promql
rate(resilience4j_retry_calls_total{name="QUESTION-SERVICE"}[1m])
```

Call latency p95 — the number that drops from ~3s to ~0s when the breaker opens:

```promql
histogram_quantile(0.95,
  rate(resilience4j_circuitbreaker_calls_seconds_bucket{name="QUESTION-SERVICE"}[1m]))
```

## Grafana is for the slide, not for the live demo

Prometheus scrapes every 5 seconds here (default is 15). A circuit breaker flips
state in under a second, so the graph always shows the change **after** it
happened and cannot be tied to an individual call.

Use `demo-breaker.ps1` when presenting — it prints the breaker state after every
single call. Use Grafana for the screenshot that shows the system is monitored,
and for anything running longer than a few minutes.

## Memory

Roughly 1.2 GB for all three containers, on top of Postgres and the four Spring
services. On a 16 GB machine that is fine, but do not leave it running while
building.
