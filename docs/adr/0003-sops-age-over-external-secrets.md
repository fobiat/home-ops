# 0003. SOPS and age rather than External Secrets

Status: Accepted, 2026-08-15

## Context

Secrets have to get into the cluster somehow. The two live options are encrypting them
into this repository with SOPS, or keeping them in a hosted vault and syncing them in
with External Secrets Operator.

A survey of actively maintained homelab repositories in August 2026 found the majority
have moved the other way. Five of the most active (onedr0p, buroa, szinn, auricom,
kashalls) use External Secrets with 1Password Connect and carry no SOPS config at all.
This decision goes against that.

## Decision

SOPS with age, encrypted in this repository. One age key, backed up outside the repo.

## Consequences

Good: no external dependency and no subscription. No bootstrap ordering problem, because
Flux decrypts secrets itself and there is no operator that has to be running first, and
no credential for that operator that has to arrive some other way. Everything needed to
rebuild the cluster is this repository plus one key.

Bad: rotation is manual. Encrypted blobs live in the Git history permanently, so a
compromised key means every secret it ever encrypted must be treated as exposed, not just
the current ones. Sharing a secret with anyone else is awkward, though that does not
apply to a single-operator homelab.

The key itself is the whole security model. It lives in NordPass and nowhere else that
matters. Losing it means every secret has to be regenerated from scratch.

## Alternatives

**External Secrets plus 1Password.** Better rotation, better sharing, and where the
community has gone. Rejected because it introduces a paid dependency and a bootstrap
chicken-and-egg: the operator needs a credential before it can fetch credentials, and
that first credential has to get into the cluster by some other means anyway.

**The hybrid joryirving uses**, SOPS for the bootstrap-critical values and External
Secrets for everything downstream, is the honest answer if a vault is ever added. It
solves the ordering problem properly. Not worth two mechanisms yet, per rule 11.
