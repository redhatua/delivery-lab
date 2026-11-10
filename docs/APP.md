# Application

FastAPI service. Every pod serves HTTP and is also one member of a Redis Streams
fan-out: a broadcast accepted by one member is acknowledged by every other
active member.

## Modules (src/messenger)

| File | Role |
| --- | --- |
| app.py | FastAPI app, lifespan, HTTP endpoints |
| consumer.py | `Member`: supervisor, heartbeat, listener, pending reclaim, test pause hook |
| store.py | All Redis calls and the Lua scripts |
| models.py | Request model, fingerprint, stream entry validation |
| status.py | Pure status calculation |
| config.py | Settings from environment |
| logs.py | JSON logging |

## Redis layout (prefix `demo` by default)

- `demo:events` stream; entry fields `event_id`, `origin`, `targets`.
- `demo:acks` stream; one entry per first business ACK.
- `demo:members` zset, score = lease expiry in ms (Redis time); `demo:member:<name>` identity hash.
- `demo:event:<id>` hash: metadata, `expected` (JSON list) and `ack:<member>` fields.
- `demo:idempotency:<sha256(key)>` hash: `event_id`, `fingerprint`.
- One consumer group per logical member, `receiver:<POD_NAME>`; consumer name is `POD_UID`.

Event and idempotency keys expire together, `RESULT_TTL` after creation, and are never extended.

## Behaviour notes

- Publication is one Lua script: idempotency check, live-member snapshot (origin excluded), XADD, event state.
- ACK commit is one Lua script: checks event exists and member is expected, writes the first ACK to the hash and the acks stream, then transport-XACKs the delivered entry. Duplicates, expired events and non-targets are transport-acked without a business ACK.
- Malformed stream entries are logged, transport-acked as rejected and skipped.
- A replay of an expired stream entry finds no event hash and is only transport-acked.
- Pending entries of the member's own group are reclaimed with XAUTOCLAIM (cursor followed to the end) after `RECLAIM_MIN_IDLE`. A replacement pod with the same name but a new UID finishes the old obligation; the ACK shows the new UID and IP.
- Replay of an identical POST returns 200 with `replayed: true`; creation returns 202.
- Streams are never trimmed during operation; clean up explicitly.
- Heartbeat overwrites the identity of a member name; a late old process could briefly
  overwrite a newer one, but deregistration is guarded by UID.

## Chat UI and live feed

The image also serves a small React app (`ui/`, built by the Dockerfile's node stage into
`/app/static`, no CDN at runtime) at `/`. It shows each broadcast as a message from its
sender, replies as they arrive (colour per pod, time and delay since the broadcast), and a
typing indicator for recipients that have not answered yet.

- `GET /ws` (websocket): pushes `hello`, `event` and `ack` messages. It reads the shared
  `demo:events` and `demo:acks` streams with plain XREAD from the moment of connection, so
  any pod can serve it and it never affects delivery. At most 8 feeds per pod.
- Recipients wait a random `REPLY_DELAY_MIN`..`REPLY_DELAY_MAX` seconds (default 1 to 4)
  before the ACK, to look like people answering. Keep the maximum below `RECLAIM_MIN_IDLE`.
  Set both to 0 to disable. Tests run with 0.
- uvicorn needs the `websockets` package to serve `/ws`; it is pinned in requirements.txt and locked in requirements.lock.
- Local UI development: `scripts/run-local.sh 3`, then `cd ui && npm install && npm run dev`.

## Test hook

`TEST_HOOKS=1` enables a one-shot pause before the ACK script. Set
`<prefix>:test:pause:<POD_NAME>` in Redis; the next recipient processing deletes it
(GETDEL), records `<prefix>:test:paused:<POD_NAME>` with its UID and sleeps forever. While
paused, that process's own reclaim loop is off, so the entry stays pending until the pod is killed.
Replacement pods find no pause key and run normally.

## Run and test without Kubernetes

    scripts/test.sh            # starts a throwaway redis container, runs all tests
    scripts/test.sh -k outage  # pass pytest arguments through
    REDIS_TEST_URL=redis://host:6379/0 scripts/test.sh   # use an existing Redis
    scripts/run-local.sh 3     # three members on ports 8100-8102

    docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t messenger .

Example:

    curl -s -X POST localhost:8100/broadcast -H 'Content-Type: application/json' \
      -H 'Idempotency-Key: demo-1' -d '{"message":"hello"}'
    curl -s localhost:8101/broadcasts/<event_id>
