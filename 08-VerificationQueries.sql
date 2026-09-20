-- =================================================================================================
-- OneDesk Automation - non-destructive verification
-- All smoke-test writes are enclosed in one transaction and always rolled back.
-- Run after 01, 02, 03, 04, 05, 07, 09, 10, and 11.
-- =================================================================================================
USE OneDeskDb;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

PRINT 'OneDesk Automation verification starting';

IF OBJECT_ID('dbo.AutomationEvaluations', 'U') IS NULL
    THROW 51000, 'Missing durable evaluation audit table.', 1;
IF OBJECT_ID('dbo.AutomationEvaluationBlocks', 'U') IS NULL
    THROW 51001, 'Missing durable block audit table.', 1;
IF OBJECT_ID('dbo.AutomationEvaluationRules', 'U') IS NULL
    THROW 51002, 'Missing durable rule audit table.', 1;
IF OBJECT_ID('dbo.AutomationTriggerQueueTrigger', 'U') IS NULL
    THROW 51003, 'Missing selected-trigger queue table.', 1;
IF OBJECT_ID('dbo.AutomationTriggerQueueAction', 'U') IS NULL
    THROW 51004, 'Missing action queue table.', 1;
IF OBJECT_ID('dbo.AutomationActionHistories', 'U') IS NULL
    THROW 51005, 'Missing immutable action history table.', 1;
IF OBJECT_ID('dbo.ganymede_automationActionProcessBatch', 'P') IS NULL
    THROW 51006, 'Missing database action processor.', 1;

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @TicketId UNIQUEIDENTIFIER = NEWID();
    DECLARE @ActorId UNIQUEIDENTIFIER = NEWID();
    DECLARE @OperationId UNIQUEIDENTIFIER = NEWID();
    DECLARE @TicketNo VARCHAR(25) = '#V' + RIGHT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 9);

    INSERT dbo.Tickets
    (
        Id, TicketNo, RequesterContactId, GroupId, AssignedAgentId,
        Subject, Description, PlainDescription, Source, Status, Priority,
        CreatedBy, CreatedAt, UpdatedBy, UpdatedAt, IsDeleted
    )
    VALUES
    (
        @TicketId, @TicketNo, NEWID(), NEWID(), NEWID(),
        'URGENT: transactional automation verification', 'verification', 'verification',
        'PORTAL_AGENT', 'OPEN', 'MEDIUM', 'AUTOMATION_TEST',
        SYSUTCDATETIME() AT TIME ZONE 'UTC', 'AUTOMATION_TEST',
        SYSUTCDATETIME() AT TIME ZONE 'UTC', 0
    );

    EXEC dbo.ganymede_ticketActivityLogCreateForCreatedTicket
        @TicketId = @TicketId,
        @ActorId = @ActorId,
        @AutomationExecutionId = NULL,
        @OperationId = @OperationId;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.TicketActivityLogs
        WHERE TicketId = @TicketId AND Event = 'TICKET_CREATED'
          AND OperationId = @OperationId AND AutomationExecutionId IS NULL
    )
        THROW 51010, 'Create activity did not preserve OperationId.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.Tickets
        WHERE Id = @TicketId AND CreateAutomationStatus = 'PENDING'
    )
        THROW 51011, 'Ticket creation visibility was not gated.', 1;

    DECLARE @Collected INT;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch
        @BatchSize = 2000,
        @CollectedCount = @Collected OUTPUT;

    DECLARE @QueueSummaryId BIGINT =
    (
        SELECT Id FROM dbo.AutomationTriggerQueueSummary
        WHERE TicketId = @TicketId AND OperationId = @OperationId
    );

    IF @QueueSummaryId IS NULL
        THROW 51012, 'Collector did not create an operation summary.', 1;

    IF (SELECT COUNT(*) FROM dbo.AutomationTriggerQueueSummary
        WHERE TicketId = @TicketId AND OperationId = @OperationId) <> 1
        THROW 51013, 'Collector created more than one summary for an operation.', 1;

    DECLARE @Evaluated INT;
    DECLARE @Executions INT;
    EXEC dbo.ganymede_automationEvaluateBatch
        @BatchSize = 1000,
        @EvaluatedCount = @Evaluated OUTPUT,
        @ExecutionsCreatedCount = @Executions OUTPUT,
        @WorkerId = 'Verification-Evaluator';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationEvaluations
        WHERE QueueSummaryId = @QueueSummaryId AND IsMatch = 1 AND IsSelected = 1
    )
        THROW 51014, 'No matching selected evaluation was audited.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.AutomationEvaluations AS evaluation
        INNER JOIN dbo.AutomationEventSettings AS setting ON setting.EventType = evaluation.EventType
        WHERE evaluation.QueueSummaryId = @QueueSummaryId
          AND setting.ExecutionMode = 'FIRST_MATCH'
        GROUP BY evaluation.QueueSummaryId
        HAVING SUM(CONVERT(INT, evaluation.IsSelected)) > 1
    )
        THROW 51015, 'FIRST_MATCH selected more than one trigger.', 1;

    DECLARE @ExecutionId UNIQUEIDENTIFIER =
    (
        SELECT TOP (1) Id FROM dbo.AutomationExecutions
        WHERE QueueSummaryId = @QueueSummaryId ORDER BY CreatedAt, Id
    );

    IF @ExecutionId IS NULL
        THROW 51016, 'Selected evaluation did not create an execution.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerQueueAction
        WHERE AutomationExecutionId = @ExecutionId
          AND ExecutionTarget = 'AUTOMATION' AND ActionType = 'SET_PRIORITY'
    )
        THROW 51017, 'Field action was not routed to the database target.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerQueueAction
        WHERE AutomationExecutionId = @ExecutionId
          AND ExecutionTarget = 'APPLICATION' AND ActionType = 'SEND_EMAIL'
    )
        THROW 51018, 'External action was not routed to the application target.', 1;

    DECLARE @Processed INT;
    DECLARE @Succeeded INT;
    DECLARE @Failed INT;
    EXEC dbo.ganymede_automationActionProcessBatch
        @BatchSize = 1000,
        @WorkerId = 'Verification-DB-Worker',
        @ProcessedCount = @Processed OUTPUT,
        @SucceededCount = @Succeeded OUTPUT,
        @FailedCount = @Failed OUTPUT;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.Tickets WHERE Id = @TicketId AND Priority = 'URGENT'
    )
        THROW 51019, 'Database field action did not update the ticket.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.TicketActivityLogs
        WHERE TicketId = @TicketId AND AutomationExecutionId = @ExecutionId
          AND Event = 'TICKET_UPDATED'
    )
        THROW 51020, 'Database field action did not emit a lineage-bearing activity.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationActionHistories
        WHERE AutomationExecutionId = @ExecutionId
          AND ActionType = 'SET_PRIORITY' AND Status = 'SUCCEEDED'
    )
        THROW 51021, 'Database action history was not written.', 1;

    EXEC dbo.ganymede_automationExecutionActionClaimBatch
        @WorkerId = 'Verification-App-Worker',
        @BatchSize = 100,
        @LeaseSeconds = 60;

    DECLARE @ApplicationActionId UNIQUEIDENTIFIER =
    (
        SELECT Id
        FROM dbo.AutomationTriggerQueueAction
        WHERE AutomationExecutionId = @ExecutionId AND ActionType = 'SEND_EMAIL'
    );

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerQueueAction
        WHERE Id = @ApplicationActionId
          AND Status = 'PROCESSING'
          AND ClaimedBy = 'Verification-App-Worker'
          AND AttemptCount = 1
          AND LeaseExpiresAt > (SYSUTCDATETIME() AT TIME ZONE 'UTC')
    )
        THROW 51026, 'Application action was not atomically leased to the worker.', 1;

    DECLARE @RenderedEmail NVARCHAR(MAX) = N'{"ticketNo":"' + @TicketNo + N'"}';
    EXEC dbo.ganymede_automationExecutionActionComplete
        @ActionId = @ApplicationActionId,
        @Status = 'SUCCEEDED',
        @RenderedValue = @RenderedEmail,
        @WorkerId = 'Verification-App-Worker';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerQueueAction
        WHERE Id = @ApplicationActionId
          AND Status = 'SUCCEEDED'
          AND ActionValue LIKE '%{{ticket.ticketNo}}%'
          AND RenderedValue = @RenderedEmail
    )
        THROW 51027, 'Application completion did not preserve ActionValue and persist RenderedValue.', 1;

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationActionHistories
        WHERE QueueActionId = @ApplicationActionId
          AND AttemptNumber = 1 AND Status = 'SUCCEEDED'
    )
        THROW 51028, 'Application action history was not written.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.AutomationExecutions AS execution
        INNER JOIN dbo.Tickets AS ticket ON ticket.Id = execution.TicketId
        WHERE execution.Id = @ExecutionId
          AND execution.Status = 'COMPLETED'
          AND ticket.CreateAutomationStatus = 'READY'
    )
        THROW 51029, 'Execution aggregation or create visibility finalization failed.', 1;

    EXEC dbo.ganymede_automationTriggerQueueCollectBatch
        @BatchSize = 2000,
        @CollectedCount = @Collected OUTPUT;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.AutomationTriggerQueueSummary
        WHERE TicketId = @TicketId
          AND SourceAutomationExecutionId = @ExecutionId
          AND RootExecutionId = @ExecutionId
          AND ExecutionDepth = 1
    )
        THROW 51032, 'Cascade collector did not preserve parent/root/depth lineage.', 1;

    DECLARE @MaxDepth INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue)
         FROM dbo.AutomationSettings WHERE SettingKey = 'MaxExecutionDepth'),
        10
    );
    UPDATE dbo.AutomationExecutions SET ExecutionDepth = @MaxDepth WHERE Id = @ExecutionId;

    DECLARE @DepthOperationId UNIQUEIDENTIFIER = NEWID();
    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket
        @TicketId = @TicketId,
        @ActorType = 'SYSTEM',
        @OldValuesJson = N'{"subject":"before-depth-check"}',
        @NewValuesJson = N'{"subject":"after-depth-check"}',
        @AutomationExecutionId = @ExecutionId,
        @OperationId = @DepthOperationId;

    EXEC dbo.ganymede_automationTriggerQueueCollectBatch
        @BatchSize = 2000,
        @CollectedCount = @Collected OUTPUT;
    EXEC dbo.ganymede_automationEvaluateBatch
        @BatchSize = 1000,
        @EvaluatedCount = @Evaluated OUTPUT,
        @ExecutionsCreatedCount = @Executions OUTPUT,
        @WorkerId = 'Verification-Depth-Evaluator';

    IF NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerQueueSummary
        WHERE TicketId = @TicketId AND OperationId = @DepthOperationId
          AND ExecutionDepth = @MaxDepth + 1
          AND Status = 'SKIPPED' AND SkipReason = 'SKIPPED_MAX_DEPTH'
    )
        THROW 51033, 'Cascade maximum-depth guard did not halt the descendant.', 1;

    DECLARE @AllMatchOperationId UNIQUEIDENTIFIER = NEWID();
    DECLARE @AllMatchTrigger1 UNIQUEIDENTIFIER = NEWID();
    DECLARE @AllMatchTrigger2 UNIQUEIDENTIFIER = NEWID();

    INSERT dbo.AutomationEventSettings (EventType, ExecutionMode, IsActive)
    VALUES ('VERIFY_ALL_MATCH', 'ALL_MATCH', 1);
    INSERT dbo.AutomationTriggers (Id, Name, EventType, Priority, IsActive)
    VALUES
        (@AllMatchTrigger1, 'Verification ALL_MATCH A', 'VERIFY_ALL_MATCH', 10, 1),
        (@AllMatchTrigger2, 'Verification ALL_MATCH B', 'VERIFY_ALL_MATCH', 20, 1);
    INSERT dbo.TicketActivityLogs
    (
        TicketId, Event, ActorType, ActorId, OldValue, NewValue,
        Description, PlainDescription, AutomationExecutionId, OperationId, CreatedAt
    )
    VALUES
    (
        @TicketId, 'VERIFY_ALL_MATCH', 'SYSTEM', NULL, NULL, N'{}',
        'ALL_MATCH verification', 'ALL_MATCH verification', NULL,
        @AllMatchOperationId, SYSUTCDATETIME() AT TIME ZONE 'UTC'
    );

    EXEC dbo.ganymede_automationTriggerQueueCollectBatch
        @BatchSize = 2000,
        @CollectedCount = @Collected OUTPUT;
    EXEC dbo.ganymede_automationEvaluateBatch
        @BatchSize = 1000,
        @EvaluatedCount = @Evaluated OUTPUT,
        @ExecutionsCreatedCount = @Executions OUTPUT,
        @WorkerId = 'Verification-AllMatch-Evaluator';

    IF
    (
        SELECT COUNT(*)
        FROM dbo.AutomationEvaluations AS evaluation
        INNER JOIN dbo.AutomationTriggerQueueSummary AS summary
            ON summary.Id = evaluation.QueueSummaryId
        WHERE summary.OperationId = @AllMatchOperationId
          AND evaluation.IsMatch = 1 AND evaluation.IsSelected = 1
    ) <> 2
        THROW 51034, 'ALL_MATCH did not select every matching trigger.', 1;

    UPDATE dbo.Tickets
    SET Status = 'PENDING',
        StatusChangedAt = DATEADD(HOUR, -30, SYSUTCDATETIME() AT TIME ZONE 'UTC')
    WHERE Id = @TicketId;

    DECLARE @ActivityCountBeforeTimeScan BIGINT = (SELECT COUNT_BIG(*) FROM dbo.TicketActivityLogs);
    DECLARE @TimeQueued INT;
    DECLARE @Bucket VARCHAR(100) = 'VERIFY_' + REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', '');
    EXEC dbo.ganymede_automationTimeTriggerScanBatch
        @EvaluationBucket = @Bucket,
        @BatchSize = 1000,
        @QueuedCount = @TimeQueued OUTPUT;

    IF @TimeQueued = 0
        THROW 51025, 'Time scanner did not produce an eligible candidate.', 1;

    IF @ActivityCountBeforeTimeScan <> (SELECT COUNT_BIG(*) FROM dbo.TicketActivityLogs)
        THROW 51022, 'Time scanner polluted TicketActivityLogs.', 1;

    DECLARE @TimeQueuedAgain INT;
    EXEC dbo.ganymede_automationTimeTriggerScanBatch
        @EvaluationBucket = @Bucket,
        @BatchSize = 1000,
        @QueuedCount = @TimeQueuedAgain OUTPUT;

    IF EXISTS
    (
        SELECT TicketId, CandidateTriggerId, EvaluationBucket
        FROM dbo.AutomationTriggerQueueSummary
        WHERE QueueSourceType = 'TIME_TRIGGER' AND EvaluationBucket = @Bucket
        GROUP BY TicketId, CandidateTriggerId, EvaluationBucket
        HAVING COUNT(*) > 1
    )
        THROW 51023, 'Time scanner created a duplicate inside an evaluation bucket.', 1;

    ROLLBACK TRANSACTION;
    PRINT 'PASS: transactional smoke verification completed; all writes rolled back.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

-- Read-only operational checks. Empty result sets are healthy.
SELECT action.Id, action.AutomationExecutionId, action.ClaimedBy, action.LeaseExpiresAt
FROM dbo.AutomationTriggerQueueAction AS action
WHERE action.Status = 'PROCESSING'
  AND action.LeaseExpiresAt < (SYSUTCDATETIME() AT TIME ZONE 'UTC');

SELECT summary.Id, summary.TicketId, summary.ClaimedBy, summary.LeaseExpiresAt
FROM dbo.AutomationTriggerQueueSummary AS summary
WHERE summary.Status = 'PROCESSING'
  AND summary.LeaseExpiresAt < (SYSUTCDATETIME() AT TIME ZONE 'UTC');

SELECT execution.TicketId, execution.RootExecutionId, MAX(execution.ExecutionDepth) AS MaximumDepth
FROM dbo.AutomationExecutions AS execution
GROUP BY execution.TicketId, execution.RootExecutionId
HAVING MAX(execution.ExecutionDepth) > COALESCE
(
    (SELECT TRY_CONVERT(INT, SettingValue)
     FROM dbo.AutomationSettings WHERE SettingKey = 'MaxExecutionDepth'),
    10
);
GO
