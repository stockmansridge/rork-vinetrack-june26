# Sync Change Request — mandatory template

**Change ID / issue:**  
**Author / reviewers:**  
**Date / source HEAD before edit:**  
**Reason for change / original failing example:**  
**Affected domain IDs** (from `sync-domain-contracts-v1.json`):  
**Old released baseline binaries:** iOS 3.1.8 ___; Android 3.1.8 ___; current 3.1.9 ___
**Affected main / branches and unresolved PRs:**  
**Live backend RPC hash + deployment owner / permission:**  

## 1. Data model — field-by-field review

| Table / RPC / JSON path | Wire key | PG type / nullable | Unit / semantics of missing, null, 0 | Old client read/write | New iOS encoder+decoder | New Android serializer+parser | Portal reader/writer | Authority/revision/merge | Status |
|---|---|---|---|---|---|---|---|---|---|
| | | | | | | | | | UNVERIFIED |

Document nested JSON arrays, enum case, time zone, identifiers, original planned vs actual data and unknown keys. No placeholder "same on both" without fixture evidence.

## 2. State transitions and durable replay

**Original account+vineyard scope, entity ID, operation/idempotency key:**  
**Local persistence store and atomic write:**  
**Parent-first dependency and server readback:**  
**Retryable / held / unknown / conflict classes:**  
**Exactly which matching receipt clears local pending state:**  
**Latest edit vs old ack guard:**  
**Soft deletion / tombstone / hard-stop impact:**  
**Read-only entitlement and old-session recovery:**  
**What a second independent operation may safely start:**  

## 3. Must-pass test matrix

- [ ] Frozen iOS 3.1.8 decoder/encoder round trip
- [ ] Frozen Android 3.1.8 decoder/encoder round trip
- [ ] New iOS + Android encode/decode identical canonical fields (not merely numerical outputs)
- [ ] Portal create/read/edit and actual backend RPC/DDL field + permission test
- [ ] Device A -> server receipt -> device B; B -> server receipt -> A
- [ ] Create, edit, delete / explicit tombstone, partial paging
- [ ] Offline queue -> force close -> reopen -> same-ID retry
- [ ] HTTP timeout before and after committed insert; 401/403, parse fail, 500
- [ ] Newer local edit while older upload response arrives
- [ ] Two-device conflict retains BOTH original authored values
- [ ] Vineyard/account incarnation switch; revoke membership; expired entitlement
- [ ] Trip chain: create/occurrence/activate/route/spray/tank session/operator actuals/end
- [ ] Independent new Trip vs retained same/other-parent starts
- [ ] Exact matched receipt and all per-record diagnostic counts
- [ ] Native XCTest, Android JVM/instrumentation and actual TestFlight/Play in-place updates
- [ ] Strict inventory and sync-contract gate
- [ ] Latency/traffic/memory bounded on 1x,10x,100x histories

## 4. Migration & rollout

**Backward-compatible additive first / deployed version:**  
**Authorised migration owner / rollback contract:**  
**Existing pending local data survival across app update:**  
**Release build commit + source fingerprint:**  
**Results / raw test logs / failure list:**  
**Original-device evidence / operator acceptance:**  
**Open blockers and rollback trigger:**  

**Approval:** No release checkbox or register certification is permitted based on source parsing, CI compile, backend existence alone, screenshots without server verification, or newly installed empty-device tests. No destructive unblocking without exact original record reconciliation.
