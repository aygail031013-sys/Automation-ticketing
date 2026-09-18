-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 5: Application Worker API SPs
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------
-- 1. ganymede_automationExecutionActionClaimBatch (Atomic claim with UPDLOCK, READPAST)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_automationExecutionActionClaimBatch
    @WorkerId VARCHAR(100) = 'Worker-Default',
    @BatchSize INT = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ClaimedIds TABLE (ActionId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);

    ;WITH PendingActions AS
    (
        SELECT TOP (@BatchSize)
            Id,
            Status,
            ClaimedAt,
            ClaimedBy
        FROM dbo.AutomationExecutionActions WITH (UPDLOCK, READPAST)
        WHERE Status = 'PENDING'
        ORDER BY CreatedAt ASC, ActionOrder ASC
    )
    UPDATE PendingActions
    SET Status = 'CLAIMED',
        ClaimedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        ClaimedBy = ISNULL(@WorkerId, 'Worker-Default')
    OUTPUT inserted.Id INTO @ClaimedIds(ActionId);

    SELECT
        act.Id AS ActionExecutionId,
        act.AutomationExecutionId,
        act.ActionOrder,
        act.ActionType,
        act.ActionValue,
        ae.TriggerId,
        ae.TicketId,
        ae.ParentExecutionId,
        ae.RootExecutionId,
        ae.ExecutionDepth,
        t.TicketNo,
        t.Subject AS TicketSubject,
        t.Status AS TicketStatus,
        t.Priority AS TicketPriority,
        t.GroupId AS TicketGroupId,
        t.AssignedAgentId AS TicketAssignedAgentId,
        t.RequesterContactId,
        t.RequesterCompanyId
    FROM dbo.AutomationExecutionActions act WITH (NOLOCK)
    INNER JOIN @ClaimedIds c
        ON c.ActionId = act.Id
    INNER JOIN dbo.AutomationExecutions ae WITH (NOLOCK)
        ON ae.Id = act.AutomationExecutionId
    INNER JOIN dbo.Tickets t WITH (NOLOCK)
        ON t.Id = ae.TicketId
    ORDER BY act.CreatedAt ASC, act.ActionOrder ASC;
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 2. ganymede_automationExecutionActionComplete (Action completion & Execution state transition)
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_automationExecutionActionComplete
    @ActionId UNIQUEIDENTIFIER,
    @Status VARCHAR(20) = 'COMPLETED', -- COMPLETED or FAILED
    @RenderedValue NVARCHAR(MAX) = NULL,
    @ErrorMessage NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ExecutionId UNIQUEIDENTIFIER;

    SELECT TOP 1 @ExecutionId = AutomationExecutionId
    FROM dbo.AutomationExecutionActions WITH (NOLOCK)
    WHERE Id = @ActionId;

    IF @ExecutionId IS NULL
    BEGIN
        SELECT 16 AS ErrorCode, 'ACTION_EXECUTION_NOT_FOUND' AS ErrorMessage;
        RETURN;
    END;

    UPDATE dbo.AutomationExecutionActions
    SET Status = ISNULL(@Status, 'COMPLETED'),
        RenderedValue = COALESCE(@RenderedValue, RenderedValue),
        RenderedAt = CASE 
                        WHEN @RenderedValue IS NOT NULL THEN (SYSUTCDATETIME() AT TIME ZONE 'UTC') 
                        ELSE RenderedAt 
                     END,
        CompletedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC'),
        ErrorMessage = @ErrorMessage
    WHERE Id = @ActionId;

    -- Check if all actions under this execution have finished
    IF NOT EXISTS
    (
        SELECT 1 
        FROM dbo.AutomationExecutionActions WITH (NOLOCK)
        WHERE AutomationExecutionId = @ExecutionId
          AND Status IN ('PENDING', 'CLAIMED')
    )
    BEGIN
        DECLARE @HasFailed BIT = 0;
        DECLARE @AllFailed BIT = 0;
        DECLARE @TotalActions INT = 0;
        DECLARE @FailedActions INT = 0;

        SELECT 
            @TotalActions = COUNT(*),
            @FailedActions = COUNT(CASE WHEN Status = 'FAILED' THEN 1 END)
        FROM dbo.AutomationExecutionActions WITH (NOLOCK)
        WHERE AutomationExecutionId = @ExecutionId;

        DECLARE @FinalExecutionStatus VARCHAR(20) = 'COMPLETED';

        IF @FailedActions > 0
        BEGIN
            IF @FailedActions = @TotalActions
                SET @FinalExecutionStatus = 'FAILED';
            ELSE
                SET @FinalExecutionStatus = 'PARTIAL_FAILED';
        END;

        UPDATE dbo.AutomationExecutions
        SET Status = @FinalExecutionStatus,
            ExecutedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        WHERE Id = @ExecutionId;
    END;

    SELECT 0 AS ErrorCode, '' AS ErrorMessage;
END;
GO
