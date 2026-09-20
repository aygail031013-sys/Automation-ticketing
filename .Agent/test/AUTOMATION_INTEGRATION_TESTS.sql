-- =================================================================================================
-- Executable acceptance tests for AUTOMATION_TESTING_PLAN.md
-- SQL Server / sqlcmd. All fixture, configuration, and runtime writes are rolled back.
-- =================================================================================================
USE OneDeskDb;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @PersistTestData BIT = COALESCE(TRY_CONVERT(BIT, SESSION_CONTEXT(N'PersistAutomationTestData')), 0);
    DECLARE @TestRunId UNIQUEIDENTIFIER = NEWID();
    DECLARE @TestRunToken VARCHAR(8) = LEFT(REPLACE(CONVERT(VARCHAR(36), @TestRunId), '-', ''), 8);
    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';
    DECLARE @ActorId UNIQUEIDENTIFIER = NEWID();
    DECLARE @ContactId UNIQUEIDENTIFIER;
    DECLARE @CompanyId UNIQUEIDENTIFIER;
    DECLARE @GroupDefault UNIQUEIDENTIFIER;
    DECLARE @GroupEscalation UNIQUEIDENTIFIER;
    DECLARE @GroupVip UNIQUEIDENTIFIER;
    DECLARE @AgentAvailable UNIQUEIDENTIFIER;
    DECLARE @AgentUnavailable UNIQUEIDENTIFIER;
    DECLARE @CustomDepartment UNIQUEIDENTIFIER;

    DECLARE @CreateTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @StatusTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @PriorityTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @GroupTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @AssigneeTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @RequesterTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @AgentTicket UNIQUEIDENTIFIER = NEWID();
    DECLARE @ScheduleTicket UNIQUEIDENTIFIER = NEWID();

    CREATE TABLE #Results
    (
        TestCaseId VARCHAR(20) NOT NULL,
        OperationId UNIQUEIDENTIFIER NULL,
        TicketId UNIQUEIDENTIFIER NULL,
        QueueSummaryId BIGINT NULL,
        Result VARCHAR(10) NOT NULL,
        Evidence NVARCHAR(1000) NOT NULL
    );

    CREATE TABLE #OriginalTriggerState
    (
        TriggerId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY,
        IsActive BIT NOT NULL
    );
    INSERT #OriginalTriggerState (TriggerId, IsActive)
    SELECT Id, IsActive FROM dbo.AutomationTriggers;

    -- Isolate this suite from sample/business triggers while preserving all changes via rollback.
    UPDATE dbo.AutomationTriggers SET IsActive = 0;

    MERGE dbo.AutomationEventSettings AS target
    USING
    (
        VALUES
            ('TICKET_CREATED', 'FIRST_MATCH'),
            ('STATUS_CHANGED', 'ALL_MATCH'),
            ('PRIORITY_CHANGED', 'ALL_MATCH'),
            ('GROUP_CHANGED', 'ALL_MATCH'),
            ('ASSIGNEE_CHANGED', 'ALL_MATCH'),
            ('REQUESTER_REPLIED', 'ALL_MATCH'),
            ('AGENT_REPLIED', 'ALL_MATCH'),
            ('SCHEDULE_DUE', 'ALL_MATCH')
    ) AS source(EventType, ExecutionMode)
    ON target.EventType = source.EventType
    WHEN MATCHED THEN UPDATE SET ExecutionMode = source.ExecutionMode, IsActive = 1, UpdatedAt = @Now
    WHEN NOT MATCHED THEN INSERT (EventType, ExecutionMode, IsActive)
        VALUES (source.EventType, source.ExecutionMode, 1);

    -- Deterministic entity fixtures from the common rule test configuration. Reuse the persistent
    -- common-rule seed when present so this transactional suite remains safe to run before or after it.
    SELECT @CompanyId = Id FROM dbo.Companies WHERE Name = N'[TEST] VIP Company';
    IF @CompanyId IS NULL
    BEGIN
        SET @CompanyId = NEWID();
        INSERT dbo.Companies (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@CompanyId, N'[TEST] VIP Company', N'AUTOMATION_TEST', N'AUTOMATION_TEST');
    END;
    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyDomains WHERE CompanyId = @CompanyId AND Domain = 'vip.automation.test')
        INSERT dbo.CompanyDomains (CompanyId, Domain, CreatedBy)
        VALUES (@CompanyId, 'vip.automation.test', N'AUTOMATION_TEST');

    SELECT @ContactId = Id FROM dbo.Contacts WHERE PrimaryEmail = N'active-requester@automation.test';
    IF @ContactId IS NULL
    BEGIN
        SET @ContactId = NEWID();
        INSERT dbo.Contacts
            (Id, Name, PrimaryEmail, PrimaryCompanyId, Status, CreatedBy, UpdatedBy)
        VALUES
            (@ContactId, N'[TEST] Active Requester', N'active-requester@automation.test', @CompanyId, 1,
             N'AUTOMATION_TEST', N'AUTOMATION_TEST');
    END;

    SELECT @GroupDefault = Id FROM dbo.Groups WHERE Name = N'[TEST] Default';
    IF @GroupDefault IS NULL
    BEGIN
        SET @GroupDefault = NEWID();
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupDefault, N'[TEST] Default', N'AUTOMATION_TEST', N'AUTOMATION_TEST');
    END;
    SELECT @GroupEscalation = Id FROM dbo.Groups WHERE Name = N'[TEST] Escalation';
    IF @GroupEscalation IS NULL
    BEGIN
        SET @GroupEscalation = NEWID();
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupEscalation, N'[TEST] Escalation', N'AUTOMATION_TEST', N'AUTOMATION_TEST');
    END;
    SELECT @GroupVip = Id FROM dbo.Groups WHERE Name = N'[TEST] VIP';
    IF @GroupVip IS NULL
    BEGIN
        SET @GroupVip = NEWID();
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupVip, N'[TEST] VIP', N'AUTOMATION_TEST', N'AUTOMATION_TEST');
    END;

    SELECT @AgentAvailable = Id FROM dbo.Agents WHERE Email = N'available-agent@automation.test';
    IF @AgentAvailable IS NULL
    BEGIN
        SET @AgentAvailable = NEWID();
        INSERT dbo.Agents (Id, FullName, Email, Status, TicketAvailability, CreatedBy)
        VALUES (@AgentAvailable, N'[TEST] Available Agent', N'available-agent@automation.test', 1, 1, N'AUTOMATION_TEST');
    END;
    SELECT @AgentUnavailable = Id FROM dbo.Agents WHERE Email = N'unavailable-agent@automation.test';
    IF @AgentUnavailable IS NULL
    BEGIN
        SET @AgentUnavailable = NEWID();
        INSERT dbo.Agents (Id, FullName, Email, Status, TicketAvailability, CreatedBy)
        VALUES (@AgentUnavailable, N'[TEST] Unavailable Agent', N'unavailable-agent@automation.test', 1, 0, N'AUTOMATION_TEST');
    END;
    IF NOT EXISTS (SELECT 1 FROM dbo.GroupAgents WHERE AgentId = @AgentAvailable AND GroupId = @GroupVip)
        INSERT dbo.GroupAgents (AgentId, GroupId, CreatedBy)
        VALUES (@AgentAvailable, @GroupVip, N'AUTOMATION_TEST');

    SELECT @CustomDepartment = Id FROM dbo.TicketFields WHERE FieldCode = 'CUSTOM_DEPARTMENT';
    IF @CustomDepartment IS NULL
    BEGIN
        SET @CustomDepartment = NEWID();
        INSERT dbo.TicketFields
        (
            Id, FieldCode, FieldLabelForCustomer, FieldLabelForAgent, FieldType, FieldCategory,
            CreatedBy, UpdatedBy
        )
        VALUES
        (
            @CustomDepartment, 'CUSTOM_DEPARTMENT', N'Department', N'Department',
            'SINGLE_LINE_TEXT', 'CUSTOM', N'AUTOMATION_TEST', N'AUTOMATION_TEST'
        );
    END;

    INSERT dbo.Tickets
    (
        Id, TicketNo, RequesterContactId, RequesterCompanyId, GroupId, AssignedAgentId,
        Subject, Description, PlainDescription, Source, Status, Priority, StatusChangedAt,
        CreatedBy, CreatedAt, UpdatedBy, UpdatedAt, IsDeleted
    )
    VALUES
        (@CreateTicket, '#AT' + @TestRunToken + 'C', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Creation routing', N'test', N'test', 'PORTAL_AGENT', 'OPEN', 'URGENT', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@StatusTicket, '#AT' + @TestRunToken + 'S', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Status event', N'test', N'test', 'PORTAL_AGENT', 'OPEN', 'HIGH', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@PriorityTicket, '#AT' + @TestRunToken + 'P', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Priority event', N'test', N'test', 'PORTAL_AGENT', 'OPEN', 'HIGH', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@GroupTicket, '#AT' + @TestRunToken + 'G', @ContactId, @CompanyId, @GroupDefault, @AgentUnavailable,
         N'[' + @TestRunToken + N'] Group event', N'test', N'test', 'PORTAL_AGENT', 'OPEN', 'LOW', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@AssigneeTicket, '#AT' + @TestRunToken + 'A', @ContactId, @CompanyId, @GroupDefault, @AgentUnavailable,
         N'[' + @TestRunToken + N'] Assignee event', N'test', N'test', 'PORTAL_AGENT', 'PENDING', 'LOW', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@RequesterTicket, '#AT' + @TestRunToken + 'R', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Requester reply', N'test', N'test', 'PORTAL_AGENT', 'PENDING', 'LOW', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@AgentTicket, '#AT' + @TestRunToken + 'Y', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Agent reply', N'test', N'test', 'PORTAL_AGENT', 'OPEN', 'LOW', @Now,
         N'AUTOMATION_TEST', @Now, N'AUTOMATION_TEST', @Now, 0),
        (@ScheduleTicket, '#AT' + @TestRunToken + 'T', @ContactId, @CompanyId, @GroupDefault, @AgentAvailable,
         N'[' + @TestRunToken + N'] Schedule event', N'test', N'test', 'PORTAL_AGENT', 'RESOLVED', 'LOW', DATEADD(HOUR, -49, @Now),
         N'AUTOMATION_TEST', DATEADD(HOUR, -72, @Now), N'AUTOMATION_TEST', DATEADD(HOUR, -49, @Now), 0);

    INSERT dbo.TicketFieldValues
    (
        Id, TicketId, TicketFieldId, TextValue, CreatedBy, UpdatedBy
    )
    VALUES
    (
        NEWID(), @CreateTicket, @CustomDepartment, N'CUSTOMER_SERVICE',
        N'AUTOMATION_TEST', N'AUTOMATION_TEST'
    );

    -- Configuration -------------------------------------------------------------------------------
    DECLARE @CrtVip UNIQUEIDENTIFIER = NEWID(), @CrtEsc UNIQUEIDENTIFIER = NEWID(), @CrtDefault UNIQUEIDENTIFIER = NEWID();
    DECLARE @StatusResolved UNIQUEIDENTIFIER = NEWID();
    DECLARE @PriorityRoute UNIQUEIDENTIFIER = NEWID(), @PriorityNotify UNIQUEIDENTIFIER = NEWID();
    DECLARE @GroupAssign UNIQUEIDENTIFIER = NEWID(), @AssigneeOpen UNIQUEIDENTIFIER = NEWID();
    DECLARE @RequesterOpen UNIQUEIDENTIFIER = NEWID(), @AgentWait UNIQUEIDENTIFIER = NEWID();
    DECLARE @ScheduleClose UNIQUEIDENTIFIER = NEWID();

    INSERT dbo.AutomationTriggers (Id, Name, EventType, Priority, IsActive)
    VALUES
        (@CrtVip, N'[RUN ' + @TestRunToken + N'] CRT_URGENT_VIP', 'TICKET_CREATED', 9010, 1),
        (@CrtEsc, N'[RUN ' + @TestRunToken + N'] CRT_URGENT_ESCALATION', 'TICKET_CREATED', 9020, 1),
        (@CrtDefault, N'[RUN ' + @TestRunToken + N'] CRT_DEFAULT_ROUTE', 'TICKET_CREATED', 9090, 1),
        (@StatusResolved, N'[RUN ' + @TestRunToken + N'] UPD_STATUS_RESOLVED_HIGH', 'STATUS_CHANGED', 9100, 1),
        (@PriorityRoute, N'[RUN ' + @TestRunToken + N'] UPD_PRIORITY_URGENT_ROUTE', 'PRIORITY_CHANGED', 9110, 1),
        (@PriorityNotify, N'[RUN ' + @TestRunToken + N'] UPD_PRIORITY_URGENT_NOTIFY', 'PRIORITY_CHANGED', 9120, 1),
        (@GroupAssign, N'[RUN ' + @TestRunToken + N'] UPD_GROUP_VIP_ASSIGN', 'GROUP_CHANGED', 9130, 1),
        (@AssigneeOpen, N'[RUN ' + @TestRunToken + N'] UPD_ASSIGNEE_AVAILABLE_OPEN', 'ASSIGNEE_CHANGED', 9140, 1),
        (@RequesterOpen, N'[RUN ' + @TestRunToken + N'] UPD_REQUESTER_REPLY_REOPEN', 'REQUESTER_REPLIED', 9150, 1),
        (@AgentWait, N'[RUN ' + @TestRunToken + N'] UPD_AGENT_REPLY_WAIT', 'AGENT_REPLIED', 9160, 1),
        (@ScheduleClose, N'[RUN ' + @TestRunToken + N'] SCH_RESOLVED_CLOSE_48H', 'SCHEDULE_DUE', 9210, 1);

    DECLARE @Block UNIQUEIDENTIFIER;
    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @CrtVip, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_PRIORITY', 'EQUALS', 'URGENT'),
        (@Block, 20, 'CUSTOM_FIELD', 'CUSTOM_DEPARTMENT', 'EQUALS', 'CUSTOMER_SERVICE'),
        (@Block, 30, 'REQUESTER', 'STATUS', 'EQUALS', '1');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField) VALUES
        (@CrtVip, 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupVip) + N'"}', 'AUTOMATION', 'groupId'),
        (@CrtVip, 20, 'SET_PRIORITY', N'{"priority":"HIGH"}', 'AUTOMATION', 'priority');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @CrtEsc, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_PRIORITY', 'EQUALS', 'URGENT'),
        (@Block, 20, 'REQUESTER', 'STATUS', 'EQUALS', '1');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@CrtEsc, 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @CrtDefault, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
        VALUES (@Block, 10, 'TICKET', 'DEFAULT_SOURCE', 'IN', 'PORTAL_AGENT,PORTAL_ONECHAT');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@CrtDefault, 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupDefault) + N'"}', 'AUTOMATION', 'groupId');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @StatusResolved, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_STATUS', 'CHANGED_TO', 'RESOLVED'),
        (@Block, 20, 'TICKET', 'DEFAULT_PRIORITY', 'IN', 'HIGH,URGENT');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@StatusResolved, 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @PriorityRoute, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_PRIORITY', 'CHANGED_TO', 'URGENT'),
        (@Block, 20, 'TICKET', 'DEFAULT_STATUS', 'NOT_EQUALS', 'CLOSED'),
        (@Block, 30, 'REQUESTER', 'STATUS', 'EQUALS', '1');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@PriorityRoute, 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @PriorityNotify, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_PRIORITY', 'CHANGED_TO', 'URGENT'),
        (@Block, 20, 'COMPANY', 'DOMAIN', 'EQUALS', 'vip.automation.test');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@PriorityNotify, 10, 'SEND_NOTIFICATION', N'{"template":"URGENT_VIP_TICKET"}', 'APPLICATION', NULL);

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @GroupAssign, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_GROUP', 'CHANGED_TO', CONVERT(NVARCHAR(36), @GroupVip)),
        (@Block, 20, 'ASSIGNED_AGENT', 'TICKET_AVAILABILITY', 'EQUALS', '0');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@GroupAssign, 10, 'ASSIGN_AGENT', N'{"agentId":"' + CONVERT(NVARCHAR(36), @AgentAvailable) + N'"}', 'AUTOMATION', 'assignedAgentId');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @AssigneeOpen, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_AGENT', 'CHANGED_TO', CONVERT(NVARCHAR(36), @AgentAvailable)),
        (@Block, 20, 'ASSIGNED_AGENT', 'STATUS', 'EQUALS', '1'),
        (@Block, 30, 'ASSIGNED_AGENT', 'TICKET_AVAILABILITY', 'EQUALS', '1'),
        (@Block, 40, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', 'PENDING');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@AssigneeOpen, 10, 'SET_STATUS', N'{"status":"OPEN"}', 'AUTOMATION', 'status');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @RequesterOpen, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_STATUS', 'IN', 'PENDING,RESOLVED'),
        (@Block, 20, 'REQUESTER', 'STATUS', 'EQUALS', '1');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@RequesterOpen, 10, 'SET_STATUS', N'{"status":"OPEN"}', 'AUTOMATION', 'status');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @AgentWait, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', 'OPEN'),
        (@Block, 20, 'TICKET', 'DEFAULT_PRIORITY', 'NOT_EQUALS', 'URGENT');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@AgentWait, 10, 'SET_STATUS', N'{"status":"PENDING"}', 'AUTOMATION', 'status');

    SET @Block = NEWID(); INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, LogicalOperator) VALUES (@Block, @ScheduleClose, 'AND');
    INSERT dbo.AutomationTriggerRules (TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value) VALUES
        (@Block, 10, 'TIME', 'HOURS_SINCE_UPDATED', 'GTE', '48'),
        (@Block, 20, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', 'RESOLVED');
    INSERT dbo.AutomationTriggerActions (TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (@ScheduleClose, 10, 'SET_STATUS', N'{"status":"CLOSED"}', 'AUTOMATION', 'status');

    DECLARE @Collected INT, @Evaluated INT, @Executions INT;
    DECLARE @Processed INT, @Succeeded INT, @Failed INT;
    DECLARE @Operation UNIQUEIDENTIFIER, @Summary BIGINT;

    -- EVT-01: TICKET_CREATED / FIRST_MATCH ---------------------------------------------------------
    SET @Operation = NEWID();
    EXEC dbo.ganymede_ticketActivityLogCreateForCreatedTicket
        @TicketId=@CreateTicket, @ActorId=@ActorId, @OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100, @CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100, @EvaluatedCount=@Evaluated OUTPUT, @ExecutionsCreatedCount=@Executions OUTPUT;
    IF (SELECT COUNT(*) FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND IsMatch=1) <> 3
        THROW 52101, 'EVT-01 expected three matching creation evaluations.', 1;
    IF (SELECT COUNT(*) FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND IsSelected=1) <> 1
        THROW 52102, 'EVT-01 FIRST_MATCH selected count is incorrect.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@CrtVip AND IsSelected=1)
        THROW 52103, 'EVT-01 did not select the lowest matching SortOrder.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100, @ProcessedCount=@Processed OUTPUT, @SucceededCount=@Succeeded OUTPUT, @FailedCount=@Failed OUTPUT;
    IF EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@CreateTicket AND CreateAutomationStatus <> 'PENDING')
        THROW 52104, 'EVT-01 ticket became visible before all direct actions completed.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100, @ProcessedCount=@Processed OUTPUT, @SucceededCount=@Succeeded OUTPUT, @FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@CreateTicket AND GroupId=@GroupVip AND Priority='HIGH' AND CreateAutomationStatus='READY')
        THROW 52105, 'EVT-01 selected actions or visibility finalization failed.', 1;
    INSERT #Results VALUES ('EVT-01',@Operation,@CreateTicket,@Summary,'PASS',N'3 matched; SortOrder 9010 selected; two DB actions completed');

    -- EVT-02: STATUS_CHANGED -----------------------------------------------------------------------
    SET @Operation=NEWID();
    UPDATE dbo.Tickets SET Status='RESOLVED',StatusChangedAt=@Now,UpdatedAt=@Now WHERE Id=@StatusTicket;
    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket @TicketId=@StatusTicket,
        @OldValuesJson=N'{"status":"OPEN"}',@NewValuesJson=N'{"status":"RESOLVED"}',@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@StatusResolved AND EventType='STATUS_CHANGED' AND IsSelected=1)
        THROW 52106, 'EVT-02 normalized STATUS_CHANGED trigger did not match.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@StatusTicket AND GroupId=@GroupEscalation)
        THROW 52107, 'EVT-02 group action failed.', 1;
    INSERT #Results VALUES ('EVT-02',@Operation,@StatusTicket,@Summary,'PASS',N'STATUS_CHANGED alias, CHANGED_TO, IN and ASSIGN_GROUP passed');

    -- EVT-03: PRIORITY_CHANGED / ALL_MATCH / application lease -----------------------------------
    SET @Operation=NEWID();
    UPDATE dbo.Tickets SET Priority='URGENT',UpdatedAt=@Now WHERE Id=@PriorityTicket;
    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket @TicketId=@PriorityTicket,
        @OldValuesJson=N'{"priority":"HIGH"}',@NewValuesJson=N'{"priority":"URGENT"}',@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF (SELECT COUNT(*) FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND IsSelected=1) <> 2
        THROW 52108, 'EVT-03 ALL_MATCH did not select both triggers.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE TicketId=@PriorityTicket AND ExecutionTarget='AUTOMATION' AND ActionType='ASSIGN_GROUP')
        THROW 52109, 'EVT-03 database action was not dispatched.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE TicketId=@PriorityTicket AND ExecutionTarget='APPLICATION' AND ActionType='SEND_NOTIFICATION')
        THROW 52110, 'EVT-03 application action was not dispatched.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    EXEC dbo.ganymede_automationExecutionActionClaimBatch @WorkerId='TEST-WORKER-A',@BatchSize=100,@LeaseSeconds=60;
    DECLARE @NotificationAction UNIQUEIDENTIFIER=(SELECT Id FROM dbo.AutomationTriggerQueueAction WHERE TicketId=@PriorityTicket AND ActionType='SEND_NOTIFICATION');
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE Id=@NotificationAction AND ClaimedBy='TEST-WORKER-A' AND AttemptCount=1)
        THROW 52111, 'EVT-03 worker A did not own the first lease.', 1;
    EXEC dbo.ganymede_automationExecutionActionClaimBatch @WorkerId='TEST-WORKER-B',@BatchSize=100,@LeaseSeconds=60;
    IF EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE Id=@NotificationAction AND ClaimedBy='TEST-WORKER-B')
        THROW 52112, 'EVT-03 active lease was stolen before expiry.', 1;
    UPDATE dbo.AutomationTriggerQueueAction SET LeaseExpiresAt=DATEADD(SECOND,-1,@Now) WHERE Id=@NotificationAction;
    EXEC dbo.ganymede_automationExecutionActionClaimBatch @WorkerId='TEST-WORKER-B',@BatchSize=100,@LeaseSeconds=60;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE Id=@NotificationAction AND ClaimedBy='TEST-WORKER-B' AND AttemptCount=2)
        THROW 52113, 'EVT-03 expired lease was not reclaimed.', 1;
    EXEC dbo.ganymede_automationExecutionActionComplete @ActionId=@NotificationAction,@Status='SUCCEEDED',@RenderedValue=N'{"sent":true}',@WorkerId='TEST-WORKER-A';
    IF EXISTS (SELECT 1 FROM dbo.AutomationTriggerQueueAction WHERE Id=@NotificationAction AND Status='SUCCEEDED')
        THROW 52114, 'EVT-03 stale worker result overwrote the new owner.', 1;
    EXEC dbo.ganymede_automationExecutionActionComplete @ActionId=@NotificationAction,@Status='SUCCEEDED',@RenderedValue=N'{"sent":true}',@WorkerId='TEST-WORKER-B';
    INSERT #Results VALUES ('EVT-03',@Operation,@PriorityTicket,@Summary,'PASS',N'ALL_MATCH, AUTOMATION/APPLICATION routing, lease/reclaim/stale-owner protection passed');

    -- EVT-04: GROUP_CHANGED ------------------------------------------------------------------------
    SET @Operation=NEWID();
    UPDATE dbo.Tickets SET GroupId=@GroupVip,UpdatedAt=@Now WHERE Id=@GroupTicket;
    DECLARE @GroupChangeJson NVARCHAR(MAX)=N'{"groupId":"' + CONVERT(NVARCHAR(36),@GroupVip) + N'"}';
    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket @TicketId=@GroupTicket,
        @OldValuesJson=N'{"groupId":"old"}',@NewValuesJson=@GroupChangeJson,@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@GroupAssign AND IsSelected=1)
        THROW 52115, 'EVT-04 GROUP_CHANGED did not match agent availability.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@GroupTicket AND AssignedAgentId=@AgentAvailable)
        THROW 52116, 'EVT-04 ASSIGN_AGENT failed.', 1;
    INSERT #Results VALUES ('EVT-04',@Operation,@GroupTicket,@Summary,'PASS',N'GROUP_CHANGED and assigned-agent source passed');

    -- EVT-05: ASSIGNEE_CHANGED ---------------------------------------------------------------------
    SET @Operation=NEWID();
    UPDATE dbo.Tickets SET AssignedAgentId=@AgentAvailable,UpdatedAt=@Now WHERE Id=@AssigneeTicket;
    DECLARE @AgentChangeJson NVARCHAR(MAX)=N'{"assignedAgentId":"' + CONVERT(NVARCHAR(36),@AgentAvailable) + N'"}';
    EXEC dbo.ganymede_ticketActivityLogCreateForUpdatedTicket @TicketId=@AssigneeTicket,
        @OldValuesJson=N'{"assignedAgentId":"old"}',@NewValuesJson=@AgentChangeJson,@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@AssigneeOpen AND IsSelected=1)
        THROW 52117, 'EVT-05 ASSIGNEE_CHANGED did not match.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@AssigneeTicket AND Status='OPEN')
        THROW 52118, 'EVT-05 SET_STATUS OPEN failed.', 1;
    INSERT #Results VALUES ('EVT-05',@Operation,@AssigneeTicket,@Summary,'PASS',N'ASSIGNEE_CHANGED and agent status/availability passed');

    -- EVT-06 and EVT-07: reply actor normalization -------------------------------------------------
    DECLARE @RequesterMessage UNIQUEIDENTIFIER=NEWID(), @AgentMessage UNIQUEIDENTIFIER=NEWID();
    INSERT dbo.TicketMessages
        (Id,TicketId,AuthorType,AuthorId,MessageType,Visibility,Body,PlainBody,CreatedBy,UpdatedBy)
    VALUES
        (@RequesterMessage,@RequesterTicket,'CUSTOMER',@ContactId,'CONVERSATION_REPLY','PUBLIC',N'reply',N'reply',N'AUTOMATION_TEST',N'AUTOMATION_TEST'),
        (@AgentMessage,@AgentTicket,'AGENT',@AgentAvailable,'CONVERSATION_REPLY','PUBLIC',N'reply',N'reply',N'AUTOMATION_TEST',N'AUTOMATION_TEST');

    SET @Operation=NEWID();
    EXEC dbo.ganymede_ticketActivityLogCreateForPublicReply @TicketId=@RequesterTicket,@TicketMessageId=@RequesterMessage,@ActorId=@ContactId,@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@RequesterOpen AND EventType='REQUESTER_REPLIED' AND IsSelected=1)
        THROW 52119, 'EVT-06 requester reply actor normalization failed.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@RequesterTicket AND Status='OPEN') THROW 52120, 'EVT-06 reopen failed.',1;
    INSERT #Results VALUES ('EVT-06',@Operation,@RequesterTicket,@Summary,'PASS',N'REQUESTER_REPLIED actor and requester state passed');

    SET @Operation=NEWID();
    EXEC dbo.ganymede_ticketActivityLogCreateForPublicReply @TicketId=@AgentTicket,@TicketMessageId=@AgentMessage,@ActorId=@AgentAvailable,@OperationId=@Operation;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=100,@CollectedCount=@Collected OUTPUT;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE OperationId=@Operation;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=100,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@AgentWait AND EventType='AGENT_REPLIED' AND IsSelected=1)
        THROW 52121, 'EVT-07 agent reply actor normalization failed.', 1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=100,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@AgentTicket AND Status='PENDING') THROW 52122, 'EVT-07 wait status failed.',1;
    INSERT #Results VALUES ('EVT-07',@Operation,@AgentTicket,@Summary,'PASS',N'AGENT_REPLIED actor and NOT_EQUALS passed');

    -- Drain activity cascades before schedule assertions.
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=1000,@CollectedCount=@Collected OUTPUT;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=1000,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;

    -- EVT-08: SCHEDULE_DUE and occurrence idempotency ---------------------------------------------
    DECLARE @Bucket VARCHAR(100)='TEST_SCHEDULE_' + REPLACE(CONVERT(VARCHAR(36),NEWID()),'-','');
    DECLARE @TimeQueued INT, @TimeQueuedAgain INT;
    EXEC dbo.ganymede_automationTimeTriggerScanBatch @EvaluationBucket=@Bucket,@BatchSize=1000,@QueuedCount=@TimeQueued OUTPUT;
    EXEC dbo.ganymede_automationTimeTriggerScanBatch @EvaluationBucket=@Bucket,@BatchSize=1000,@QueuedCount=@TimeQueuedAgain OUTPUT;
    IF @TimeQueuedAgain <> 0 THROW 52123, 'EVT-08 duplicate schedule scan created work.',1;
    SELECT @Summary=Id FROM dbo.AutomationTriggerQueueSummary WHERE TicketId=@ScheduleTicket AND CandidateTriggerId=@ScheduleClose AND EvaluationBucket=@Bucket;
    IF @Summary IS NULL THROW 52124, 'EVT-08 schedule scanner did not queue the resolved ticket.',1;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=1000,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.AutomationEvaluations WHERE QueueSummaryId=@Summary AND TriggerId=@ScheduleClose AND EventType='SCHEDULE_DUE' AND IsSelected=1)
        THROW 52125, 'EVT-08 SCHEDULE_DUE time rule did not match.',1;
    EXEC dbo.ganymede_automationActionProcessBatch @BatchSize=1000,@ProcessedCount=@Processed OUTPUT,@SucceededCount=@Succeeded OUTPUT,@FailedCount=@Failed OUTPUT;
    IF NOT EXISTS (SELECT 1 FROM dbo.Tickets WHERE Id=@ScheduleTicket AND Status='CLOSED') THROW 52126, 'EVT-08 close action failed.',1;
    INSERT #Results VALUES ('EVT-08',NULL,@ScheduleTicket,@Summary,'PASS',N'SCHEDULE_DUE, GTE threshold, purity and bucket idempotency passed');

    -- BATCH-01: exact batch boundaries 2,2,1 ------------------------------------------------------
    UPDATE dbo.AutomationTriggers SET IsActive=0;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=2000,@CollectedCount=@Collected OUTPUT;
    EXEC dbo.ganymede_automationEvaluateBatch @BatchSize=2000,@EvaluatedCount=@Evaluated OUTPUT,@ExecutionsCreatedCount=@Executions OUTPUT;

    DECLARE @BatchOp1 UNIQUEIDENTIFIER=NEWID(),@BatchOp2 UNIQUEIDENTIFIER=NEWID(),@BatchOp3 UNIQUEIDENTIFIER=NEWID(),@BatchOp4 UNIQUEIDENTIFIER=NEWID(),@BatchOp5 UNIQUEIDENTIFIER=NEWID();
    INSERT dbo.TicketActivityLogs
        (TicketId,Event,ActorType,OldValue,NewValue,Description,PlainDescription,OperationId,CreatedAt)
    VALUES
        (@StatusTicket,'TICKET_UPDATED','SYSTEM',N'{"subject":"0"}',N'{"subject":"1"}',N'batch',N'batch',@BatchOp1,@Now),
        (@StatusTicket,'TICKET_UPDATED','SYSTEM',N'{"subject":"1"}',N'{"subject":"2"}',N'batch',N'batch',@BatchOp2,@Now),
        (@StatusTicket,'TICKET_UPDATED','SYSTEM',N'{"subject":"2"}',N'{"subject":"3"}',N'batch',N'batch',@BatchOp3,@Now),
        (@StatusTicket,'TICKET_UPDATED','SYSTEM',N'{"subject":"3"}',N'{"subject":"4"}',N'batch',N'batch',@BatchOp4,@Now),
        (@StatusTicket,'TICKET_UPDATED','SYSTEM',N'{"subject":"4"}',N'{"subject":"5"}',N'batch',N'batch',@BatchOp5,@Now);
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=2,@CollectedCount=@Collected OUTPUT;
    IF @Collected<>2 THROW 52127,'BATCH-01 first batch was not exactly 2.',1;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=2,@CollectedCount=@Collected OUTPUT;
    IF @Collected<>2 THROW 52128,'BATCH-01 second batch was not exactly 2.',1;
    EXEC dbo.ganymede_automationTriggerQueueCollectBatch @BatchSize=2,@CollectedCount=@Collected OUTPUT;
    IF @Collected<>1 THROW 52129,'BATCH-01 remainder batch was not exactly 1.',1;
    IF (SELECT COUNT(*) FROM dbo.AutomationTriggerQueueSummary WHERE OperationId IN (@BatchOp1,@BatchOp2,@BatchOp3,@BatchOp4,@BatchOp5))<>5
        THROW 52130,'BATCH-01 skipped or duplicated an operation.',1;
    INSERT #Results VALUES ('BATCH-01',NULL,@StatusTicket,NULL,'PASS',N'Five operations collected in deterministic 2,2,1 batches');

    -- RET-01: queue cleanup does not remove durable evaluation audit. Observable runs keep queue
    -- rows so their full pipeline can be inspected after commit.
    IF @PersistTestData = 0
    BEGIN
        DECLARE @AuditBefore INT=(SELECT COUNT(*) FROM dbo.AutomationEvaluations WHERE QueueSummaryId IN
            (SELECT QueueSummaryId FROM #Results WHERE QueueSummaryId IS NOT NULL));
        EXEC dbo.ganymede_automationRetentionCleanupBatch
            @BatchSize=50000,@QueueRetentionDays=0,@RuleAuditRetentionDays=99999,@AuditRetentionDays=99999;
        IF @AuditBefore=0 OR (SELECT COUNT(*) FROM dbo.AutomationEvaluations WHERE QueueSummaryId IN
            (SELECT QueueSummaryId FROM #Results WHERE QueueSummaryId IS NOT NULL))<>@AuditBefore
            THROW 52131,'RET-01 queue cleanup removed durable evaluation audit.',1;
        INSERT #Results VALUES ('RET-01',NULL,NULL,NULL,'PASS',N'Bounded queue cleanup retained durable evaluation audit');
    END;

    SELECT TestCaseId,OperationId,TicketId,QueueSummaryId,Result,Evidence
    FROM #Results ORDER BY TestCaseId;
    SELECT COUNT(*) AS PassedTestCount FROM #Results WHERE Result='PASS';
    SELECT @TestRunId AS TestRunId, @TestRunToken AS TestRunToken, @PersistTestData AS Persisted;

    IF @PersistTestData = 1
    BEGIN
        UPDATE t
        SET IsActive = original.IsActive
        FROM dbo.AutomationTriggers t
        JOIN #OriginalTriggerState original ON original.TriggerId = t.Id;

        COMMIT TRANSACTION;
        PRINT 'PASS: observable acceptance run committed. Filter Tickets by the returned TestRunToken.';
    END
    ELSE
    BEGIN
        ROLLBACK TRANSACTION;
        PRINT 'PASS: acceptance test transaction rolled back; no suite-created fixture/configuration data persisted.';
    END;
END TRY
BEGIN CATCH
    IF XACT_STATE()<>0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
