# Migration Working State

## Baseline

- `/workspace/scratch/2cfdbf340f33/project_sources/11-onedesk-2026-09-15.zip` — latest complete OneDesk application baseline identified by the user.

## Active phase

- Review continuation / Phase 1 planning only.

## Module

- OneDesk Ticket Automation testing and common rule configuration.

## Current overrides

- `AUTOMATION_EXECUTION_PLAN.md` — active design checkpoint, Library version read on 2026-09-20.
- `AUTOMATION_FLOW_AND_COMPONENT_GUIDE.md` — active flow checkpoint, Library version read on 2026-09-20.
- `AUTOMATION_TESTING_PLAN.md` — draft testing plan created in this checkpoint.
- `AUTOMATION_COMMON_RULE_TEST_CONFIGURATION.md` — draft configuration contract created in this checkpoint.

## Reference inspected but not active

- `09-Automation-Test-Configuration.sql` (16 Sep 2026) — superseded for new implementation because it targets the older EventQueue/ActionQueue/TimerQueue runtime model.
- `onedesk-automation-mvp-feature-scope-business-rules-2026-09-10.md` — used only to retain the six approved Ticket Update event names; newer architecture checkpoints supersede its simplified queue model and no-cascade decision.

## Approved SQL contracts

- None. No revised Automation DDL or stored-procedure contract is final yet.

## Repository status

- Not started. No Go source changes are authorized by this task.

## Superseded versions

- The 16 Sep test SQL configuration is not valid as the executable seed for the revised Tridens-style pipeline.

## Last validation

- Read both active 20 Sep design documents completely.
- Inspected source baseline fields for `Tickets`, `Contacts`, `Companies`, `Agents`, `GroupAgents`, `TicketActivityLogs`, and initial Ticket Field seed values.
- Cross-checked all configured event names against the earlier MVP business-rule document.
- Performed static document consistency checks only.
- SQL Server compilation and runtime tests were not run because this task creates a plan/configuration contract and the revised Automation DDL/SP does not yet exist as an approved final contract.

## Checkpoint status

- Draft for review.
