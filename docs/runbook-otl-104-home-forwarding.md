# Home forwarding limits (OTL-104 / CTC-5602)

Ryan approved keeping the home Loki and Tempo sinks, including telemetry from personal tools. The cloud collector also forwards to both home sinks. The personal-OS filter applies only to ClickHouse pipelines; do not add it to the home exporters.

## Limits

The home config in this repository sets Loki's ingestion rate to 16 MB/s, burst to 32 MB, and structured metadata per record to 256 KB. These cover the observed 4 MB/s rate rejection and a 161,111-byte metadata record rejected at the former 65,536-byte cap. `ingester.max_chunk_age: 4h` gives a two-hour out-of-order window for delayed personal-OS batches; a `codex_exec` record arrived 67 minutes behind its stream and was rejected under the one-hour default window. `tempo.yaml` sets the OTLP gRPC receiver's maximum message to 16 MiB after a 4 MiB rejection.

The cloud box's `/etc/otel-box/collector-config-box.yaml` is host-local and is not generated from this repository. Its `otlp/tempo` exporter uses a 30-second timeout, a queue of 1,000 requests, and retry with a five-minute elapsed limit. Its `batch/tempo` processor has `send_batch_size: 64`, `send_batch_max_size: 64`, and `timeout: 1s`. That processor is last in the `traces`, `traces/cloudflare`, `traces/platform`, and `traces/gateway` pipelines, which send to home Tempo. Keep the ClickHouse pipelines and their personal-OS filter unchanged.

## Validate and roll

On the home host, validate `loki-config.yaml` with the running Loki image's `-verify-config` flag and `tempo.yaml` with Tempo's `-config.verify=true`. Recreate only `otel-loki` and `otel-tempo`; a restart alone can leave single-file bind mounts pinned to an old inode. Check both `/ready` endpoints for HTTP 200.

On the cloud box, validate all four merged collector configs with the pinned `otelcol-contrib validate` command from the running image before recreating only `otel-collector`. Check that it is running and that the four home Tempo pipelines include `batch/tempo` in the loaded config. Keep a timestamped backup of the host-local overlay before editing it.

After the last recreate, inspect collector `Dropping data` events by `otelcol.component.id` for `otlp_http` (home Loki) and `otlp/tempo` (home Tempo) over a continuous 30-minute window. Other exporters have separate failures and must be counted separately. Send a fresh personal-OS test log through the cloud collector and query that exact marker from home Loki. A successful ingestion response alone does not prove storage or ClickHouse filtering.

The 2026-10-12 live rollout backups are `/home/rozich/otel-stack/.config-backups/20261012T191503Z`, `/home/rozich/otel-stack/loki-config.yaml.backup-20261012T191908Z`, `/home/rozich/otel-stack/loki-config.yaml.backup-20261012T1938Z`, and `/etc/otel-box/collector-config-box.yaml.backup-20261012T191536Z` on their respective hosts. The cloud overlay must be reconciled with those values during any rebuild because it is not in this Git repository.
