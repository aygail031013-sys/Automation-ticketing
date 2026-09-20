-- =================================================================================================
-- OneDesk Automation - application action worker API
-- Claims are atomic and leased. The ActionId returned as IdempotencyKey must also be used by the
-- application's outbox/deduplication layer for non-transactional external effects.
-- =================================================================================================
USE OneDeskDb;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationExecutionRefreshStatus
    @AutomationExecutionId UNIQUEIDENTIFIER
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @Total INT;
    DECLARE @Open INT;
    DECLARE @Failed INT;

    SELECT
        @Total = COUNT(*),
        @Open = COALESCE(SUM(CASE WHEN Status IN ('READY', 'PROCESSING') THEN 1 ELSE 0 END), 0),
        @Failed = COALESCE(SUM(CASE WHEN Status = 'FAILED' THEN 1 ELSE 0 END), 0)
    FROM dbo.AutomationTriggerQueueAction
    WHERE AutomationExecutionId = @AutomationExecutionId;

    UPDATE dbo.AutomationExecutions
    SET Status = CASE
            WHEN COALESCE(@Total, 0) = 0 THEN 'COMPLETED'
            WHEN @Open > 0 THEN 'IN_PROGRESS'
            WHEN @Failed = @Total THEN 'FAILED'
            WHEN @Failed > 0 THEN 'PARTIAL_FAILED'
            ELSE 'COMPLETED'
        END,
        ExecutedAt = CASE WHEN @Open = 0 THEN @Now ELSE NULL END
    WHERE Id = @AutomationExecutionId;

    -- Only the direct TICKET_CREATED execution set controls create visibility. Descendant update
    -- automations are intentionally excluded by ParentExecutionId IS NULL.
    UPDATE ticket
    SET CreateAutomationStatus = 'READY'
    FROM dbo.Tickets AS ticket
    INNER JOIN dbo.AutomationExecutions AS completed ON completed.TicketId = ticket.Id
    INNER JOIN dbo.AutomationTriggerQueueSummary AS origin ON origin.Id = completed.QueueSummaryId
    WHERE completed.Id = @AutomationExecutionId
      AND origin.EventType = 'TICKET_CREATED'
      AND completed.ParentExecutionId IS NULL
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.AutomationExecutions AS direct_execution
          INNER JOIN dbo.AutomationTriggerQueueSummary AS direct_origin
              ON direct_origin.Id = direct_execution.QueueSummaryId
          WHERE direct_execution.TicketId = ticket.Id
            AND direct_origin.EventType = 'TICKET_CREATED'
            AND direct_execution.ParentExecutionId IS NULL
            AND direct_execution.Status NOT IN ('COMPLETED', 'PARTIAL_FAILED', 'FAILED', 'SKIPPED')
      );
END;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationExecutionActionClaimBatch
    @WorkerId VARCHAR(100) = 'Worker-Default',
    @BatchSize INT = 20,
    @LeaseSeconds INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 500 THEN @BatchSize ELSE 20 END;
    SET @LeaseSeconds = COALESCE
    (
        NULLIF(@LeaseSeconds, 0),
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'ActionLeaseSeconds'),
        300
    );
    SET @LeaseSeconds = CASE WHEN @LeaseSeconds BETWEEN 10 AND 86400 THEN @LeaseSeconds ELSE 300 END;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @MaxAttempts INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'ActionMaxAttempts'),
        5
    );

    CREATE TABLE #ClaimedIds (ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);

    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @ClaimLockResult INT;
        EXEC @ClaimLockResult = sys.sp_getapplock
            @Resource = 'OneDesk.Automation.ActionClaim',
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 5000;
        IF @ClaimLockResult < 0
            THROW 51030, 'Unable to acquire the automation action claim lock.', 1;

        ;WITH Eligible AS
        (
            SELECT
                action.Id,
                action.TicketId,
                action.CreatedAt,
                action.ActionSequence,
                ROW_NUMBER() OVER
                (
                    PARTITION BY action.TicketId
                    ORDER BY action.CreatedAt, action.AutomationExecutionId, action.ActionSequence
                ) AS TicketRank
            FROM dbo.AutomationTriggerQueueAction AS action WITH (UPDLOCK, READPAST, ROWLOCK)
            WHERE action.ExecutionTarget = 'APPLICATION'
              AND action.AttemptCount < @MaxAttempts
              AND
              (
                  action.Status = 'READY'
                  OR (action.Status = 'PROCESSING' AND action.LeaseExpiresAt < @Now)
              )
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.AutomationTriggerQueueAction AS active_claim
                  WHERE active_claim.TicketId = action.TicketId
                    AND active_claim.Id <> action.Id
                    AND active_claim.Status = 'PROCESSING'
                    AND active_claim.LeaseExpiresAt >= @Now
              )
              AND NOT EXISTS
              (
                  SELECT 1
                  FROM dbo.AutomationTriggerQueueAction AS previous
                  WHERE previous.AutomationExecutionId = action.AutomationExecutionId
                    AND previous.ActionSequence < action.ActionSequence
                    AND previous.Status IN ('READY', 'PROCESSING')
              )
        )
        INSERT #ClaimedIds (ActionId)
        SELECT TOP (@BatchSize) Id
        FROM Eligible
        WHERE TicketRank = 1
        ORDER BY CreatedAt, ActionSequence;

        UPDATE action
        SET Status = 'PROCESSING',
            AttemptCount = AttemptCount + 1,
            ClaimedBy = COALESCE(NULLIF(@WorkerId, ''), 'Worker-Default'),
            ClaimedAt = @Now,
            LeaseExpiresAt = DATEADD(SECOND, @LeaseSeconds, @Now),
            LastError = NULL
        FROM dbo.AutomationTriggerQueueAction AS action
        INNER JOIN #ClaimedIds AS claimed ON claimed.ActionId = action.Id;

        UPDATE execution
        SET Status = 'IN_PROGRESS'
        FROM dbo.AutomationExecutions AS execution
        WHERE EXISTS
        (
            SELECT 1
            FROM dbo.AutomationTriggerQueueAction AS action
            INNER JOIN #ClaimedIds AS claimed ON claimed.ActionId = action.Id
            WHERE action.AutomationExecutionId = execution.Id
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        action.Id AS ActionId,
        action.Id AS IdempotencyKey,
        action.AutomationExecutionId AS ExecutionId,
        action.TicketId,
        action.ActionSequence,
        action.ActionType,
        action.ExecutionTarget,
        action.TargetField,
        action.ActionValue,
        action.AttemptCount,
        action.LeaseExpiresAt,
        execution.TriggerId,
        execution.ParentExecutionId,
        execution.RootExecutionId,
        execution.ExecutionDepth,
        ticket.TicketNo,
        ticket.Subject AS TicketSubject,
        ticket.Status AS TicketStatus,
        ticket.Priority AS TicketPriority,
        ticket.GroupId AS TicketGroupId,
        ticket.AssignedAgentId AS TicketAssignedAgentId,
        ticket.RequesterContactId,
        ticket.RequesterCompanyId
    FROM dbo.AutomationTriggerQueueAction AS action
    INNER JOIN #ClaimedIds AS claimed ON claimed.ActionId = action.Id
    INNER JOIN dbo.AutomationExecutions AS execution ON execution.Id = action.AutomationExecutionId
    INNER JOIN dbo.Tickets AS ticket ON ticket.Id = action.TicketId
    ORDER BY action.CreatedAt, action.ActionSequence;
END;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationExecutionActionComplete
    @ActionId UNIQUEIDENTIFIER,
    @Status VARCHAR(20) = 'SUCCEEDED',
    @RenderedValue NVARCHAR(MAX) = NULL,
    @ErrorMessage NVARCHAR(MAX) = NULL,
    @WorkerId VARCHAR(100) = NULL,
    @Retryable BIT = 1
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @ExecutionId UNIQUEIDENTIFIER;
    DECLARE @TicketId UNIQUEIDENTIFIER;
    DECLARE @AttemptCount INT;
    DECLARE @CurrentStatus VARCHAR(20);
    DECLARE @ClaimedBy VARCHAR(100);
    DECLARE @MaxAttempts INT = COALESCE
    (
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'ActionMaxAttempts'),
        5
    );
    DECLARE @IsSuccess BIT = CASE WHEN UPPER(@Status) IN ('SUCCESS', 'SUCCEEDED', 'COMPLETED') THEN 1 ELSE 0 END;

    BEGIN TRY
        BEGIN TRANSACTION;

        SELECT
            @ExecutionId = action.AutomationExecutionId,
            @TicketId = action.TicketId,
            @AttemptCount = action.AttemptCount,
            @CurrentStatus = action.Status,
            @ClaimedBy = action.ClaimedBy
        FROM dbo.AutomationTriggerQueueAction AS action WITH (UPDLOCK, ROWLOCK)
        WHERE action.Id = @ActionId
          AND action.ExecutionTarget = 'APPLICATION';

        IF @ExecutionId IS NULL
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 16 AS ErrorCode, 'ACTION_NOT_FOUND' AS ErrorMessage;
            RETURN;
        END;

        -- Repeated completion calls are idempotent and do not append a second history row.
        IF @CurrentStatus IN ('SUCCEEDED', 'FAILED')
        BEGIN
            COMMIT TRANSACTION;
            SELECT 0 AS ErrorCode, 'ALREADY_TERMINAL' AS ErrorMessage;
            RETURN;
        END;

        IF @CurrentStatus <> 'PROCESSING'
           OR (@WorkerId IS NOT NULL AND @ClaimedBy <> @WorkerId)
        BEGIN
            ROLLBACK TRANSACTION;
            SELECT 16 AS ErrorCode, 'ACTION_NOT_OWNED_BY_WORKER' AS ErrorMessage;
            RETURN;
        END;

        UPDATE dbo.AutomationTriggerQueueAction
        SET Status = CASE
                WHEN @IsSuccess = 1 THEN 'SUCCEEDED'
                WHEN @Retryable = 1 AND @AttemptCount < @MaxAttempts THEN 'READY'
                ELSE 'FAILED'
            END,
            RenderedValue = COALESCE(@RenderedValue, RenderedValue),
            RenderedAt = CASE WHEN @RenderedValue IS NULL THEN RenderedAt ELSE @Now END,
            CompletedAt = CASE
                WHEN @IsSuccess = 1 OR @Retryable = 0 OR @AttemptCount >= @MaxAttempts THEN @Now
                ELSE NULL
            END,
            LastError = CASE WHEN @IsSuccess = 1 THEN NULL ELSE @ErrorMessage END,
            LeaseExpiresAt = NULL
        WHERE Id = @ActionId;

        INSERT dbo.AutomationActionHistories
        (
            QueueActionId, AutomationExecutionId, TicketId, AttemptNumber,
            ActionType, ExecutionTarget, TargetField, ConfiguredValue, ResolvedValue,
            FromValue, ToValue, Status, WorkerId, ErrorMessage, StartedAt, CompletedAt
        )
        SELECT
            action.Id, action.AutomationExecutionId, action.TicketId, action.AttemptCount,
            action.ActionType, action.ExecutionTarget, action.TargetField, action.ActionValue,
            COALESCE(@RenderedValue, action.RenderedValue), NULL, NULL,
            CASE WHEN @IsSuccess = 1 THEN 'SUCCEEDED' ELSE 'FAILED' END,
            action.ClaimedBy, CASE WHEN @IsSuccess = 1 THEN NULL ELSE @ErrorMessage END,
            action.ClaimedAt, @Now
        FROM dbo.AutomationTriggerQueueAction AS action
        WHERE action.Id = @ActionId;

        EXEC dbo.ganymede_automationExecutionRefreshStatus
            @AutomationExecutionId = @ExecutionId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT 0 AS ErrorCode, '' AS ErrorMessage;
END;
GO
