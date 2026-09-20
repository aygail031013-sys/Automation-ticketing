# OneDesk Automation — Flow and Component Guide

**Purpose:** Explain how the OneDesk Automation engine works, why each table/stage exists, and how it relates to the existing Tridens trigger engine.

---

# 1. Core Concept

OneDesk Automation is a **data-driven automation engine**.

The engine does not execute everything immediately inside the request that creates/updates a Ticket.

Instead:

```text
Business event
    -> normalized queue
    -> rule evaluation
    -> trigger selection
    -> action dispatch
    -> action execution
    -> audit
```

This separation provides:

- batch processing
- retry capability
- clear ownership
- auditability
- deterministic `FIRST_MATCH` / `ALL_MATCH`
- controlled cascading
- low coupling between Automation and application

---

# 2. Main Pipeline

```text
TicketActivityLogs / Schedule Scanner
                  |
                  v
     AutomationTriggerQueueDelta
                  |
                  v
    AutomationTriggerQueueSummary
                  |
                  v
      AutomationTriggerQueueRule
                  |
                  v
    AutomationTriggerQueueTrigger
                  |
                  v
         AutomationExecutions
                  |
                  v
     AutomationTriggerQueueAction
                  |
         +--------+--------+
         |                 |
         v                 v
   DB Automation       Application
   field actions       app actions
         |                 |
         +--------+--------+
                  |
                  v
       AutomationActionHistories
```

---


# 2A. Batch Is a Core Engine Rule

OneDesk Automation is designed as a batch engine, not a row-by-row trigger executor.

Every high-volume stage follows:

```text
claim batch
    ->
set-based processing
    ->
batch output
    ->
next stage
```

Examples:

```text
Delta batch
    -> Summary batch

Summary batch
    -> Rule evaluation batch

Rule results
    -> Trigger selection batch

Action queue batch
    -> DB field updates batch
```

Avoid:

```text
FOR EACH queue row
    EXEC one stored procedure
```

This matters because Tickets and Ticket fields are active tables. Small deterministic batches reduce lock duration, round trips, and deadlock probability.

For field actions, the preferred pattern is:

```text
atomic claim
    ->
#ClaimedActions
    ->
set UPDATE joined to #ClaimedActions
    ->
OUTPUT deleted/inserted values
    ->
batch TicketActivityLogs
    ->
batch AutomationActionHistories
```


# 3. Stage 1 — Event Producer

There are two producers.

## 3.1 Ticket event

Examples:

```text
Ticket created
Ticket updated
Public reply
Customer reply
Automation changes a Ticket field
```

These produce:

```text
TicketActivityLogs
```

The collector converts history into Automation queue data.

## 3.2 Schedule Trigger

Schedule Trigger exists mainly as a separate UI/configuration category.

It can expose time-related conditions.

The Schedule Scanner only produces a normal Automation event/delta.

It does not have its own rule engine.

---

# 4. Stage 2 — Delta

`AutomationTriggerQueueDelta`

Purpose:

> Store the raw changed/current values required by Automation evaluation.

Typical data:

```text
TicketId
EventType
FieldSource
FieldCode
FromValue
ToValue
```

Example:

```text
DEFAULT_PRIORITY
NORMAL -> HIGH
```

or:

```text
DEFAULT_STATUS
OPEN -> PENDING
```

This stage corresponds to Tridens `tbl_TriggerQueueDelta`.

Delta means:

> Something relevant happened to this entity.

In OneDesk, the entity is a Ticket.

---

# 5. Stage 3 — Summary

`AutomationTriggerQueueSummary`

Purpose:

> Normalize related deltas into one Automation event/evaluation unit.

Example:

One API update changes:

```text
Priority NORMAL -> HIGH
Status OPEN -> PENDING
Group NULL -> VIP
```

These can belong to one:

```text
OperationId
```

The Summary represents:

```text
one Ticket
one business operation
one Automation event
```

This corresponds to Tridens `tbl_TriggerQueueSummary`.

---

# 6. Stage 4 — Rule

`AutomationTriggerQueueRule`

Purpose:

> Evaluate configured Rules against the normalized Ticket event/state.

Configuration example:

```text
Priority = HIGH
Status = PENDING
CustomerType = VIP
```

Rule evaluation understands operators such as:

```text
EQUALS
NOT_EQUALS
CONTAINS
IN
GT
GTE
LT
LTE
CHANGED
CHANGED_FROM
CHANGED_TO
IS_EMPTY
IS_NOT_EMPTY
```

This stage corresponds to Tridens `tbl_TriggerQueueRule`.

---

# 7. Rule vs Audit

Queue Rule is not permanent audit.

For long-term traceability, the evaluator copies the decision into:

```text
AutomationEvaluationRules
```

Why both?

```text
AutomationTriggerQueueRule
    = processing

AutomationEvaluationRules
    = audit
```

Queue rows may later be cleaned or archived.

Audit must remain available.

---

# 8. Stage 5 — Block

Automation Rules can be grouped into logical Blocks.

Example:

```text
Block 1
    Priority = HIGH
    AND
    Status = PENDING

Block 2
    CustomerType = VIP
```

The engine evaluates:

```text
Rule -> Block
```

Persistent block audit is stored in:

```text
AutomationEvaluationBlocks
```

---

# 9. Stage 6 — Trigger

`AutomationTriggerQueueTrigger`

Purpose:

> Represent a Trigger that passed Rule/Block evaluation and survived execution-mode selection.

This stage is important.

A Trigger can be:

```text
MATCHED
```

but not:

```text
SELECTED
```

Example:

```text
ExecutionMode = FIRST_MATCH

Trigger A   MATCH   SortOrder 10
Trigger B   MATCH   SortOrder 20
Trigger C   MATCH   SortOrder 30
```

Evaluation audit:

```text
A IsMatch=1 IsSelected=1
B IsMatch=1 IsSelected=0
C IsMatch=1 IsSelected=0
```

Only A becomes an executable selected trigger.

For:

```text
ALL_MATCH
```

A/B/C are all selected.

This stage corresponds to Tridens `tbl_TriggerQueueTrigger`.

---

# 10. Why `AutomationExecutions` Exists

`AutomationExecutions` is not a replacement for QueueTrigger.

QueueTrigger is pipeline state.

Execution is durable business state.

Example:

```text
QueueTrigger
    = Trigger selected during this batch

AutomationExecution
    = permanent occurrence that this Trigger was actually executed for this Ticket
```

Execution supports:

- audit
- Ticket Creation visibility
- application action linkage
- schedule execution history
- cascade lineage

---

# 11. Evaluation Audit

`AutomationEvaluations`

Stores:

```text
Ticket
Trigger
event
execution mode
sort order
match result
selected result
```

It answers:

> Which automation rules were checked against this Ticket?

---

# 12. Rule Audit

`AutomationEvaluationRules`

Stores:

```text
FieldCode
Operator
FromValue
ToValue
ExpectedValue
IsMatch
```

It answers:

> Why did this trigger match or fail?

Example:

```text
Priority
Operator: EQUALS
Actual: HIGH
Expected: HIGH
Result: MATCH
```

---

# 13. Stage 7 — Action Queue

`AutomationTriggerQueueAction`

Purpose:

> Hold executable work.

This corresponds to Tridens `tbl_TriggerQueueAction`.

Important:

The Action Queue does not care why the Trigger matched.

It only contains:

```text
ExecutionId
TicketId
ActionType
ExecutionTarget
TargetField
Value
Sequence
Status
```

This becomes the boundary between Automation and the executor.

---

# 14. Action Execution Target

Actions have two targets.

## AUTOMATION

Executed by Automation/DB.

Examples:

```text
SET_STATUS
SET_PRIORITY
SET_GROUP
SET_AGENT
SET_TYPE
SET_DUE_DATE
SET_CUSTOM_FIELD
```

## APPLICATION

Executed by Go/application.

Examples:

```text
SEND_EMAIL
SEND_NOTIFICATION
WEBHOOK
ADD_REPLY
ADD_NOTE
external service
```

---

# 15. Why Field Actions Stay in Automation

A simple field update does not need:

```text
DB -> Go -> repository -> DB
```

The DB Automation processor already has the required Ticket identifier and action definition.

More importantly, the resulting field update should become another normal Automation event.

Example:

```text
Automation A
IF Status = OPEN
THEN Priority = HIGH
```

DB performs:

```text
Priority NORMAL -> HIGH
```

Then:

```text
TicketActivityLogs
```

records the mutation.

The normal collector creates a new Delta.

Automation B can then process:

```text
IF Priority = HIGH
THEN Group = VIP
```

This is the intended segmentation/data-driven flow inherited from Tridens.

---

# 16. Application Independence

The application should not know:

```text
TriggerBlock
TriggerRule
Operator
FIRST_MATCH
ALL_MATCH
Evaluation logic
```

Application only sees:

```text
ActionId
ExecutionId
TicketId
ActionType
Target
Value
```

This prevents Automation implementation changes from forcing application changes.

---

# 17. Automation Independence

Automation should not know how the application:

```text
sends email
renders HTML
calls external APIs
processes attachments
sends notification
```

Automation only dispatches a work item and receives the result.

---


# 17A. Application Worker Concurrency Model

Application workers may run in parallel.

They never perform:

```text
SELECT READY
then later
UPDATE PROCESSING
```

Instead, the DB performs one atomic claim:

```text
READY
    -> PROCESSING
    + owner
    + lease
```

and returns only the rows owned by that worker.

A lease handles worker crashes:

```text
PROCESSING
Lease expired
    ->
reclaimable
```

Atomic claim prevents concurrent duplicate ownership.

It does **not** by itself guarantee exactly-once external effects. For `SEND_EMAIL`, webhook, and other external actions, use a stable action idempotency key or application outbox/deduplication mechanism.

Worker reports:

```text
SUCCESS
or
FAIL
```

The Automation DB aggregates all action results into:

```text
PROCESSING
COMPLETED
PARTIAL_FAILED
FAILED
```

This aggregate status is also used by Ticket Creation visibility finalization.


# 18. Action History

`AutomationActionHistories`

Purpose:

> Immutable final record of what was actually attempted/executed.

Example field action:

```text
ActionType = SET_PRIORITY
FromValue = NORMAL
ToValue = HIGH
Status = SUCCESS
```

Example app action:

```text
ActionType = SEND_EMAIL
ConfiguredValue = "Hello {{ticket.requester.name}}"
ResolvedValue = "Hello John"
Status = SUCCESS
```

This table is the OneDesk audit equivalent of the immutable action history role provided by Tridens `tbl_TriggerActionPlayer`.

---


# 18A. Audit Volume and Retention

Audit intentionally stores more information than the processing queue.

The largest table is expected to be:

```text
AutomationEvaluationRules
```

because it may contain one row for every rule evaluated, including `IsMatch = 0`.

Therefore:

```text
queue retention != audit retention
```

Audit retention must be configurable.

The schema should be friendly to:

```text
time-based batch purge
archival
future monthly/date partitioning
```

Cleanup must itself use bounded batches. Never delete millions of audit rows in one transaction.

The usual retention hierarchy can be configured so that detailed rule audit may have a shorter retention than execution/action summaries, but the exact duration is a Business Rule rather than an engine constant.


# 19. Ticket Activity vs Automation Audit

These answer different questions.

## TicketActivityLogs

Answers:

> What changed on the Ticket?

Example:

```text
Priority NORMAL -> HIGH
```

## AutomationEvaluations

Answers:

> Which Trigger was evaluated and did it match?

## AutomationEvaluationRules

Answers:

> Why did it match?

## AutomationExecutions

Answers:

> Which selected Automation was actually launched?

## AutomationActionHistories

Answers:

> What action actually happened and what was the result?

Together they provide full traceability.

---

# 20. Full Audit Example

Ticket:

```text
TKT-001
```

Event:

```text
Ticket created
```

Evaluation:

```text
Trigger: VIP Routing
Result: MATCH
Selected: YES
```

Rule detail:

```text
CustomerType = VIP       MATCH
Priority = URGENT        MATCH
```

Execution:

```text
EXEC-001
```

Action:

```text
SET_GROUP = VIP_SUPPORT
```

Action result:

```text
SUCCESS
FromValue = NULL
ToValue = VIP_SUPPORT
```

Ticket activity:

```text
Group NULL -> VIP_SUPPORT
CausedBy AutomationExecution EXEC-001
```

This gives an end-to-end audit chain:

```text
Ticket Event
    -> Evaluation
    -> Rule reason
    -> Selection
    -> Execution
    -> Action
    -> Ticket mutation
```

---

# 21. FIRST_MATCH

Used when only the first matching Trigger should execute.

Ordering must be deterministic:

```text
SortOrder
```

Example:

```text
10 VIP Routing       MATCH
20 Urgent Routing    MATCH
30 Default Routing   MATCH
```

Result:

```text
VIP Routing selected
```

The other matches stay available in audit as:

```text
IsMatch=1
IsSelected=0
```

---

# 22. ALL_MATCH

All matching Triggers are selected.

Example:

```text
10 VIP Routing       MATCH
20 Urgent Priority   MATCH
30 Add SLA Tag       MATCH
```

All three become executions/actions.

The application never decides which should run.

That decision is already final when the action reaches the Action Queue.

---

# 23. Ticket Creation Visibility

New Ticket visibility to the User is gated by directly selected `TICKET_CREATED` Automation executions.

Example:

```text
Ticket created
CreateAutomationStatus=PENDING
```

After selection:

```text
FIRST_MATCH
    -> one selected execution

ALL_MATCH
    -> all selected executions
```

The Ticket becomes User-visible after all directly selected create executions become terminal.

Do not wait for descendant Ticket Update automation caused by create actions.

---

# 24. Cascade

Example:

```text
Create Automation A
    -> SET_PRIORITY HIGH

Priority update creates new Ticket event

Update Automation B
    -> SET_GROUP VIP
```

This is two distinct Automation cycles.

This is preferred over modifying the current evaluator snapshot in memory.

Benefits:

- easier audit
- easier retry
- easier loop protection
- consistent with event-driven Tridens flow

---

# 25. Cascade Lineage

Each automation-caused Ticket change carries:

```text
AutomationExecutionId
```

The next Execution can derive:

```text
ParentExecutionId
RootExecutionId
ExecutionDepth
```

Example:

```text
EXEC-A depth 0
    |
    v
EXEC-B depth 1
    |
    v
EXEC-C depth 2
```

A configurable maximum depth prevents infinite loops.

---

# 26. Schedule Trigger

Schedule Trigger is not a separate backend engine.

It is mainly a UI grouping that allows time-based conditions.

Normal event producer:

```text
TicketActivityLogs -> Collector
```

Schedule producer:

```text
Schedule Scanner -> Delta
```

After Delta:

```text
both use exactly the same pipeline
```

This means:

```text
one evaluator
one trigger selector
one action dispatcher
one audit model
```

---

# 27. Queue Cleanup

Because permanent audit exists, queue tables may later use retention/cleanup.

Examples:

```text
delete completed queue rows after N days
archive completed rows
partition queue tables
```

Long-term audit remains in:

```text
AutomationEvaluations
AutomationEvaluationBlocks
AutomationEvaluationRules
AutomationExecutions
AutomationActionHistories
TicketActivityLogs
```

---

# 28. Key Design Rules

1. Do not use queue tables as permanent audit.
2. Do not let application evaluate Automation rules.
3. Do not let DB perform external application actions.
4. Field mutations stay in DB Automation when practical.
5. Every Automation-caused field mutation becomes a normal Ticket event.
6. Schedule Trigger enters the normal pipeline.
7. `FIRST_MATCH` / `ALL_MATCH` is resolved before Action dispatch.
8. Execution lineage must be persisted.
9. Audit must distinguish `MATCHED` from `SELECTED`.
10. `AutomationExecutions` means selected execution occurrence, not current Trigger state.
11. High-volume DB stages must be set-based and batch-oriented.
12. Queue claim must be atomic.
13. External application actions require idempotency beyond atomic claim.
14. Queue and audit retention are separate policies.

---

# 29. Mental Model

The easiest way to understand the system is:

```text
Queue = work being processed

Evaluation Audit = why a decision was made

Execution = what Automation was actually selected

Action Queue = what must be done

Action History = what actually happened

Ticket Activity = what changed on the Ticket
```

Those concepts should not be merged.

