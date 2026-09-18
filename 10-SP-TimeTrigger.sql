-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 4: Time Trigger Scanner SP
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationTimeTriggerScanBatch
    @EvaluationBucket VARCHAR(100) = NULL,
    @BatchSize INT = 200,
    @QueuedCount INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @QueuedCount = 0;

    -- Default evaluation bucket to current UTC hourly bucket: e.g. "TT_20260918_12"
    IF @EvaluationBucket IS NULL OR LTRIM(RTRIM(@EvaluationBucket)) = ''
    BEGIN
        SET @EvaluationBucket = 'TT_' + FORMAT(SYSUTCDATETIME(), 'yyyyMMdd_HH');
    END;

    DECLARE @CurrentUtc DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';

    -- Active Time Triggers
    DECLARE @TimeTriggers TABLE
    (
        RowId INT IDENTITY(1,1) PRIMARY KEY,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        BusinessCalendarId UNIQUEIDENTIFIER NULL
    );

    INSERT INTO @TimeTriggers (TriggerId, BusinessCalendarId)
    SELECT t.Id, t.BusinessCalendarId
    FROM dbo.AutomationTriggers t WITH (NOLOCK)
    WHERE t.EventType = 'TIME_TRIGGER' 
      AND t.IsActive = 1
    ORDER BY t.Priority ASC;

    DECLARE @TotalTriggers INT = (SELECT COUNT(*) FROM @TimeTriggers);
    DECLARE @CurrentTriggerRow INT = 1;

    WHILE @CurrentTriggerRow <= @TotalTriggers
    BEGIN
        DECLARE @TriggerId UNIQUEIDENTIFIER;
        DECLARE @CalendarId UNIQUEIDENTIFIER;

        SELECT
            @TriggerId = TriggerId,
            @CalendarId = BusinessCalendarId
        FROM @TimeTriggers
        WHERE RowId = @CurrentTriggerRow;

        -- Resolve Business Calendar for this trigger
        DECLARE @ResolvedCalId UNIQUEIDENTIFIER = NULL;
        DECLARE @IsBusinessHour BIT = 0;
        DECLARE @IsHoliday BIT = 0;

        EXEC dbo.ganymede_businessCalendarResolve
            @BusinessCalendarId = @CalendarId,
            @CheckTimeUtc = @CurrentUtc,
            @ResolvedCalendarId = @ResolvedCalId OUTPUT,
            @IsBusinessHour = @IsBusinessHour OUTPUT,
            @IsHoliday = @IsHoliday OUTPUT;

        -- Identify Candidate Tickets for this trigger with Cheap Pre-Filtering
        -- Exclude deleted tickets and tickets already scanned in this bucket
        DECLARE @CandidateTickets TABLE
        (
            TicketRowId INT NOT NULL PRIMARY KEY,
            TicketId UNIQUEIDENTIFIER NOT NULL
        );
        DELETE FROM @CandidateTickets;

        INSERT INTO @CandidateTickets (TicketRowId, TicketId)
        SELECT TOP (@BatchSize) 
            ROW_NUMBER() OVER (ORDER BY t.UpdatedAt ASC),
            t.Id
        FROM dbo.Tickets t WITH (NOLOCK)
        WHERE t.IsDeleted = 0
          AND NOT EXISTS
          (
              SELECT 1 
              FROM dbo.AutomationTriggerQueueSummary qs WITH (NOLOCK)
              WHERE qs.TicketId = t.Id
                AND qs.CandidateTriggerId = @TriggerId
                AND qs.EvaluationBucket = @EvaluationBucket
                AND qs.QueueSourceType = 'TIME_TRIGGER'
          );

        DECLARE @TotalTickets INT = (SELECT COUNT(*) FROM @CandidateTickets);
        DECLARE @CurrentTicketRow INT = 1;

        WHILE @CurrentTicketRow <= @TotalTickets
        BEGIN
            DECLARE @TicketId UNIQUEIDENTIFIER;
            SELECT @TicketId = TicketId
            FROM @CandidateTickets
            WHERE TicketRowId = @CurrentTicketRow;

            DECLARE @QueueSummaryId BIGINT;

            -- Route directly into AutomationTriggerQueueSummary (pure time trigger, no fake activity log rows)
            INSERT INTO dbo.AutomationTriggerQueueSummary
            (
                TicketId,
                QueueSourceType,
                CandidateTriggerId,
                EvaluationBucket,
                SourceAutomationExecutionId,
                RootExecutionId,
                ExecutionDepth,
                OccurredAt,
                BusinessCalendarId,
                IsBusinessHour,
                IsHoliday,
                Status,
                CreatedAt
            )
            VALUES
            (
                @TicketId,
                'TIME_TRIGGER',
                @TriggerId,
                @EvaluationBucket,
                NULL,
                NULL,
                0,
                @CurrentUtc,
                @ResolvedCalId,
                @IsBusinessHour,
                @IsHoliday,
                'PENDING',
                @CurrentUtc
            );

            SET @QueueSummaryId = SCOPE_IDENTITY();

            -- Materialize Ticket Delta Attributes
            INSERT INTO dbo.AutomationTriggerQueueDelta
            (
                QueueSummaryId,
                FieldSource,
                FieldCode,
                OldValue,
                NewValue
            )
            SELECT
                @QueueSummaryId,
                'DEFAULT',
                prop.Code,
                NULL,
                prop.Val
            FROM dbo.Tickets t WITH (NOLOCK)
            CROSS APPLY
            (
                VALUES
                    ('status', t.Status),
                    ('priority', t.Priority),
                    ('subject', t.Subject),
                    ('source', t.Source),
                    ('groupId', CAST(t.GroupId AS NVARCHAR(MAX))),
                    ('assignedAgentId', CAST(t.AssignedAgentId AS NVARCHAR(MAX))),
                    ('requesterContactId', CAST(t.RequesterContactId AS NVARCHAR(MAX))),
                    ('requesterCompanyId', CAST(t.RequesterCompanyId AS NVARCHAR(MAX))),
                    ('hoursSinceCreated', CAST(DATEDIFF(HOUR, t.CreatedAt, @CurrentUtc) AS NVARCHAR(MAX))),
                    ('hoursSinceStatusChanged', CAST(DATEDIFF(HOUR, ISNULL(t.StatusChangedAt, t.CreatedAt), @CurrentUtc) AS NVARCHAR(MAX))),
                    ('isBusinessHour', CAST(@IsBusinessHour AS NVARCHAR(MAX))),
                    ('isHoliday', CAST(@IsHoliday AS NVARCHAR(MAX)))
            ) AS prop(Code, Val)
            WHERE t.Id = @TicketId;

            -- Materialize Custom Fields
            INSERT INTO dbo.AutomationTriggerQueueDelta
            (
                QueueSummaryId,
                FieldSource,
                FieldCode,
                OldValue,
                NewValue
            )
            SELECT
                @QueueSummaryId,
                'CUSTOM',
                tf.FieldCode,
                NULL,
                COALESCE(
                    tfv.TextValue,
                    CAST(tfv.NumberValue AS NVARCHAR(MAX)),
                    CAST(tfv.DecimalValue AS NVARCHAR(MAX)),
                    CONVERT(NVARCHAR(MAX), tfv.DateValue, 23),
                    CASE WHEN tfv.BooleanValue = 1 THEN 'true' WHEN tfv.BooleanValue = 0 THEN 'false' END,
                    CAST(tfv.SelectedOptionId AS NVARCHAR(MAX))
                )
            FROM dbo.TicketFieldValues tfv WITH (NOLOCK)
            INNER JOIN dbo.TicketFields tf WITH (NOLOCK)
                ON tf.Id = tfv.TicketFieldId
            WHERE tfv.TicketId = @TicketId;

            SET @QueuedCount = @QueuedCount + 1;
            SET @CurrentTicketRow = @CurrentTicketRow + 1;
        END;

        SET @CurrentTriggerRow = @CurrentTriggerRow + 1;
    END;

    SELECT @QueuedCount AS QueuedCount;
END;
GO
