-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 3: Evaluator Engine SP
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationEvaluateBatch
    @BatchSize INT = 50,
    @EvaluatedCount INT = 0 OUTPUT,
    @ExecutionsCreatedCount INT = 0 OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SET @EvaluatedCount = 0;
    SET @ExecutionsCreatedCount = 0;

    -- 1. Read MaxExecutionDepth configuration
    DECLARE @MaxExecutionDepth INT = 10;
    SELECT @MaxExecutionDepth = TRY_CAST(SettingValue AS INT)
    FROM dbo.AutomationSettings WITH (NOLOCK)
    WHERE SettingKey = 'MaxExecutionDepth';

    IF @MaxExecutionDepth IS NULL
        SET @MaxExecutionDepth = 10;

    -- 2. Select batch of pending queue items
    DECLARE @PendingQueue TABLE
    (
        RowId INT NOT NULL PRIMARY KEY,
        Id BIGINT NOT NULL,
        TicketId UNIQUEIDENTIFIER NOT NULL,
        QueueSourceType VARCHAR(30) NOT NULL,
        CandidateTriggerId UNIQUEIDENTIFIER NULL,
        SourceAutomationExecutionId UNIQUEIDENTIFIER NULL,
        RootExecutionId UNIQUEIDENTIFIER NULL,
        ExecutionDepth INT NOT NULL,
        OccurredAt DATETIMEOFFSET NOT NULL,
        IsBusinessHour BIT NOT NULL,
        IsHoliday BIT NOT NULL
    );

    INSERT INTO @PendingQueue
    (
        RowId,
        Id,
        TicketId,
        QueueSourceType,
        CandidateTriggerId,
        SourceAutomationExecutionId,
        RootExecutionId,
        ExecutionDepth,
        OccurredAt,
        IsBusinessHour,
        IsHoliday
    )
    SELECT TOP (@BatchSize)
        ROW_NUMBER() OVER (ORDER BY qs.Id ASC),
        qs.Id,
        qs.TicketId,
        qs.QueueSourceType,
        qs.CandidateTriggerId,
        qs.SourceAutomationExecutionId,
        qs.RootExecutionId,
        qs.ExecutionDepth,
        qs.OccurredAt,
        qs.IsBusinessHour,
        qs.IsHoliday
    FROM dbo.AutomationTriggerQueueSummary qs WITH (NOLOCK)
    WHERE qs.Status = 'PENDING'
    ORDER BY qs.Id ASC;

    DECLARE @TotalQueueRows INT = (SELECT COUNT(*) FROM @PendingQueue);
    DECLARE @CurrentQueueRow INT = 1;

    -- Working tables declared once outside the loop without IDENTITY
    DECLARE @CandidateTriggers TABLE
    (
        TriggerRowId INT NOT NULL PRIMARY KEY,
        TriggerId UNIQUEIDENTIFIER NOT NULL,
        Priority INT NOT NULL
    );

    DECLARE @TriggerBlocks TABLE
    (
        BlockRowId INT NOT NULL PRIMARY KEY,
        BlockId UNIQUEIDENTIFIER NOT NULL,
        LogicalOperator VARCHAR(10) NOT NULL
    );

    DECLARE @BlockRules TABLE
    (
        RuleRowId INT NOT NULL PRIMARY KEY,
        RuleId UNIQUEIDENTIFIER NOT NULL,
        FieldSource VARCHAR(20) NOT NULL,
        FieldCode VARCHAR(100) NOT NULL,
        Operator VARCHAR(50) NOT NULL,
        Value NVARCHAR(MAX) NULL
    );

    WHILE @CurrentQueueRow <= @TotalQueueRows
    BEGIN
        DECLARE @QueueId BIGINT;
        DECLARE @TicketId UNIQUEIDENTIFIER;
        DECLARE @QueueSourceType VARCHAR(30);
        DECLARE @CandidateTriggerId UNIQUEIDENTIFIER;
        DECLARE @SourceAutomationExecutionId UNIQUEIDENTIFIER;
        DECLARE @RootExecutionId UNIQUEIDENTIFIER;
        DECLARE @ExecutionDepth INT;
        DECLARE @OccurredAt DATETIMEOFFSET;
        DECLARE @IsBusinessHour BIT;
        DECLARE @IsHoliday BIT;

        SELECT
            @QueueId = Id,
            @TicketId = TicketId,
            @QueueSourceType = QueueSourceType,
            @CandidateTriggerId = CandidateTriggerId,
            @SourceAutomationExecutionId = SourceAutomationExecutionId,
            @RootExecutionId = RootExecutionId,
            @ExecutionDepth = ExecutionDepth,
            @OccurredAt = OccurredAt,
            @IsBusinessHour = IsBusinessHour,
            @IsHoliday = IsHoliday
        FROM @PendingQueue
        WHERE RowId = @CurrentQueueRow;

        -- 3. Cascade Protection: If ExecutionDepth > MaxExecutionDepth, skip execution creation
        IF @ExecutionDepth > @MaxExecutionDepth
        BEGIN
            UPDATE dbo.AutomationTriggerQueueSummary
            SET Status = 'SKIPPED',
                SkipReason = 'SKIPPED_MAX_DEPTH',
                ProcessedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
            WHERE Id = @QueueId;

            SET @EvaluatedCount = @EvaluatedCount + 1;
            SET @CurrentQueueRow = @CurrentQueueRow + 1;
            CONTINUE;
        END;

        -- 4. Determine EventType & ExecutionMode
        DECLARE @EventType VARCHAR(50) = NULL;

        IF @QueueSourceType = 'TIME_TRIGGER'
        BEGIN
            SET @EventType = 'TIME_TRIGGER';
        END
        ELSE
        BEGIN
            SELECT TOP 1 @EventType = NewValue
            FROM dbo.AutomationTriggerQueueDelta WITH (NOLOCK)
            WHERE QueueSummaryId = @QueueId
              AND FieldSource = 'EVENT'
              AND FieldCode = 'event';

            IF @EventType IS NULL
                SET @EventType = 'UNKNOWN';
        END;

        DECLARE @ExecutionMode VARCHAR(20) = 'FIRST_MATCH';
        SELECT TOP 1 @ExecutionMode = ExecutionMode
        FROM dbo.AutomationEventSettings WITH (NOLOCK)
        WHERE EventType = @EventType AND IsActive = 1;

        IF @ExecutionMode IS NULL
            SET @ExecutionMode = 'FIRST_MATCH';

        -- 5. Candidate Triggers
        DELETE FROM @CandidateTriggers;

        IF @CandidateTriggerId IS NOT NULL
        BEGIN
            INSERT INTO @CandidateTriggers (TriggerRowId, TriggerId, Priority)
            SELECT 1, t.Id, t.Priority
            FROM dbo.AutomationTriggers t WITH (NOLOCK)
            WHERE t.Id = @CandidateTriggerId AND t.IsActive = 1;
        END
        ELSE
        BEGIN
            INSERT INTO @CandidateTriggers (TriggerRowId, TriggerId, Priority)
            SELECT 
                ROW_NUMBER() OVER (ORDER BY t.Priority ASC, t.CreatedAt ASC),
                t.Id, 
                t.Priority
            FROM dbo.AutomationTriggers t WITH (NOLOCK)
            WHERE t.EventType = @EventType AND t.IsActive = 1;
        END;

        DECLARE @TotalTriggers INT = (SELECT COUNT(*) FROM @CandidateTriggers);
        DECLARE @CurrentTriggerRow INT = 1;
        DECLARE @AnyTriggerMatched BIT = 0;

        WHILE @CurrentTriggerRow <= @TotalTriggers
        BEGIN
            DECLARE @TriggerId UNIQUEIDENTIFIER;
            SELECT @TriggerId = TriggerId
            FROM @CandidateTriggers
            WHERE TriggerRowId = @CurrentTriggerRow;

            -- Evaluate Blocks for this trigger
            DELETE FROM @TriggerBlocks;

            INSERT INTO @TriggerBlocks (BlockRowId, BlockId, LogicalOperator)
            SELECT 
                ROW_NUMBER() OVER (ORDER BY b.BlockOrder ASC),
                b.Id, 
                b.LogicalOperator
            FROM dbo.AutomationTriggerBlocks b WITH (NOLOCK)
            WHERE b.TriggerId = @TriggerId;

            DECLARE @TotalBlocks INT = (SELECT COUNT(*) FROM @TriggerBlocks);
            DECLARE @TriggerMatched BIT = 1;

            IF @TotalBlocks > 0
            BEGIN
                DECLARE @CurrentBlockRow INT = 1;
                DECLARE @HasOrSuccess BIT = 0;
                DECLARE @HasAndFailure BIT = 0;

                WHILE @CurrentBlockRow <= @TotalBlocks
                BEGIN
                    DECLARE @BlockId UNIQUEIDENTIFIER;
                    DECLARE @BlockOp VARCHAR(10);
                    SELECT @BlockId = BlockId, @BlockOp = LogicalOperator
                    FROM @TriggerBlocks
                    WHERE BlockRowId = @CurrentBlockRow;

                    -- Evaluate Rules in this block
                    DELETE FROM @BlockRules;

                    INSERT INTO @BlockRules (RuleRowId, RuleId, FieldSource, FieldCode, Operator, Value)
                    SELECT 
                        ROW_NUMBER() OVER (ORDER BY r.RuleOrder ASC),
                        r.Id, 
                        r.FieldSource, 
                        r.FieldCode, 
                        r.Operator, 
                        r.Value
                    FROM dbo.AutomationTriggerRules r WITH (NOLOCK)
                    WHERE r.TriggerBlockId = @BlockId;

                    DECLARE @TotalRules INT = (SELECT COUNT(*) FROM @BlockRules);
                    DECLARE @CurrentRuleRow INT = 1;
                    DECLARE @BlockMatched BIT = 1;

                    WHILE @CurrentRuleRow <= @TotalRules
                    BEGIN
                        DECLARE @RuleId UNIQUEIDENTIFIER;
                        DECLARE @FieldSource VARCHAR(20);
                        DECLARE @FieldCode VARCHAR(100);
                        DECLARE @RuleOp VARCHAR(50);
                        DECLARE @ExpectedVal NVARCHAR(MAX);

                        SELECT
                            @RuleId = RuleId,
                            @FieldSource = FieldSource,
                            @FieldCode = FieldCode,
                            @RuleOp = UPPER(Operator),
                            @ExpectedVal = Value
                        FROM @BlockRules
                        WHERE RuleRowId = @CurrentRuleRow;

                        -- Fetch Actual Values from Delta
                        DECLARE @ActualOldVal NVARCHAR(MAX) = NULL;
                        DECLARE @ActualNewVal NVARCHAR(MAX) = NULL;

                        SELECT TOP 1
                            @ActualOldVal = OldValue,
                            @ActualNewVal = NewValue
                        FROM dbo.AutomationTriggerQueueDelta WITH (NOLOCK)
                        WHERE QueueSummaryId = @QueueId
                          AND (
                                (FieldSource = @FieldSource AND FieldCode = @FieldCode COLLATE DATABASE_DEFAULT)
                                OR (@FieldSource = 'DEFAULT' AND FieldCode = LOWER(@FieldCode) COLLATE DATABASE_DEFAULT)
                              );

                        -- Fallback for business hours/holidays if evaluated directly
                        IF @FieldCode IN ('isBusinessHour', 'is_business_hour')
                            SET @ActualNewVal = CAST(@IsBusinessHour AS NVARCHAR(MAX));
                        IF @FieldCode IN ('isHoliday', 'is_holiday')
                            SET @ActualNewVal = CAST(@IsHoliday AS NVARCHAR(MAX));

                        -- Evaluate rule operator
                        DECLARE @RuleMatched BIT = 0;

                        IF @RuleOp IN ('EQUALS', '=')
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) = UPPER(ISNULL(@ExpectedVal, ''))
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp IN ('NOT_EQUALS', '!=', '<>')
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) <> UPPER(ISNULL(@ExpectedVal, ''))
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'CONTAINS'
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) LIKE '%' + UPPER(ISNULL(@ExpectedVal, '')) + '%'
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'NOT_CONTAINS'
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) NOT LIKE '%' + UPPER(ISNULL(@ExpectedVal, '')) + '%'
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'STARTS_WITH'
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) LIKE UPPER(ISNULL(@ExpectedVal, '')) + '%'
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'ENDS_WITH'
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) LIKE '%' + UPPER(ISNULL(@ExpectedVal, ''))
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'CHANGED_TO'
                        BEGIN
                            IF UPPER(ISNULL(@ActualNewVal, '')) = UPPER(ISNULL(@ExpectedVal, ''))
                               AND (ISNULL(@ActualOldVal, '') <> ISNULL(@ActualNewVal, '') OR @ActualOldVal IS NULL)
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'CHANGED_FROM'
                        BEGIN
                            IF UPPER(ISNULL(@ActualOldVal, '')) = UPPER(ISNULL(@ExpectedVal, ''))
                               AND (ISNULL(@ActualOldVal, '') <> ISNULL(@ActualNewVal, '') OR @ActualNewVal IS NULL)
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'CHANGED'
                        BEGIN
                            IF ISNULL(@ActualOldVal, '') <> ISNULL(@ActualNewVal, '')
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'IS_EMPTY'
                        BEGIN
                            IF @ActualNewVal IS NULL OR LTRIM(RTRIM(@ActualNewVal)) = ''
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'IS_NOT_EMPTY'
                        BEGIN
                            IF @ActualNewVal IS NOT NULL AND LTRIM(RTRIM(@ActualNewVal)) <> ''
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp IN ('GREATER_THAN', '>')
                        BEGIN
                            IF TRY_CAST(@ActualNewVal AS DECIMAL(18,4)) > TRY_CAST(@ExpectedVal AS DECIMAL(18,4))
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp IN ('LESS_THAN', '<')
                        BEGIN
                            IF TRY_CAST(@ActualNewVal AS DECIMAL(18,4)) < TRY_CAST(@ExpectedVal AS DECIMAL(18,4))
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'IS_BUSINESS_HOUR'
                        BEGIN
                            IF ISNULL(@ActualNewVal, '0') = ISNULL(@ExpectedVal, '1')
                                SET @RuleMatched = 1;
                        END
                        ELSE IF @RuleOp = 'IS_HOLIDAY'
                        BEGIN
                            IF ISNULL(@ActualNewVal, '0') = ISNULL(@ExpectedVal, '1')
                                SET @RuleMatched = 1;
                        END;

                        -- Record rule audit in AutomationTriggerQueueRule
                        INSERT INTO dbo.AutomationTriggerQueueRule
                        (
                            QueueSummaryId,
                            TriggerId,
                            RuleId,
                            IsMatched,
                            EvaluatedAt
                        )
                        VALUES
                        (
                            @QueueId,
                            @TriggerId,
                            @RuleId,
                            @RuleMatched,
                            (SYSUTCDATETIME() AT TIME ZONE 'UTC')
                        );

                        IF @RuleMatched = 0
                        BEGIN
                            SET @BlockMatched = 0;
                        END;

                        SET @CurrentRuleRow = @CurrentRuleRow + 1;
                    END;

                    -- Combine blocks
                    IF @BlockOp = 'OR'
                    BEGIN
                        IF @BlockMatched = 1
                            SET @HasOrSuccess = 1;
                    END
                    ELSE -- Default 'AND'
                    BEGIN
                        IF @BlockMatched = 0
                            SET @HasAndFailure = 1;
                    END;

                    SET @CurrentBlockRow = @CurrentBlockRow + 1;
                END;

                -- Overall Trigger decision
                IF @HasAndFailure = 1
                    SET @TriggerMatched = 0;
                ELSE IF @HasOrSuccess = 1
                    SET @TriggerMatched = 1;
            END;

            -- If matched, create Execution and ExecutionActions
            IF @TriggerMatched = 1
            BEGIN
                SET @AnyTriggerMatched = 1;

                DECLARE @NewExecutionId UNIQUEIDENTIFIER = NEWID();
                DECLARE @CurrentRootId UNIQUEIDENTIFIER = ISNULL(@RootExecutionId, @NewExecutionId);

                INSERT INTO dbo.AutomationExecutions
                (
                    Id,
                    QueueSummaryId,
                    TriggerId,
                    TicketId,
                    ParentExecutionId,
                    RootExecutionId,
                    ExecutionDepth,
                    Status,
                    CreatedAt
                )
                VALUES
                (
                    @NewExecutionId,
                    @QueueId,
                    @TriggerId,
                    @TicketId,
                    @SourceAutomationExecutionId,
                    @CurrentRootId,
                    @ExecutionDepth,
                    'PENDING',
                    (SYSUTCDATETIME() AT TIME ZONE 'UTC')
                );

                -- Snapshot actions from trigger definition
                INSERT INTO dbo.AutomationExecutionActions
                (
                    Id,
                    AutomationExecutionId,
                    ActionOrder,
                    ActionType,
                    ActionValue,
                    Status,
                    CreatedAt
                )
                SELECT
                    NEWID(),
                    @NewExecutionId,
                    act.ActionOrder,
                    act.ActionType,
                    act.ActionValue,
                    'PENDING',
                    (SYSUTCDATETIME() AT TIME ZONE 'UTC')
                FROM dbo.AutomationTriggerActions act WITH (NOLOCK)
                WHERE act.TriggerId = @TriggerId
                ORDER BY act.ActionOrder ASC;

                SET @ExecutionsCreatedCount = @ExecutionsCreatedCount + 1;

                -- If FIRST_MATCH mode, break the trigger loop
                IF @ExecutionMode = 'FIRST_MATCH'
                    BREAK;
            END;

            SET @CurrentTriggerRow = @CurrentTriggerRow + 1;
        END;

        -- 6. Mark Queue Summary Completed
        UPDATE dbo.AutomationTriggerQueueSummary
        SET Status = 'COMPLETED',
            SkipReason = CASE WHEN @AnyTriggerMatched = 0 THEN 'NO_MATCH' ELSE NULL END,
            ProcessedAt = (SYSUTCDATETIME() AT TIME ZONE 'UTC')
        WHERE Id = @QueueId;

        SET @EvaluatedCount = @EvaluatedCount + 1;
        SET @CurrentQueueRow = @CurrentQueueRow + 1;
    END;

    SELECT 
        @EvaluatedCount AS EvaluatedCount, 
        @ExecutionsCreatedCount AS ExecutionsCreatedCount;
END;
GO
