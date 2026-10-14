# 2. A synchronous standby, required

- Status: accepted
- Date: 2026-10-14

## Context

With asynchronous replication a commit is acknowledged when the primary has it. If the primary dies before a standby receives it, the promoted standby does not have it, and the client was told it was saved.

## Decision

`synchronous: {method: any, number: 1, dataDurability: required}`: a commit is acknowledged once any one of the two standbys has it. When no standby can confirm, writes wait instead of being acknowledged by the primary alone.

## Consequences

- Every write pays one round trip to the nearest standby. On one kind node that is nothing; across zones it is the zones' latency.
- With both standbys down, writes stop. That is the point of `required`: the alternative is acknowledging writes that a second failure would lose. CloudNativePG's `preferred` makes the other choice.
- The drill kills the primary while a client writes every 200 ms and checks that every write the client saw acknowledged is on the new primary.

## Alternatives

- **Asynchronous.** Lowest latency; the last few hundred milliseconds of acknowledged writes can go with the primary.
- **`dataDurability: preferred`.** Synchronous while a standby is there, asynchronous when none is: available, and silently weaker exactly when things are already failing.
- **Two synchronous standbys.** Survives two losses at once; every write waits for both.

## How to explain this to a customer

When the application is told a payment was saved, it is on two servers before it hears that. If the main server dies a millisecond later, the copy that takes over has it. The price is a little latency on every write, and if both copies are gone at once, the database stops taking writes rather than take ones it could lose.
