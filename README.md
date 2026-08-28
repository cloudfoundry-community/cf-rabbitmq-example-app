# CF RabbitMQ Example App

A verification and example app for a RabbitMQ service instance bound to
a Cloud Foundry application. It exercises every protocol a
Blacksmith-deployed RabbitMQ can expose: AMQP, AMQPS, MQTT, STOMP,
Web-MQTT, Web-STOMP, the management HTTP API, and the
`x-consistent-hash` exchange type.

For each protocol the app can declare a queue, publish a message into
it, and consume a message back out, so you can confirm a binding
actually works end to end rather than just that it parses.

## Getting Started

```
$ git clone git@github.com:cloudfoundry-community/cf-rabbitmq-example-app.git
$ cd cf-rabbitmq-example-app
$ cf push rabbitmq-example-app --no-start
$ cf create-service rabbitmq standalone rabbitmq-instance
$ cf bind-service rabbitmq-example-app rabbitmq-instance
$ cf start rabbitmq-example-app
```

Then open the app's route in a browser, or start with:

```
$ export APP=https://rabbitmq-example-app.my-cloud-foundry.com
$ curl $APP/protocols
```

`/protocols` is the first thing to run against any new binding — see
[Diagnostics](#diagnostics-protocols) below.

## Bare routes

These keep their pre-consolidation contract: same method, path, request
params and status codes. They act on whichever protocol is currently
[selected](#selecting-a-protocol) (AMQP by default).

Four things behind them did change, deliberately:

- **`/env` no longer prints credentials.** It used to echo the raw `uris`
  array, passwords included; it now returns only `rabbitmq_url:
  amqp://host:port`.
- **`/queues` lists the whole vhost**, read from the management API,
  rather than only queues this app declared. Queues created by anything
  else — the MQTT plugin's per-subscription queues especially — appear
  too.
- **`GET /queue/:name` returns one message**, not every buffered message.
- **`/queues` and `POST /queues` now require the `rabbitmq_management`
  plugin**, since both consult the management API.

| Method | Path | Purpose |
|---|---|---|
| GET | `/ping` | connectivity check |
| GET | `/env` | the resolved `rabbitmq_url` (no credentials) |
| GET | `/queues` | list every queue in the vhost |
| POST | `/queues` | declare a queue (`name` param) |
| PUT | `/queue/:name` | publish a message (`data` param) |
| GET | `/queue/:name` | consume one message |

Example:

```
$ curl $APP/ping
OK
$ curl -X POST $APP/queues -d 'name=a-test-queue'
SUCCESS
$ curl -X PUT $APP/queue/a-test-queue -d 'data=Hello'
SUCCESS
$ curl $APP/queue/a-test-queue
Hello
```

## Per-protocol routes

The same five routes (`ping`, `queues`, `queue/:name`) are also
available under a fixed prefix for each protocol, so you can exercise
a specific protocol without touching the [selection](#selecting-a-protocol)
cookie. The prefix is the protocol name with underscores rendered as
hyphens:

`/amqp`, `/amqps`, `/management`, `/management-tls`, `/mqtt`, `/mqtts`,
`/stomp`, `/stomps`, `/web-mqtt`, `/web-mqtt-tls`, `/web-stomp`,
`/web-stomp-tls`

Example: `GET /stomp/queues`, `PUT /mqtt/queue/foo`.

## Everything else

| Method | Path | Purpose |
|---|---|---|
| GET | `/` | protocol selector (works with no service bound) |
| POST | `/select` | set the `rmq_protocol` cookie |
| POST | `/select-mqtt` | set the `rmq_mqtt` concurrency cookie |
| GET | `/protocols` | availability report — run this first |
| GET | `/mgmt/ping` | management API reachability |
| GET | `/mgmt/queues` | queue list with depths |
| GET | `/mgmt/queue/:name` | one queue's detail |
| GET | `/demo/consistent-hash` | consistent-hash demo status |
| POST | `/demo/consistent-hash` | run the consistent-hash demo |
| GET | `/demo/config.json` | browser demo config (no password) |
| GET | `/web-mqtt/demo` | browser page for Web-MQTT |
| GET | `/web-stomp/demo` | browser page for Web-STOMP |
| GET | `/js/mqtt.min.js` | vendored MQTT-over-WebSocket client |
| GET | `/js/stomp.umd.min.js` | vendored STOMP-over-WebSocket client |

`/`, `/select` and `/select-mqtt` are the only routes that work with no
RabbitMQ service bound; every other route returns `500` with binding
instructions until one is. That's a distinct case from the `503` a
protocol-specific route can return when a service *is* bound but the
requested protocol itself can't be resolved (see
[Diagnostics](#diagnostics-protocols)) — `500` means "nothing is
bound at all", `503` means "bound, but not this protocol".

## Selecting a protocol

The bare routes above default to AMQP, but which protocol backs them
can be changed per request or per session:

1. `?protocol=<name>` on the request, if present.
2. Otherwise the `rmq_protocol` cookie, set by `POST /select` (which
   is what the `/` page's form does).
3. Otherwise `amqp`.

An unrecognised or currently-unavailable value falls back to `amqp`
silently rather than erroring — the selector is a convenience, not a
gate.

MQTT additionally has a concurrency strategy, since a single fixed
MQTT client id would make concurrent requests to the same app
instance evict each other's connections. It resolves the same way:

1. `?mqtt=<strategy>` on the request.
2. Otherwise the `rmq_mqtt` cookie, set by `POST /select-mqtt`.
3. Otherwise the `MQTT_CONCURRENCY` environment variable.
4. Otherwise `serialized`.

Valid strategies:

| Strategy | Behaviour |
|---|---|
| `serialized` | One shared client id, mutex-guarded. Safest, but every MQTT request on an instance queues behind the others. |
| `per-queue` | One client id per queue name, so a `declare`/`consume` pair against the same queue can still find each other. Concurrent across queues. |
| `per-request` | A fresh client id on every request. Most parallel, most broker connections — and it can never see a subscription made by an earlier request, so `GET /mqtt/queue/:name` (consume) returns `409 STRATEGY-CONFLICT` under this strategy. |

## Diagnostics: `/protocols`

`/protocols` is the first thing to run against a binding — it reports,
for every protocol name, whether it's advertised by the binding
(`source: "advertised"`), computable from the binding's host and a
well-known port (`source: "derived"`), or neither. This is the real
output the app produces against a binding that advertises only `amqp`
and `management` (`spec/fixtures/vcap/tls_off.json`), trimmed to a
representative excerpt:

```json
{
  "amqp": {
    "protocol": "amqp", "host": "10.7.16.17", "port": 5672,
    "tls": false, "vhost": "0de041e6-91ba-4f55-b50f-d575ce91e2a5",
    "username": "app-user", "source": "advertised",
    "available": true, "adapter": "yes", "path": "/amqp"
  },
  "amqps": {
    "available": false,
    "reason": "amqps is not advertised in the binding and could not be derived",
    "path": "/amqps"
  },
  "mqtt": {
    "protocol": "mqtt", "host": "10.7.16.17", "port": 1883,
    "tls": false, "vhost": "0de041e6-91ba-4f55-b50f-d575ce91e2a5",
    "username": "0de041e6-91ba-4f55-b50f-d575ce91e2a5:app-user",
    "source": "derived", "available": true, "adapter": "yes",
    "path": "/mqtt"
  },
  "web_stomp_tls": {
    "available": false,
    "reason": "web-stomp over TLS has no documented default port; it must be advertised in the binding or configured explicitly",
    "path": "/web-stomp-tls"
  }
}
```

No password ever appears in this output, by design — see
[`lib/rabbitmq/endpoint.rb`](lib/rabbitmq/endpoint.rb).

Two things worth knowing when reading it:

- **MQTT's `username`** carries a `vhost:user` prefix. The MQTT plugin
  takes no vhost from the connection itself, and Blacksmith gives each
  instance its own vhost, so without the prefix an MQTT client would
  silently land on `/` instead of the bound instance's vhost.
- **`web_stomp_tls` has no derived fallback.** RabbitMQ documents no
  default TLS port for web-stomp, so it's only available when the
  binding advertises it explicitly.

## Management API: `/mgmt/*` and queue depth

| Method | Path | Purpose |
|---|---|---|
| GET | `/mgmt/ping` | management API reachability |
| GET | `/mgmt/queues` | every queue, with its current depth |
| GET | `/mgmt/queue/:name` | one queue's detail |

`/mgmt/*` is the documented short alias, but only `ping` is truly
equivalent between the two forms. `/management/ping` and
`/management-tls/ping` (from the generic per-protocol routes) do the
same reachability check as `/mgmt/ping`. The other two paths under
`/management/*`/`/management-tls/*` are a different operation, not an
alias: they come from the same generic bare-route handler every other
protocol shares, so `GET /management/queues` returns plain-text queue
names with no depth (`management.queue_names`, not `management.queues`),
and `GET /management/queue/:name` returns `501 NOT-SUPPORTED` — the
`Management` adapter doesn't implement `consume`, which is what that
generic route calls. Use `/mgmt/*` for depth and per-queue detail;
`/management/*` and `/management-tls/*` exist because every protocol
gets the same five routes, not because they mirror `/mgmt/*`.

Queue depth is what the `rabbitmq-autoscale` kit feature scales on,
and nothing in the pre-consolidation example apps exposed it.

## `/demo/consistent-hash`

Demonstrates RabbitMQ's `x-consistent-hash` exchange type: `POST
/demo/consistent-hash` (with optional `queues` and `messages` params,
2–20 and 1–10,000 respectively) declares a ring of queues bound to a
consistent-hash exchange, publishes messages across it, and reports
the resulting distribution. `GET /demo/consistent-hash` reports the
current distribution and total without publishing anything new.

This demo always uses AMQP — it deliberately ignores your
[protocol selection](#selecting-a-protocol), since `x-consistent-hash`
is an AMQP exchange-type concept with no MQTT or STOMP equivalent.

It returns `501 NOT-SUPPORTED` if the broker doesn't have the
`rabbitmq_consistent_hash_exchange` plugin enabled.

## Browser demo pages

`/web-mqtt/demo` and `/web-stomp/demo` serve small browser pages that
publish and consume messages over Web-MQTT and Web-STOMP respectively,
using the vendored `mqtt.min.js` and `stomp.umd.min.js` clients
(`GET /demo/config.json` hands them the endpoint to connect to, minus
the password — the page prompts you for credentials instead).

These two protocols are **not curl-testable end to end**: no Ruby
client speaks MQTT or STOMP over WebSocket, so the `/web-mqtt/*` and
`/web-stomp/*` routes' `declare`/`publish`/`consume` all return `501
NOT-SUPPORTED`, pointing at the corresponding demo page. Their `ping`
route still works from curl — it performs a real WebSocket upgrade
plus a protocol-level CONNECT/CONNACK (or STOMP CONNECT/CONNECTED)
exchange, which proves the listener, the subprotocol, and the
credentials, even though it can't carry a message.

## Enabling plugins

MQTT, STOMP, and their WebSocket variants (Web-MQTT, Web-STOMP) are
not enabled on a RabbitMQ instance by default — the operator has to
add them to `params.rabbitmq_plugins` in the Blacksmith deployment
manifest for the RabbitMQ forge. Consult the
[`blacksmith-genesis-kit`](https://github.com/genesis-community/blacksmith-genesis-kit)
plugin guide for the exact parameter shape; tracked for inclusion in
the kit walkthrough as
[genesis-community/blacksmith-genesis-kit#85](https://github.com/genesis-community/blacksmith-genesis-kit/issues/85).

`/protocols` cannot detect whether a plugin is enabled — it only
reports what the binding advertises versus what can be derived from a
protocol's standard port, which is pure arithmetic with no connectivity
or plugin check involved. A protocol whose plugin is disabled still
shows up as `available: true, source: "derived"`. In practice a
disabled plugin surfaces as a connection failure or timeout on that
protocol's `ping` or `declare` — a raw `502`/`504`/`500`, not a
structured "missing plugin" diagnostic. (The one exception is the
consistent-hash demo, which does detect its own plugin explicitly and
returns `501 NOT-SUPPORTED` — see
[`/demo/consistent-hash`](#democonsistent-hash) above.)

## Derived endpoints

A Blacksmith-provisioned RabbitMQ binding's `credentials.protocols`
block currently advertises only `amqp`, `amqps`, `management`, and
`management_tls`. Every other protocol this app supports — MQTT,
STOMP, and the four WebSocket/TLS variants — is **derived**: computed
from the binding's host plus that protocol's well-known port, not read
from the binding directly. `/protocols` reports which is which via its
`source` field (`"advertised"` vs `"derived"`).

This is tracked upstream as
[blacksmith-community/rabbitmq-forge-boshrelease#96](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/96).
Until the forge advertises the rest of the enabled protocols directly,
derivation is what makes them reachable at all.

## TLS

Six protocols have a TLS form: `amqps`, `management_tls`, `mqtts`,
`stomps`, `web_mqtt_tls` and `web_stomp_tls`. All six verify the
broker's certificate — chain **and** hostname — by default.

That default is not what the client gems do on their own. Bunny
(`amqps`) and `Net::HTTP` (`management_tls`) verify; the other three
gems do not:

| gem | out of the box |
|---|---|
| `bunny` | verifies |
| `net/http` | verifies |
| `mqtt` 0.7.0 | checks the hostname, never the chain |
| `stomp` 1.4.10 | `verify_mode = VERIFY_NONE`, hard-coded |
| `websocket-client-simple` 0.9.0 | verifies only if the caller asks |

Left at their defaults, `/mqtts/ping`, `/stomps/ping`,
`/web-mqtt-tls/ping` and `/web-stomp-tls/ping` all returned **200 OK**
against a broker holding a certificate from a CA in no trust store, and
three of the four did the same against a certificate issued to an
entirely different hostname. That is encryption with no
authentication, reported as a healthy binding — the one answer a
verification app must never give. `lib/rabbitmq/tls.rb` supplies the
policy those adapters were missing; `spec/integration/tls_spec.rb`
holds all three cases down against real brokers.

### Trusting a private CA

Blacksmith signs each deployment's service certificates with its own
CA, which is in no default trust store. Point OpenSSL at it:

```bash
cf set-env rabbitmq-example-app SSL_CERT_FILE /path/to/ca-bundle.pem
```

`SSL_CERT_FILE` is read by every adapter here — it is the single lever,
not an app-specific variable. The bundle must contain the platform CAs
as well if anything else in the app needs them.

### Turning verification off

```bash
cf set-env rabbitmq-example-app RABBITMQ_VERIFY_PEER false
```

Accepted values are `true`, `false`, `1`, `0` only; anything else is a
startup error rather than a guess. This disables verification for all
six TLS protocols at once and is the documented escape hatch for a lab
where adding the CA is not worth it. It is not appropriate anywhere
real — an unverified TLS connection tells you nothing about who is on
the other end.

### What `stomps` can and cannot promise

The `stomp` gem verifies only when handed a trust store through
`Stomp::SSLParams(:ts_files)`, and that code path guards each file with
`File::exists?` — not present on the Ruby this app runs on, so it
raises `NoMethodError` before a socket is opened. 1.4.10 is the newest
release, so there is no version to move to; reported upstream as
[stompgem/stomp#176](https://github.com/stompgem/stomp/issues/176).

`stomps` therefore verifies the endpoint on a connection this app opens
itself, immediately before handing off to the gem. That catches the
wrong CA, an expired certificate and the wrong hostname — the failures
that actually happen. It does **not** authenticate the connection the
messages then travel over; a broker that served a different certificate
to each connection would not be caught. `web_mqtt_tls` and
`web_stomp_tls` are checked the same way for hostname, because
`websocket-client-simple` has no hook for it, though their chain is
verified by the gem on the real connection.

### The forge renders no TLS listener for four of the six

`rabbitmq-forge-boshrelease` writes `listeners.ssl` and
`management.ssl` when `rabbitmq.tls.enabled` is set, and says nothing
about the MQTT, STOMP, Web-MQTT or Web-STOMP plugins. Those plugins do
not inherit the core listener settings. Rendering the forge's own
TLS-only configuration (`tls.enabled: true`, `dual-mode: false`)
against RabbitMQ 4.2.9 produces:

```
port 5671   amqp/ssl          <- TLS, as intended
port 15671  https             <- TLS, as intended
port 1883   mqtt              <- plaintext, still open
port 61613  stomp             <- plaintext, still open
port 15675  http/web-mqtt     <- plaintext, still open
port 15674  http/web-stomp    <- plaintext, still open
```

So "TLS only" turns off plaintext AMQP and leaves four protocols
carrying credentials in the clear, with no TLS port to move them to.
`spec/support/rabbitmq-tls.conf` shows the lines that fix it
(`mqtt.listeners.ssl.default`, `stomp.listeners.ssl.default`,
`web_mqtt.ssl.*`, `web_stomp.ssl.*`). Reported as
[rabbitmq-forge-boshrelease#99](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/99)
and fixed by [#100](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/pull/100),
merged 2026-08-28. **No forge release carries it yet** — v1.5.1 is the
newest, so a deployment on a released forge still has this gap.

The kit side has its own gap: the Blacksmith kit's OCFP feature hook is
meant to add `rabbitmq-tls` automatically, but only sees features listed
*before* `ocfp`, so with the conventional ordering it adds nothing —
[blacksmith-genesis-kit#87](https://github.com/genesis-community/blacksmith-genesis-kit/issues/87),
fixed by [#88](https://github.com/genesis-community/blacksmith-genesis-kit/pull/88)
and merged 2026-08-25. Until a kit release carries it, list
`rabbitmq-dual-mode` explicitly in the environment file.

## `instances: 1`

The manifest deploys a single instance deliberately, because of MQTT.
An MQTT client is identified by its `client_id`, which this app derives
from `CF_INSTANCE_INDEX` so that two instances cannot collide on the
broker. A `declare` (subscribe) and a later `consume` for the same
queue therefore have to land on the same instance; behind the CF router
with more than one instance they may not, and the consume would see
nothing. (This is also why MQTT's `serialized` strategy uses a mutex
scoped to a single process — see
[Selecting a protocol](#selecting-a-protocol).)

Nothing else here needs it. STOMP opens and closes a connection per
request and the queue it declares lives in the broker, so any instance
can consume it; AMQP and the management and diagnostic routes are
stateless too. The manifest cannot set instance counts per route, so
the whole app stays at `1`.

## Migrating from the MQTT/STOMP example apps

If you're moving off the standalone
`cf-rabbitmq-example-mqtt-app` or `cf-rabbitmq-example-stomp-app`:
queue names created through this app are no longer prefixed with
`test.mq.` — pass the queue name as-is.

## Stacks

The app runs on both `cflinuxfs4` and `cflinuxfs5`. `manifest.yml`
deliberately pins no `stack:` line, so each foundation applies its own
default. Every gem this app uses is pure Ruby with no native
extensions, so nothing here is stack-specific. Ruby is pinned to
`3.3.11` — the newest patch version the `ruby_buildpack` carries in
common between the two stacks.

## Verification status

**Automated verification:** the unit and integration suites
(`spec/unit`, `spec/integration`) run in CI against
`rabbitmq:3.13-management` and `rabbitmq:4.2-management` in Docker
(`docker-compose.test.yml`) — AMQP, management, MQTT, STOMP, Web-MQTT,
Web-STOMP, the consistent-hash exchange, and all six TLS protocols are
exercised there. Run `spec/support/gen-tls-certs.sh` once before
starting the brokers; the certificates it writes are git-ignored.

**Live verification:** confirmed against a Blacksmith-provisioned
instance (`rabbitmq-forge` 1.5.1, RabbitMQ 4.2.8) on a Cloud Foundry
foundation, `cflinuxfs5`, bound with `cf bind-service`:

- `/protocols` against the real binding reports `amqp` and `management`
  as **advertised** and `mqtt`, `mqtts`, `stomp`, `stomps`, `web_mqtt`,
  `web_mqtt_tls`, `web_stomp`, `management_tls` as **derived**, with
  `amqps` and `web_stomp_tls` unavailable — matching what this README
  describes.
- Round-tripped a message over **AMQP**, **STOMP** and **MQTT**: declare
  `201`, publish `201`, consume `200` with the body, `204` once drained.
- `/mgmt/queues` returned queue depths, including the MQTT plugin's own
  `mqtt-subscription-*` queue — the whole-vhost listing described above.
- `/demo/consistent-hash` distributed 12 messages across 3 queues.
- No credential appeared in any response body.

**TLS verification:** covered against real brokers by
`spec/integration/tls_spec.rb` (`rabbitmq:4.2-management`, the line the
forge deploys). All six TLS protocols round-trip or ping against a
certificate that verifies, are refused against one from an untrusted
CA, are refused against one naming a different host, and connect again
under `RABBITMQ_VERIFY_PEER=false`. See [TLS](#tls).

**TLS against a live Blacksmith instance:** verified end to end on Cloud
Foundry — `rabbitmq-forge` 1.5.1 (plus the four fixes below), RabbitMQ
4.2.8, TLS in dual mode, all twelve listeners up on the instance
(1883/5671/5672/8883/15671–15676/61613/61614).

- `/protocols` reports **four** advertised protocols with TLS on — `amqp`,
  `amqps`, `management`, `management_tls` — and derives `mqtts`, `stomps`
  and `web_mqtt_tls` on their standard TLS ports. `web_stomp_tls` stays
  unavailable, as designed.
- With the binding's private CA **untrusted**, all five reachable TLS
  protocols refuse the broker and name the reason. Four of the five
  returned `200 OK` here before `lib/rabbitmq/tls.rb` existed.
- With the CA supplied through `SSL_CERT_FILE`, all five ping and
  `amqps`, `stomps` and `mqtts` each round-trip a message.
- `/demo/consistent-hash` distributed 12 messages across 3 queues over
  **AMQPS** — `fallback_protocol` picks `amqps` when no plaintext `amqp`
  is resolvable.
- No credential appeared in any response body.

**Six upstream fixes were needed to get there**, each filed with a PR:

| what | where | state |
|---|---|---|
| bpm colocated in every plan, so the default plan can start | forge [#97](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/97) / [#98](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/pull/98) | merged, unreleased |
| TLS listeners for mqtt, stomp and the two WebSocket plugins | forge [#99](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/99) / [#100](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/pull/100) | merged, unreleased |
| `meta.cf` emitted when `route_registrar` is on, so the plan renders | forge [#101](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/101) / [#103](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/pull/103) | merged, unreleased |
| `api_url` pointed at a management listener the broker can reach | forge [#102](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/issues/102) / [#104](https://github.com/blacksmith-community/rabbitmq-forge-boshrelease/pull/104) | merged, unreleased |
| ocfp sub-features (`rabbitmq-tls`) no longer dropped by list order | kit [#87](https://github.com/genesis-community/blacksmith-genesis-kit/issues/87) / [#88](https://github.com/genesis-community/blacksmith-genesis-kit/pull/88) | merged, unreleased |
| `stomp` gem able to load a trust store at all | [stompgem/stomp#176](https://github.com/stompgem/stomp/issues/176) / [#177](https://github.com/stompgem/stomp/pull/177) | open |

The four forge fixes and the kit fix are merged to their default branches
but not in any release — forge's newest is v1.5.1 (2026-07-22). Until a
release carries them, a foundation needs a forge built from `master`.

**Still not covered:** browser execution of the two demo pages — CI proves
the vendored JS is served, not that it runs.

**Operator note:** application security groups must allow egress from
the app to the service network on the protocol ports. A default CF
install permits only DNS and 80/443, which makes every protocol fail
with a connection error despite a correct binding.
