# OneDesk Automation — Testing Plan

**Date:** 2026-09-20  
**Status:** Draft for review  
**Design baseline:** `AUTOMATION_EXECUTION_PLAN.md` and `AUTOMATION_FLOW_AND_COMPONENT_GUIDE.md` (20 Sep 2026)

## 1. Objective

Prove that OneDesk Automation is functionally correct, batch-safe, auditable, recoverable, and independent across the Automation DB and application boundaries.

The plan validates this pipeline:

```text
Producer
  -> AutomationTriggerQueueDelta
  -> AutomationTriggerQueueSummary
  -> AutomationTriggerQueueRule
  -> AutomationTriggerQueueTrigger
  -> AutomationExecutions
  -> AutomationTriggerQueueAction
  -> AUTOMATION or APPLICATION executor
  -> AutomationActionHistories
```

It also validates that Automation-caused field changes create a new normal Ticket event and a new, traceable automation cycle.

## 2. Scope and Assumptions

### Included trigger scenarios

| Automation type | Event |
|---|---|
| Ticket Creation | `TICKET_CREATED` |
| Ticket Update | `STATUS_CHANGED` |
| Ticket Update | `PRIORITY_CHANGED` |
| Ticket Update | `GROUP_CHANGED` |
| Ticket Update | `ASSIGNEE_CHANGED` |
| Ticket Update | `REQUESTER_REPLIED` |
| Ticket Update | `AGENT_REPLIED` |
| Schedule Trigger | `SCHEDULE_DUE` produced by the Schedule Scanner |

### Initial condition-field scope

Testing uses only three fields from each supported object/source. The authoritative catalog is in `AUTOMATION_COMMON_RULE_TEST_CONFIGURATION.md`.

### Excluded from this first plan

- production performance SLA numbers;
- a final audit-retention duration;
- complex nested condition expressions;
- manual replay UI;
- deployment and rollback tests;
- direct modification of current Go or SQL product source.

## 3. Test Environment and Fixtures

Create deterministic fixtures with stable logical aliases rather than hard-coded production IDs:

```text
CONTACT_ACTIVE
CONTACT_INACTIVE

COMPANY_VIP
COMPANY_STANDARD

GROUP_DEFAULT
GROUP_ESCALATION
GROUP_VIP

AGENT_AVAILABLE
AGENT_UNAVAILABLE
AGENT_OUTSIDE_GROUP

TICKET_OPEN_LOW
TICKET_PENDING_HIGH
TICKET_RESOLVED_OLD
```

Use timestamps in UTC (`DATETIMEOFFSET`) and freeze the test clock where schedule comparisons are asserted.

Every test operation must have a unique `OperationId`. Every activity used as an event source must have a stable source identity so duplicate collection can be tested.

## 4. Test Layers

### 4.1 Configuration validation

Validate before runtime processing:

- event type is supported by the selected automation type;
- each field code belongs to the declared object/source;
- operator is compatible with the field type;
- reference values resolve to active entities where required;
- action target is writable;
- `ExecutionTarget` matches the action type;
- `SortOrder` is deterministic;
- inactive or deleted rules are not eligible;
- invalid configuration fails without creating runtime queue rows.

### 4.2 Stored-procedure/component tests

Test each stage independently:

1. Collector claims activity/schedule input in bounded batches.
2. Delta rows contain correct `FromValue`, `ToValue`, actor, event, and lineage.
3. Summary groups one Ticket operation into one evaluation unit.
4. Rule processor resolves current committed state and event transition state correctly.
5. Block aggregation implements `ALL` and `ANY` correctly.
6. Trigger processor implements `FIRST_MATCH` and `ALL_MATCH` deterministically.
7. Execution/action generation is idempotent.
8. DB field processor performs set-based mutation and batch audit writes.
9. Application claim is atomic and lease-aware.
10. Completion/failure aggregates parent execution status correctly.

### 4.3 End-to-end integration tests

Run every event from business mutation through audit output. Do not seed later queue stages directly for end-to-end tests.

### 4.4 Non-functional tests

Cover batch boundaries, concurrency, deadlock retry, worker crash, idempotency, audit retention, and queue cleanup.

## 5. Event-Trigger Test Matrix

Each row requires one positive test, one negative-condition test, one duplicate-input test, and one disabled-rule test.

| ID | Event | Positive setup | Expected selected action |
|---|---|---|---|
| EVT-01 | `TICKET_CREATED` | Urgent Portal Agent ticket | Assign escalation group and set priority according to the first selected creation rule |
| EVT-02 | `STATUS_CHANGED` | `OPEN -> RESOLVED`, priority `HIGH` | Route to resolution review |
| EVT-03 | `PRIORITY_CHANGED` | `HIGH -> URGENT` | Assign escalation group |
| EVT-04 | `GROUP_CHANGED` | Any group -> VIP group | Assign available VIP agent |
| EVT-05 | `ASSIGNEE_CHANGED` | Unassigned/other -> available agent | Set status `OPEN` when required by rule |
| EVT-06 | `REQUESTER_REPLIED` | Ticket currently `PENDING` | Set status `OPEN` |
| EVT-07 | `AGENT_REPLIED` | Ticket currently `OPEN` | Set status `PENDING` |
| EVT-08 | `SCHEDULE_DUE` | Resolved and unchanged for at least 48 hours | Set status `CLOSED` |

Additional event assertions:

- wrong `FromValue` does not match;
- wrong `ToValue` does not match;
- `NULL FromValue` behaves as wildcard only when configured as wildcard;
- current conditions use the latest committed Ticket state;
- `REQUESTER_REPLIED` and `AGENT_REPLIED` preserve the correct actor type;
- a failed business mutation produces no automation event.

## 6. Selection Semantics

### 6.1 `FIRST_MATCH`

Seed three active `TICKET_CREATED` rules with `SortOrder` 10, 20, and 30. Make all three match.

Expected:

```text
3 AutomationEvaluations: IsMatch = 1
1 AutomationEvaluation:  IsSelected = 1 (SortOrder 10)
1 AutomationTriggerQueueTrigger
1 AutomationExecution
actions only for the selected rule
```

Also test a non-matching rule at SortOrder 5 followed by matching rules at 10 and 20. SortOrder 10 must be selected.

### 6.2 `ALL_MATCH`

Seed at least two matching rules for `PRIORITY_CHANGED`.

Expected:

```text
both evaluations selected
two executions
both action sets generated
deterministic ordering retained in audit
```

## 7. Condition and Operator Tests

For every field in the initial catalog, test at least one supported positive and negative operator.

Minimum operator coverage:

| Field class | Operators |
|---|---|
| Enum/reference | `EQUALS`, `NOT_EQUALS`, `IN`, `IS_EMPTY`, `IS_NOT_EMPTY` |
| String | `EQUALS`, `CONTAINS`, `NOT_CONTAINS`, `IS_EMPTY` |
| Boolean | `EQUALS` |
| Number/time | `GT`, `GTE`, `LT`, `LTE`, `EQUALS` |
| Event transition | `CHANGED`, `CHANGED_FROM`, `CHANGED_TO` |

Test `ALL` and `ANY` blocks separately. Audit must preserve actual, previous, and expected values even when the result is not matched.

## 8. Action Tests

### 8.1 AUTOMATION-target field actions

Test:

```text
SET_STATUS
SET_PRIORITY
ASSIGN_GROUP
ASSIGN_AGENT
SET_CUSTOM_FIELD
```

For every action assert:

- queue row is atomically claimed;
- target validation happens before mutation;
- mutation is applied once;
- unchanged target becomes `NO_OP/SUCCESS` and does not generate a duplicate field-change event;
- `OUTPUT deleted/inserted` values equal audit `FromValue/ToValue`;
- `TicketActivityLogs.AutomationExecutionId` points to the causing execution;
- history is append-only;
- queue status becomes terminal.

### 8.2 APPLICATION-target actions

Test at least:

```text
SEND_NOTIFICATION
SEND_EMAIL
WEBHOOK
```

Use fakes/stubs for external delivery. Assert that the application receives only the action contract and does not need rule/block configuration.

## 9. Batch and Set-Based Processing Tests

Run every high-volume procedure with batch sizes `1`, `2`, a normal test size such as `100`, and a remainder case such as `205 rows / batch 100`.

Required assertions:

- no row is skipped or processed twice;
- each call claims no more than `@BatchSize`;
- ordering is deterministic;
- multiple Tickets may be updated by one set-based statement;
- audit/activity rows are inserted from batch result sets, not per-row procedure calls;
- a failure for one incompatible action is isolated and does not silently lose other claimed rows;
- transactions end before any external application work begins.

For `ganymede_automationFieldActionProcessBatch`, seed multiple action types and multiple actions for the same Ticket. Verify deterministic processing by `TicketId`, action sequence, and queue ID.

Static review gate: reject cursor-based, per-row `WHILE`, and `EXEC procedure-per-row` implementations in high-volume stages.

## 10. Concurrency and Lease Tests

### Atomic application claim

Start at least four concurrent workers claiming the same READY pool.

Expected:

- claimed ID sets are disjoint;
- total claimed equals eligible rows;
- each row has one `ClaimedBy`, `ClaimedAt`, and `LeaseUntil` for the active lease;
- `AttemptCount` increments exactly once per claim/reclaim.

### Worker crash

1. Worker A claims an action.
2. Worker A stops without reporting a result.
3. Before lease expiry, Worker B cannot claim it.
4. After expiry, Worker B can reclaim it.
5. A stale result from Worker A cannot overwrite Worker B's ownership/result.

### External side-effect idempotency

Simulate external success followed by worker crash before completion is recorded. On retry, the stable `IdempotencyKey` must prevent a second effective send/call.

## 11. Execution Result Aggregation

| Child action state | Expected execution state |
|---|---|
| Any `READY` or `PROCESSING` remains | `PROCESSING` |
| All terminal and all success/no-op | `COMPLETED` |
| All terminal with success and fail | `PARTIAL_FAILED` |
| All terminal and all fail | `FAILED` |

Re-run aggregation for the same terminal results to prove idempotency.

## 12. Ticket Creation Visibility

Test all cases:

| Case | Expected |
|---|---|
| No active creation rule | Visible with `NO_RULE` |
| Rules evaluated but none match | Visible with `NO_MATCH` |
| Selected actions still pending | Hidden |
| All selected actions successful | Visible with `SUCCESS` |
| Mix success/fail | Visible according to approved terminal policy with `PARTIAL_FAILED` |
| All fail | Visible according to approved terminal policy with `FAILED` |

For `ALL_MATCH`, visibility waits for all directly selected creation executions. It must not wait for descendant update automations created by cascade.

## 13. Cascade and Loop Protection

Positive chain:

```text
Rule A: STATUS OPEN -> SET_PRIORITY HIGH
Rule B: PRIORITY HIGH -> ASSIGN_GROUP VIP
Rule C: GROUP VIP -> ASSIGN_AGENT AGENT_AVAILABLE
```

Expected:

- three separate automation cycles;
- `ParentExecutionId`, `RootExecutionId`, and `ExecutionDepth` form one chain;
- every Ticket mutation has its causing `AutomationExecutionId`;
- no in-memory shortcut bypasses the normal pipeline.

Loop case:

```text
A sets Priority HIGH
B sets Priority LOW
```

Expected: processing stops at `MaxExecutionDepth`, records a blocked/terminal reason, and does not continuously requeue.

## 14. Schedule Scanner Tests

- exactly-at-threshold comparison;
- just-before and just-after threshold;
- UTC and agent timezone do not change stored comparison semantics;
- duplicate scans do not create duplicate logical events;
- scan uses batch limits;
- schedule scanner only produces Delta/event work and does not evaluate rules itself;
- Ticket state is revalidated when the event is processed;
- already-closed Ticket results in non-match or no-op rather than another mutation.

## 15. Audit and Retention Tests

After successful processing and queue cleanup, reconstruct:

```text
Ticket activity
  -> evaluated trigger
  -> rule/block result
  -> selected trigger
  -> execution
  -> action attempt/result
  -> resulting Ticket mutation
```

Verify that:

- match and non-match decisions are both retained according to policy;
- matched-but-not-selected is distinguishable;
- action history cannot be updated after insert except through an explicitly approved correction process;
- cleanup deletes only rows older than cutoff in bounded batches;
- child audit detail is purged before/with its parent without leaving broken retained traces;
- queue retention does not delete audit;
- audit retention does not delete active queue work.

## 16. Failure and Recovery Tests

Inject failures at each boundary:

- after claim but before processing;
- after rule audit but before QueueTrigger creation;
- after execution creation but before action generation;
- after Ticket mutation but before queue completion;
- after external side effect but before completion report;
- deadlock victim during a DB batch;
- invalid target entity/reference;
- action retry exceeds `@MaxRetry`.

For each injection, assert the safe restart behavior, absence of duplicate effective mutation, and presence of a diagnosable terminal/error record.

## 17. Test Execution Phases

1. Validate configuration catalog and fixture prerequisites.
2. Run component tests for each stage.
3. Run one positive end-to-end scenario per event.
4. Run negative/operator/disabled/deleted scenarios.
5. Run `FIRST_MATCH` and `ALL_MATCH` suites.
6. Run field-action and application-action suites.
7. Run cascade, visibility, and schedule suites.
8. Run batch-boundary tests.
9. Run concurrent worker/lease/idempotency tests.
10. Run audit cleanup and queue cleanup tests.
11. Run failure-injection and recovery tests.
12. Publish evidence and unresolved findings.

## 18. Evidence Required Per Test

Record:

```text
TestCaseId
OperationId
TicketId
source ActivityLogId or ScheduleOccurrenceKey
DeltaId / SummaryId
EvaluationId(s)
ExecutionId(s)
QueueActionId(s)
ActionHistoryId(s)
expected vs actual Ticket state
elapsed time and batch size for batch tests
worker IDs and leases for concurrency tests
```

Do not declare a test passed from Ticket state alone. The full pipeline and audit invariants must also match.

## 19. Exit Criteria

Testing is accepted only when:

1. Every listed event has positive, negative, duplicate, and disabled-rule coverage.
2. All initial object fields resolve and evaluate correctly.
3. `FIRST_MATCH` and `ALL_MATCH` produce exact evaluation/selection counts.
4. All high-volume DB stages pass batch-boundary tests without row-by-row processing.
5. Concurrent workers never own the same live lease.
6. external retries are protected by idempotency.
7. execution aggregation returns correct terminal status.
8. Ticket Creation cannot remain hidden indefinitely.
9. cascade lineage is complete and loops are bounded.
10. audit remains reconstructable after queue cleanup.
11. known failures and performance limits are documented before production rollout.

