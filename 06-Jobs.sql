-- =================================================================================================
-- OneDesk Automation v1.0 - Phase 6: Scheduler & SQL Agent Jobs
-- =================================================================================================
USE OneDeskDb;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

-- -------------------------------------------------------------------------------------------------
-- 1. Unified Automation Engine Dispatcher Procedure
-- -------------------------------------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dbo.ganymede_automationRunScheduler
    @RunTimeTriggerScanner BIT = 1,
    @RunCollector BIT = 1,
    @RunEvaluator BIT = 1,
    @BatchSize INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Collected INT = 0;
    DECLARE @Evaluated INT = 0;
    DECLARE @ExecutionsCreated INT = 0;
    DECLARE @TimeTriggersQueued INT = 0;

    -- Step 1: Time Trigger Scanner
    IF @RunTimeTriggerScanner = 1
    BEGIN
        EXEC dbo.ganymede_automationTimeTriggerScanBatch
            @BatchSize = @BatchSize,
            @QueuedCount = @TimeTriggersQueued OUTPUT;
    END;

    -- Step 2: Activity Log Collector
    IF @RunCollector = 1
    BEGIN
        EXEC dbo.ganymede_automationTriggerQueueCollectBatch
            @BatchSize = @BatchSize,
            @CollectedCount = @Collected OUTPUT;
    END;

    -- Step 3: Rule Evaluator
    IF @RunEvaluator = 1
    BEGIN
        EXEC dbo.ganymede_automationEvaluateBatch
            @BatchSize = @BatchSize,
            @EvaluatedCount = @Evaluated OUTPUT,
            @ExecutionsCreatedCount = @ExecutionsCreated OUTPUT;
    END;

    SELECT
        @TimeTriggersQueued AS TimeTriggersQueued,
        @Collected AS ItemsCollected,
        @Evaluated AS ItemsEvaluated,
        @ExecutionsCreated AS ExecutionsCreated;
END;
GO

-- -------------------------------------------------------------------------------------------------
-- 2. SQL Server Agent Jobs Registration (Collector, Evaluator, Time Trigger Scanner)
-- -------------------------------------------------------------------------------------------------
USE msdb;
GO

BEGIN TRY
    -- 2.1 Job: OneDesk Automation - History Collector (Every 10 seconds)
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'OneDesk_Automation_HistoryCollector')
    BEGIN
        EXEC sp_delete_job @job_name = 'OneDesk_Automation_HistoryCollector';
    END;

    DECLARE @CollectorJobId BINARY(16);
    EXEC sp_add_job 
        @job_name = 'OneDesk_Automation_HistoryCollector',
        @enabled = 1,
        @description = 'Collects new TicketActivityLogs into AutomationTriggerQueueSummary every 10s',
        @job_id = @CollectorJobId OUTPUT;

    EXEC sp_add_jobstep
        @job_name = 'OneDesk_Automation_HistoryCollector',
        @step_name = 'Run_Collector',
        @subsystem = 'TSQL',
        @command = 'EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize = 200;',
        @database_name = 'OneDeskDb',
        @on_success_action = 1; -- Quit with success

    DECLARE @CollectorScheduleId INT;
    EXEC sp_add_schedule
        @schedule_name = 'Schedule_Every_10_Seconds',
        @freq_type = 4, -- Daily
        @freq_interval = 1,
        @freq_subday_type = 2, -- Seconds
        @freq_subday_interval = 10,
        @schedule_id = @CollectorScheduleId OUTPUT;

    EXEC sp_attach_schedule
        @job_name = 'OneDesk_Automation_HistoryCollector',
        @schedule_name = 'Schedule_Every_10_Seconds';

    EXEC sp_add_jobserver
        @job_name = 'OneDesk_Automation_HistoryCollector',
        @server_name = '(local)';

    PRINT 'SQL Agent Job: OneDesk_Automation_HistoryCollector registered successfully.';
END TRY
BEGIN CATCH
    PRINT 'Notice: SQL Server Agent Collector job registration skipped or not permitted: ' + ERROR_MESSAGE();
END CATCH;
GO

BEGIN TRY
    -- 2.2 Job: OneDesk Automation - Rule Evaluator (Every 10 seconds)
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'OneDesk_Automation_RuleEvaluator')
    BEGIN
        EXEC sp_delete_job @job_name = 'OneDesk_Automation_RuleEvaluator';
    END;

    DECLARE @EvaluatorJobId BINARY(16);
    EXEC sp_add_job 
        @job_name = 'OneDesk_Automation_RuleEvaluator',
        @enabled = 1,
        @description = 'Evaluates pending triggers and creates executions every 10s',
        @job_id = @EvaluatorJobId OUTPUT;

    EXEC sp_add_jobstep
        @job_name = 'OneDesk_Automation_RuleEvaluator',
        @step_name = 'Run_Evaluator',
        @subsystem = 'TSQL',
        @command = 'EXEC dbo.ganymede_automationEvaluateBatch @BatchSize = 100;',
        @database_name = 'OneDeskDb',
        @on_success_action = 1;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'Schedule_Every_10_Seconds')
    BEGIN
        EXEC sp_add_schedule
            @schedule_name = 'Schedule_Every_10_Seconds',
            @freq_type = 4,
            @freq_interval = 1,
            @freq_subday_type = 2,
            @freq_subday_interval = 10;
    END;

    EXEC sp_attach_schedule
        @job_name = 'OneDesk_Automation_RuleEvaluator',
        @schedule_name = 'Schedule_Every_10_Seconds';

    EXEC sp_add_jobserver
        @job_name = 'OneDesk_Automation_RuleEvaluator',
        @server_name = '(local)';

    PRINT 'SQL Agent Job: OneDesk_Automation_RuleEvaluator registered successfully.';
END TRY
BEGIN CATCH
    PRINT 'Notice: SQL Server Agent Evaluator job registration skipped or not permitted: ' + ERROR_MESSAGE();
END CATCH;
GO

BEGIN TRY
    -- 2.3 Job: OneDesk Automation - Time Trigger Scanner (Every 1 hour)
    IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = 'OneDesk_Automation_TimeTriggerScanner')
    BEGIN
        EXEC sp_delete_job @job_name = 'OneDesk_Automation_TimeTriggerScanner';
    END;

    DECLARE @ScannerJobId BINARY(16);
    EXEC sp_add_job 
        @job_name = 'OneDesk_Automation_TimeTriggerScanner',
        @enabled = 1,
        @description = 'Scans active time triggers hourly without polluting activity logs',
        @job_id = @ScannerJobId OUTPUT;

    EXEC sp_add_jobstep
        @job_name = 'OneDesk_Automation_TimeTriggerScanner',
        @step_name = 'Run_TimeTriggerScanner',
        @subsystem = 'TSQL',
        @command = 'EXEC dbo.ganymede_automationTimeTriggerScanBatch @BatchSize = 500;',
        @database_name = 'OneDeskDb',
        @on_success_action = 1;

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysschedules WHERE name = 'Schedule_Every_1_Hour')
    BEGIN
        EXEC sp_add_schedule
            @schedule_name = 'Schedule_Every_1_Hour',
            @freq_type = 4, -- Daily
            @freq_interval = 1,
            @freq_subday_type = 8, -- Hours
            @freq_subday_interval = 1;
    END;

    EXEC sp_attach_schedule
        @job_name = 'OneDesk_Automation_TimeTriggerScanner',
        @schedule_name = 'Schedule_Every_1_Hour';

    EXEC sp_add_jobserver
        @job_name = 'OneDesk_Automation_TimeTriggerScanner',
        @server_name = '(local)';

    PRINT 'SQL Agent Job: OneDesk_Automation_TimeTriggerScanner registered successfully.';
END TRY
BEGIN CATCH
    PRINT 'Notice: SQL Server Agent Scanner job registration skipped or not permitted: ' + ERROR_MESSAGE();
END CATCH;
GO

USE OneDeskDb;
GO
