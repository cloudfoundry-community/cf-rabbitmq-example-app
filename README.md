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

These are unchanged from the app's pre-consolidation versions and keep
their exact contract: method, path, request format, response format,
and status codes. They act on whichever protocol is currently
[selected](#selecting-a-protocol) (AMQP by default).

| Method | Path | Purpose |
|---|---|---|
| GET | `/ping` | connectivity check |
| GET | `/env` | the resolved `rabbitmq_url` (no credentials) |
| GET | `/queues` | list queues declared so far |
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
RabbitMQ service bound; every other route returns `503` until one is.

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

`/mgmt/*` is the documented short alias; the same three endpoints also
exist at `/management/*` and `/management-tls/*` via the per-protocol
route prefixes. Both forms are intentional and neither redirects to
the other.

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

Until a plugin is enabled, `/protocols` reports its protocols as
unavailable (or `adapter: "none"`/`declare` failing with a
missing-plugin error), rather than the app silently pretending they
work.

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

## `instances: 1`

The manifest deploys a single instance deliberately. MQTT and STOMP
each keep their subscription state on the live TCP connection to one
broker session — `declare` (subscribe) and `consume` (read) have to
land on an app instance that can still see that same session. With
more than one instance, a `declare` and a later `consume` for the same
queue can land on different instances behind the CF router with no
shared state between them, and the consume would see nothing. (This is
also why MQTT's `serialized` strategy uses a mutex scoped to a single
process — see [Selecting a protocol](#selecting-a-protocol).) AMQP,
STOMP-over-plain-TCP requests that stay within one connection, and the
stateless management/diagnostic routes don't have this restriction,
but the manifest doesn't split instance counts per route, so it stays
at `1` for the whole app.

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
`rabbitmq:3.13-management` in Docker
(`docker-compose.test.yml`) — AMQP, management, MQTT, STOMP, Web-MQTT,
Web-STOMP, and the consistent-hash exchange are all exercised there.

**Not yet done:** this app has **not** been verified against a live
Blacksmith-provisioned RabbitMQ instance. The current
`blacksmith-genesis-kit` RabbitMQ forge pin is `rabbitmq-forge`
**1.2.5**; behaviour against that forge — including whether its
advertised-protocol set matches what's assumed above, and how
`/protocols`'s derivation looks against a real binding — is expected
but unconfirmed.
