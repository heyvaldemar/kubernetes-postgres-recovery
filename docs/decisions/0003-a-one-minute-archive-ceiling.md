# 3. A one-minute ceiling on archiving

- Status: accepted
- Date: 2026-10-14

## Context

PostgreSQL archives WAL a segment at a time, and a segment is 16 MB. A quiet database can take hours to fill one, and until it is full the writes in it exist only on the cluster's volumes. Lose the cluster then, and the bucket is hours behind.

## Decision

`archive_timeout: 60s`: a segment is closed and shipped after a minute even when it is not full. The static check fails on no timeout or one above five minutes.

## Consequences

- Restoring from the bucket alone loses at most about a minute of writes, plus the time the upload takes. The drill writes, waits without forcing a switch, and requires the WAL in the bucket within 90 seconds.
- A quiet database ships a mostly empty 16 MB segment each minute it has written anything; compressed, it is small, and the retention window bounds how many are kept.

## Alternatives

- **No timeout.** The bucket's lag is unbounded on a quiet database.
- **A few seconds.** A tighter bound and many more objects; at that point streaming WAL to a standby in another region is the better tool.

## How to explain this to a customer

If we lost the whole cluster, the backup in object storage is never more than about a minute behind, even at night when almost nothing is written. A tighter number is possible, and past a point a live replica in another region is the better way to buy it.
