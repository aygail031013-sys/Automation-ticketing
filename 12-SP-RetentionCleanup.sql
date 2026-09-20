-- =================================================================================================
-- OneDesk Automation - bounded queue and audit retention
-- Invoke repeatedly from a low-frequency job until each Deleted* count returns zero.
-- =================================================================================================
USE OneDeskDb;
GO
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.ganymede_automationRetentionCleanupBatch
    @BatchSize INT = 5000,
    @QueueRetentionDays INT = NULL,
    @RuleAuditRetentionDays INT = NULL,
    @AuditRetentionDays INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    SET @BatchSize = CASE WHEN @BatchSize BETWEEN 1 AND 50000 THEN @BatchSize ELSE 5000 END;
    SET @QueueRetentionDays = COALESCE
    (
        @QueueRetentionDays,
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'QueueRetentionDays'),
        7
    );
    SET @RuleAuditRetentionDays = COALESCE
    (
        @RuleAuditRetentionDays,
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'RuleAuditRetentionDays'),
        30
    );
    SET @AuditRetentionDays = COALESCE
    (
        @AuditRetentionDays,
        (SELECT TRY_CONVERT(INT, SettingValue) FROM dbo.AutomationSettings WHERE SettingKey = 'AuditRetentionDays'),
        365
    );

    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @QueueCutoff DATETIMEOFFSET = DATEADD(DAY, -@QueueRetentionDays, @Now);
    DECLARE @RuleAuditCutoff DATETIMEOFFSET = DATEADD(DAY, -@RuleAuditRetentionDays, @Now);
    DECLARE @AuditCutoff DATETIMEOFFSET = DATEADD(DAY, -@AuditRetentionDays, @Now);
    DECLARE @DeletedRuleAudit INT = 0;
    DECLARE @DeletedQueueActions INT = 0;
    DECLARE @DeletedQueueSummaries INT = 0;
    DECLARE @DeletedAudit INT = 0;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dbo.AutomationEvaluationRules
        WHERE Id IN
        (
            SELECT TOP (@BatchSize) Id
            FROM dbo.AutomationEvaluationRules WITH (READPAST)
            WHERE EvaluatedAt < @RuleAuditCutoff
            ORDER BY EvaluatedAt, Id
        );
        SET @DeletedRuleAudit = @@ROWCOUNT;

        DELETE FROM dbo.AutomationTriggerQueueAction
        WHERE Id IN
        (
            SELECT TOP (@BatchSize) Id
            FROM dbo.AutomationTriggerQueueAction WITH (READPAST)
            WHERE Status IN ('SUCCEEDED', 'FAILED')
              AND CompletedAt < @QueueCutoff
            ORDER BY CompletedAt, Id
        );
        SET @DeletedQueueActions = @@ROWCOUNT;

        DELETE queue_trigger
        FROM dbo.AutomationTriggerQueueTrigger AS queue_trigger
        WHERE queue_trigger.Id IN
        (
            SELECT TOP (@BatchSize) candidate.Id
            FROM dbo.AutomationTriggerQueueTrigger AS candidate WITH (READPAST)
            INNER JOIN dbo.AutomationTriggerQueueSummary AS summary
                ON summary.Id = candidate.QueueSummaryId
            WHERE summary.Status IN ('COMPLETED', 'SKIPPED', 'FAILED')
              AND summary.ProcessedAt < @QueueCutoff
            ORDER BY summary.ProcessedAt, candidate.Id
        );

        DELETE summary
        FROM dbo.AutomationTriggerQueueSummary AS summary
        WHERE summary.Id IN
        (
            SELECT TOP (@BatchSize) candidate.Id
            FROM dbo.AutomationTriggerQueueSummary AS candidate WITH (READPAST)
            WHERE candidate.Status IN ('COMPLETED', 'SKIPPED', 'FAILED')
              AND candidate.ProcessedAt < @QueueCutoff
              AND NOT EXISTS
              (
                  SELECT 1 FROM dbo.AutomationTriggerQueueTrigger AS queue_trigger
                  WHERE queue_trigger.QueueSummaryId = candidate.Id
              )
            ORDER BY candidate.ProcessedAt, candidate.Id
        );
        SET @DeletedQueueSummaries = @@ROWCOUNT;

        -- Summary audit is retained longer than detailed rule audit. Child-first batches preserve
        -- referential integrity and keep every transaction bounded.
        DELETE FROM dbo.AutomationEvaluationBlocks
        WHERE Id IN
        (
            SELECT TOP (@BatchSize) block.Id
            FROM dbo.AutomationEvaluationBlocks AS block WITH (READPAST)
            INNER JOIN dbo.AutomationEvaluations AS evaluation ON evaluation.Id = block.EvaluationId
            WHERE evaluation.EvaluatedAt < @AuditCutoff
            ORDER BY evaluation.EvaluatedAt, block.Id
        );

        DELETE FROM dbo.AutomationEvaluations
        WHERE Id IN
        (
            SELECT TOP (@BatchSize) evaluation.Id
            FROM dbo.AutomationEvaluations AS evaluation WITH (READPAST)
            WHERE evaluation.EvaluatedAt < @AuditCutoff
              AND NOT EXISTS
              (
                  SELECT 1 FROM dbo.AutomationEvaluationBlocks AS block
                  WHERE block.EvaluationId = evaluation.Id
              )
              AND NOT EXISTS
              (
                  SELECT 1 FROM dbo.AutomationEvaluationRules AS rule_audit
                  WHERE rule_audit.EvaluationId = evaluation.Id
              )
              AND NOT EXISTS
              (
                  SELECT 1 FROM dbo.AutomationTriggerQueueTrigger AS queue_trigger
                  WHERE queue_trigger.EvaluationId = evaluation.Id
              )
            ORDER BY evaluation.EvaluatedAt, evaluation.Id
        );
        SET @DeletedAudit = @@ROWCOUNT;

        DELETE FROM dbo.AutomationActionHistories
        WHERE Id IN
        (
            SELECT TOP (@BatchSize) Id
            FROM dbo.AutomationActionHistories WITH (READPAST)
            WHERE CompletedAt < @AuditCutoff
            ORDER BY CompletedAt, Id
        );

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        @DeletedRuleAudit AS DeletedRuleAudit,
        @DeletedQueueActions AS DeletedQueueActions,
        @DeletedQueueSummaries AS DeletedQueueSummaries,
        @DeletedAudit AS DeletedEvaluationAudit;
END;
GO
