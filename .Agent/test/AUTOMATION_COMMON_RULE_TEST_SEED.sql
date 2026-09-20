-- =================================================================================================
-- OneDesk Automation - Common Rule Test Seed
--
-- Installs the configuration contract from AUTOMATION_COMMON_RULE_TEST_CONFIGURATION.md.
-- The seed is idempotent by the [TEST] logical rule name and does not create runtime queue data.
-- External APPLICATION actions are disabled by default.
-- =================================================================================================
USE OneDeskDb;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

BEGIN TRY
    BEGIN TRANSACTION;

    DECLARE @EnableSafeFieldRules BIT = 1;
    DECLARE @EnableApplicationActions BIT = 0;
    DECLARE @EnableScheduleRules BIT = 1;
    DECLARE @Now DATETIMEOFFSET = SYSUTCDATETIME() AT TIME ZONE 'UTC';

    -- Stable reference fixtures ------------------------------------------------------------------
    DECLARE @CompanyVip UNIQUEIDENTIFIER;
    DECLARE @CompanyStandard UNIQUEIDENTIFIER;
    DECLARE @ContactActive UNIQUEIDENTIFIER;
    DECLARE @ContactInactive UNIQUEIDENTIFIER;
    DECLARE @GroupDefault UNIQUEIDENTIFIER;
    DECLARE @GroupEscalation UNIQUEIDENTIFIER;
    DECLARE @GroupVip UNIQUEIDENTIFIER;
    DECLARE @AgentAvailable UNIQUEIDENTIFIER;
    DECLARE @AgentUnavailable UNIQUEIDENTIFIER;
    DECLARE @AgentOutsideGroup UNIQUEIDENTIFIER;

    SELECT @CompanyVip = Id FROM dbo.Companies WHERE Name = N'[TEST] VIP Company';
    IF @CompanyVip IS NULL
    BEGIN
        SET @CompanyVip = 'A1000000-0000-0000-0000-000000000001';
        INSERT dbo.Companies (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@CompanyVip, N'[TEST] VIP Company', N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END;

    SELECT @CompanyStandard = Id FROM dbo.Companies WHERE Name = N'[TEST] Standard Company';
    IF @CompanyStandard IS NULL
    BEGIN
        SET @CompanyStandard = 'A1000000-0000-0000-0000-000000000002';
        INSERT dbo.Companies (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@CompanyStandard, N'[TEST] Standard Company', N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END;

    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyDomains WHERE CompanyId = @CompanyVip AND Domain = 'vip.automation.test')
        INSERT dbo.CompanyDomains (CompanyId, Domain, CreatedBy)
        VALUES (@CompanyVip, 'vip.automation.test', N'AUTOMATION_TEST_SEED');

    IF NOT EXISTS (SELECT 1 FROM dbo.CompanyDomains WHERE CompanyId = @CompanyStandard AND Domain = 'standard.automation.test')
        INSERT dbo.CompanyDomains (CompanyId, Domain, CreatedBy)
        VALUES (@CompanyStandard, 'standard.automation.test', N'AUTOMATION_TEST_SEED');

    SELECT @ContactActive = Id FROM dbo.Contacts WHERE PrimaryEmail = N'active-requester@automation.test';
    IF @ContactActive IS NULL
    BEGIN
        SET @ContactActive = 'B1000000-0000-0000-0000-000000000001';
        INSERT dbo.Contacts (Id, Name, PrimaryEmail, PrimaryCompanyId, Status, CreatedBy, UpdatedBy)
        VALUES (@ContactActive, N'[TEST] Active Requester', N'active-requester@automation.test',
                @CompanyVip, 1, N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END
    ELSE
        UPDATE dbo.Contacts
        SET PrimaryCompanyId = @CompanyVip, Status = 1, UpdatedBy = N'AUTOMATION_TEST_SEED', UpdatedAt = @Now
        WHERE Id = @ContactActive;

    SELECT @ContactInactive = Id FROM dbo.Contacts WHERE PrimaryEmail = N'inactive-requester@automation.test';
    IF @ContactInactive IS NULL
    BEGIN
        SET @ContactInactive = 'B1000000-0000-0000-0000-000000000002';
        INSERT dbo.Contacts (Id, Name, PrimaryEmail, PrimaryCompanyId, Status, CreatedBy, UpdatedBy)
        VALUES (@ContactInactive, N'[TEST] Inactive Requester', N'inactive-requester@automation.test',
                @CompanyStandard, 0, N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END
    ELSE
        UPDATE dbo.Contacts
        SET PrimaryCompanyId = @CompanyStandard, Status = 0, UpdatedBy = N'AUTOMATION_TEST_SEED', UpdatedAt = @Now
        WHERE Id = @ContactInactive;

    SELECT @GroupDefault = Id FROM dbo.Groups WHERE Name = N'[TEST] Default';
    IF @GroupDefault IS NULL
    BEGIN
        SET @GroupDefault = 'C1000000-0000-0000-0000-000000000001';
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupDefault, N'[TEST] Default', N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END;

    SELECT @GroupEscalation = Id FROM dbo.Groups WHERE Name = N'[TEST] Escalation';
    IF @GroupEscalation IS NULL
    BEGIN
        SET @GroupEscalation = 'C1000000-0000-0000-0000-000000000002';
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupEscalation, N'[TEST] Escalation', N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END;

    SELECT @GroupVip = Id FROM dbo.Groups WHERE Name = N'[TEST] VIP';
    IF @GroupVip IS NULL
    BEGIN
        SET @GroupVip = 'C1000000-0000-0000-0000-000000000003';
        INSERT dbo.Groups (Id, Name, CreatedBy, UpdatedBy)
        VALUES (@GroupVip, N'[TEST] VIP', N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');
    END;

    SELECT @AgentAvailable = Id FROM dbo.Agents WHERE Email = N'available-agent@automation.test';
    IF @AgentAvailable IS NULL
    BEGIN
        SET @AgentAvailable = 'D1000000-0000-0000-0000-000000000001';
        INSERT dbo.Agents (Id, FullName, Email, Status, TicketAvailability, CreatedBy)
        VALUES (@AgentAvailable, N'[TEST] Available Agent', N'available-agent@automation.test', 1, 1,
                N'AUTOMATION_TEST_SEED');
    END
    ELSE
        UPDATE dbo.Agents SET Status = 1, TicketAvailability = 1 WHERE Id = @AgentAvailable;

    SELECT @AgentUnavailable = Id FROM dbo.Agents WHERE Email = N'unavailable-agent@automation.test';
    IF @AgentUnavailable IS NULL
    BEGIN
        SET @AgentUnavailable = 'D1000000-0000-0000-0000-000000000002';
        INSERT dbo.Agents (Id, FullName, Email, Status, TicketAvailability, CreatedBy)
        VALUES (@AgentUnavailable, N'[TEST] Unavailable Agent', N'unavailable-agent@automation.test', 1, 0,
                N'AUTOMATION_TEST_SEED');
    END
    ELSE
        UPDATE dbo.Agents SET Status = 1, TicketAvailability = 0 WHERE Id = @AgentUnavailable;

    SELECT @AgentOutsideGroup = Id FROM dbo.Agents WHERE Email = N'outside-agent@automation.test';
    IF @AgentOutsideGroup IS NULL
    BEGIN
        SET @AgentOutsideGroup = 'D1000000-0000-0000-0000-000000000003';
        INSERT dbo.Agents (Id, FullName, Email, Status, TicketAvailability, CreatedBy)
        VALUES (@AgentOutsideGroup, N'[TEST] Outside Group Agent', N'outside-agent@automation.test', 1, 1,
                N'AUTOMATION_TEST_SEED');
    END
    ELSE
        UPDATE dbo.Agents SET Status = 1, TicketAvailability = 1 WHERE Id = @AgentOutsideGroup;

    IF NOT EXISTS (SELECT 1 FROM dbo.GroupAgents WHERE AgentId = @AgentAvailable AND GroupId = @GroupVip)
        INSERT dbo.GroupAgents (AgentId, GroupId, CreatedBy)
        VALUES (@AgentAvailable, @GroupVip, N'AUTOMATION_TEST_SEED');

    DECLARE @FieldSeed TABLE
    (
        Id UNIQUEIDENTIFIER NOT NULL,
        FieldCode VARCHAR(100) NOT NULL,
        Label NVARCHAR(200) NOT NULL
    );

    INSERT @FieldSeed (Id, FieldCode, Label)
    VALUES
        ('E1000000-0000-0000-0000-000000000001', 'CUSTOM_DEPARTMENT', N'Department'),
        ('E1000000-0000-0000-0000-000000000002', 'CUSTOM_DIVISION', N'Division'),
        ('E1000000-0000-0000-0000-000000000003', 'CUSTOM_CATEGORY', N'Category');

    INSERT dbo.TicketFields
        (Id, FieldCode, FieldLabelForCustomer, FieldLabelForAgent, FieldType, FieldCategory, CreatedBy, UpdatedBy)
    SELECT fs.Id, fs.FieldCode, fs.Label, fs.Label, 'SINGLE_LINE_TEXT', 'CUSTOM',
           N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED'
    FROM @FieldSeed fs
    WHERE NOT EXISTS (SELECT 1 FROM dbo.TicketFields tf WHERE tf.FieldCode = fs.FieldCode);

    -- Event behavior ------------------------------------------------------------------------------
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
    WHEN MATCHED THEN
        UPDATE SET ExecutionMode = source.ExecutionMode, IsActive = 1, UpdatedAt = @Now
    WHEN NOT MATCHED THEN
        INSERT (EventType, ExecutionMode, IsActive) VALUES (source.EventType, source.ExecutionMode, 1);

    -- Trigger catalog -----------------------------------------------------------------------------
    CREATE TABLE #TriggerSeed
    (
        Name NVARCHAR(200) NOT NULL PRIMARY KEY,
        Description NVARCHAR(1000) NOT NULL,
        EventType VARCHAR(50) NOT NULL,
        Priority INT NOT NULL,
        IsActive BIT NOT NULL
    );

    INSERT #TriggerSeed (Name, Description, EventType, Priority, IsActive)
    VALUES
        (N'[TEST] CRT_URGENT_VIP', N'Route an urgent active-requester customer-service ticket to VIP.', 'TICKET_CREATED', 9010, @EnableSafeFieldRules),
        (N'[TEST] CRT_URGENT_ESCALATION', N'Fallback route for an urgent active-requester ticket.', 'TICKET_CREATED', 9020, @EnableSafeFieldRules),
        (N'[TEST] CRT_DEFAULT_ROUTE', N'Default portal ticket route.', 'TICKET_CREATED', 9090, @EnableSafeFieldRules),
        (N'[TEST] UPD_STATUS_RESOLVED_HIGH', N'Route high-priority resolved tickets to escalation.', 'STATUS_CHANGED', 9100, @EnableSafeFieldRules),
        (N'[TEST] UPD_PRIORITY_URGENT_ROUTE', N'Route a newly urgent ticket to escalation.', 'PRIORITY_CHANGED', 9110, @EnableSafeFieldRules),
        (N'[TEST] UPD_PRIORITY_URGENT_NOTIFY', N'Notify for a newly urgent VIP-company ticket.', 'PRIORITY_CHANGED', 9120, @EnableApplicationActions),
        (N'[TEST] UPD_GROUP_VIP_ASSIGN', N'Assign an available agent when a ticket enters VIP.', 'GROUP_CHANGED', 9130, @EnableSafeFieldRules),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', N'Open a pending ticket assigned to an available active agent.', 'ASSIGNEE_CHANGED', 9140, @EnableSafeFieldRules),
        (N'[TEST] UPD_REQUESTER_REPLY_REOPEN', N'Reopen a pending or resolved ticket after a requester reply.', 'REQUESTER_REPLIED', 9150, @EnableSafeFieldRules),
        (N'[TEST] UPD_AGENT_REPLY_WAIT', N'Put a non-urgent open ticket into pending after an agent reply.', 'AGENT_REPLIED', 9160, @EnableSafeFieldRules),
        (N'[TEST] SCH_RESOLVED_CLOSE_48H', N'Close a resolved ticket unchanged for at least 48 hours.', 'SCHEDULE_DUE', 9210, CASE WHEN @EnableSafeFieldRules = 1 AND @EnableScheduleRules = 1 THEN 1 ELSE 0 END),
        (N'[TEST] SCH_OPEN_ESCALATE_24H', N'Escalate a high-priority open ticket at least 24 hours old.', 'SCHEDULE_DUE', 9220, CASE WHEN @EnableSafeFieldRules = 1 AND @EnableScheduleRules = 1 THEN 1 ELSE 0 END),
        (N'[TEST] SCH_PENDING_REMINDER_12H', N'Notify for a pending ticket unchanged for at least 12 hours.', 'SCHEDULE_DUE', 9230, CASE WHEN @EnableApplicationActions = 1 AND @EnableScheduleRules = 1 THEN 1 ELSE 0 END);

    IF EXISTS
    (
        SELECT t.Name
        FROM dbo.AutomationTriggers t
        JOIN #TriggerSeed s ON s.Name = t.Name
        GROUP BY t.Name
        HAVING COUNT(*) > 1
    )
        THROW 52200, 'Duplicate [TEST] logical rule names must be resolved before applying the seed.', 1;

    MERGE dbo.AutomationTriggers AS target
    USING #TriggerSeed AS source
    ON target.Name = source.Name
    WHEN MATCHED THEN
        UPDATE SET Description = source.Description, EventType = source.EventType,
                   Priority = source.Priority, IsActive = source.IsActive, UpdatedAt = @Now,
                   UpdatedBy = N'AUTOMATION_TEST_SEED'
    WHEN NOT MATCHED THEN
        INSERT (Id, Name, Description, EventType, Priority, IsActive, CreatedBy, UpdatedBy)
        VALUES (NEWID(), source.Name, source.Description, source.EventType, source.Priority,
                source.IsActive, N'AUTOMATION_TEST_SEED', N'AUTOMATION_TEST_SEED');

    INSERT dbo.AutomationTriggerBlocks (Id, TriggerId, BlockOrder, LogicalOperator)
    SELECT NEWID(), t.Id, 1, 'AND'
    FROM dbo.AutomationTriggers t
    JOIN #TriggerSeed s ON s.Name = t.Name
    WHERE NOT EXISTS
    (
        SELECT 1 FROM dbo.AutomationTriggerBlocks b
        WHERE b.TriggerId = t.Id AND b.BlockOrder = 1
    );

    CREATE TABLE #RuleSeed
    (
        TriggerName NVARCHAR(200) NOT NULL,
        RuleOrder INT NOT NULL,
        FieldSource VARCHAR(20) NOT NULL,
        FieldCode VARCHAR(100) NOT NULL,
        Operator VARCHAR(50) NOT NULL,
        Value NVARCHAR(MAX) NULL,
        PRIMARY KEY (TriggerName, RuleOrder)
    );

    INSERT #RuleSeed (TriggerName, RuleOrder, FieldSource, FieldCode, Operator, Value)
    VALUES
        (N'[TEST] CRT_URGENT_VIP', 10, 'TICKET', 'DEFAULT_PRIORITY', 'EQUALS', N'URGENT'),
        (N'[TEST] CRT_URGENT_VIP', 20, 'CUSTOM_FIELD', 'CUSTOM_DEPARTMENT', 'EQUALS', N'CUSTOMER_SERVICE'),
        (N'[TEST] CRT_URGENT_VIP', 30, 'REQUESTER', 'STATUS', 'EQUALS', N'1'),
        (N'[TEST] CRT_URGENT_ESCALATION', 10, 'TICKET', 'DEFAULT_PRIORITY', 'EQUALS', N'URGENT'),
        (N'[TEST] CRT_URGENT_ESCALATION', 20, 'REQUESTER', 'STATUS', 'EQUALS', N'1'),
        (N'[TEST] CRT_DEFAULT_ROUTE', 10, 'TICKET', 'DEFAULT_SOURCE', 'IN', N'PORTAL_AGENT,PORTAL_ONECHAT'),
        (N'[TEST] UPD_STATUS_RESOLVED_HIGH', 10, 'TICKET', 'DEFAULT_STATUS', 'CHANGED_TO', N'RESOLVED'),
        (N'[TEST] UPD_STATUS_RESOLVED_HIGH', 20, 'TICKET', 'DEFAULT_PRIORITY', 'IN', N'HIGH,URGENT'),
        (N'[TEST] UPD_PRIORITY_URGENT_ROUTE', 10, 'TICKET', 'DEFAULT_PRIORITY', 'CHANGED_TO', N'URGENT'),
        (N'[TEST] UPD_PRIORITY_URGENT_ROUTE', 20, 'TICKET', 'DEFAULT_STATUS', 'NOT_EQUALS', N'CLOSED'),
        (N'[TEST] UPD_PRIORITY_URGENT_ROUTE', 30, 'REQUESTER', 'STATUS', 'EQUALS', N'1'),
        (N'[TEST] UPD_PRIORITY_URGENT_NOTIFY', 10, 'TICKET', 'DEFAULT_PRIORITY', 'CHANGED_TO', N'URGENT'),
        (N'[TEST] UPD_PRIORITY_URGENT_NOTIFY', 20, 'COMPANY', 'DOMAIN', 'EQUALS', N'vip.automation.test'),
        (N'[TEST] UPD_GROUP_VIP_ASSIGN', 10, 'TICKET', 'DEFAULT_GROUP', 'CHANGED_TO', CONVERT(NVARCHAR(36), @GroupVip)),
        (N'[TEST] UPD_GROUP_VIP_ASSIGN', 20, 'ASSIGNED_AGENT', 'TICKET_AVAILABILITY', 'EQUALS', N'0'),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', 10, 'TICKET', 'DEFAULT_AGENT', 'CHANGED_TO', CONVERT(NVARCHAR(36), @AgentAvailable)),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', 20, 'ASSIGNED_AGENT', 'STATUS', 'EQUALS', N'1'),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', 30, 'ASSIGNED_AGENT', 'TICKET_AVAILABILITY', 'EQUALS', N'1'),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', 40, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', N'PENDING'),
        (N'[TEST] UPD_REQUESTER_REPLY_REOPEN', 10, 'TICKET', 'DEFAULT_STATUS', 'IN', N'PENDING,RESOLVED'),
        (N'[TEST] UPD_REQUESTER_REPLY_REOPEN', 20, 'REQUESTER', 'STATUS', 'EQUALS', N'1'),
        (N'[TEST] UPD_AGENT_REPLY_WAIT', 10, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', N'OPEN'),
        (N'[TEST] UPD_AGENT_REPLY_WAIT', 20, 'TICKET', 'DEFAULT_PRIORITY', 'NOT_EQUALS', N'URGENT'),
        (N'[TEST] SCH_RESOLVED_CLOSE_48H', 10, 'TIME', 'HOURS_SINCE_UPDATED', 'GTE', N'48'),
        (N'[TEST] SCH_RESOLVED_CLOSE_48H', 20, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', N'RESOLVED'),
        (N'[TEST] SCH_OPEN_ESCALATE_24H', 10, 'TIME', 'HOURS_SINCE_CREATED', 'GTE', N'24'),
        (N'[TEST] SCH_OPEN_ESCALATE_24H', 20, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', N'OPEN'),
        (N'[TEST] SCH_OPEN_ESCALATE_24H', 30, 'TICKET', 'DEFAULT_PRIORITY', 'IN', N'HIGH,URGENT'),
        (N'[TEST] SCH_PENDING_REMINDER_12H', 10, 'TIME', 'HOURS_SINCE_STATUS_CHANGED', 'GTE', N'12'),
        (N'[TEST] SCH_PENDING_REMINDER_12H', 20, 'TICKET', 'DEFAULT_STATUS', 'EQUALS', N'PENDING');

    MERGE dbo.AutomationTriggerRules AS target
    USING
    (
        SELECT b.Id AS TriggerBlockId, s.RuleOrder, s.FieldSource, s.FieldCode, s.Operator, s.Value
        FROM #RuleSeed s
        JOIN dbo.AutomationTriggers t ON t.Name = s.TriggerName
        JOIN dbo.AutomationTriggerBlocks b ON b.TriggerId = t.Id AND b.BlockOrder = 1
    ) AS source
    ON target.TriggerBlockId = source.TriggerBlockId AND target.RuleOrder = source.RuleOrder
    WHEN MATCHED THEN
        UPDATE SET FieldSource = source.FieldSource, FieldCode = source.FieldCode,
                   Operator = source.Operator, Value = source.Value, SecondaryValue = NULL
    WHEN NOT MATCHED THEN
        INSERT (Id, TriggerBlockId, RuleOrder, FieldSource, FieldCode, Operator, Value)
        VALUES (NEWID(), source.TriggerBlockId, source.RuleOrder, source.FieldSource,
                source.FieldCode, source.Operator, source.Value);

    CREATE TABLE #ActionSeed
    (
        TriggerName NVARCHAR(200) NOT NULL,
        ActionOrder INT NOT NULL,
        ActionType VARCHAR(50) NOT NULL,
        ActionValue NVARCHAR(MAX) NOT NULL,
        ExecutionTarget VARCHAR(20) NOT NULL,
        TargetField VARCHAR(100) NULL,
        PRIMARY KEY (TriggerName, ActionOrder)
    );

    INSERT #ActionSeed (TriggerName, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
    VALUES
        (N'[TEST] CRT_URGENT_VIP', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupVip) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] CRT_URGENT_VIP', 20, 'SET_PRIORITY', N'{"priority":"HIGH"}', 'AUTOMATION', 'priority'),
        (N'[TEST] CRT_URGENT_ESCALATION', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] CRT_DEFAULT_ROUTE', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupDefault) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] UPD_STATUS_RESOLVED_HIGH', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] UPD_PRIORITY_URGENT_ROUTE', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] UPD_PRIORITY_URGENT_NOTIFY', 10, 'SEND_NOTIFICATION', N'{"template":"URGENT_VIP_TICKET"}', 'APPLICATION', NULL),
        (N'[TEST] UPD_GROUP_VIP_ASSIGN', 10, 'ASSIGN_AGENT', N'{"agentId":"' + CONVERT(NVARCHAR(36), @AgentAvailable) + N'"}', 'AUTOMATION', 'assignedAgentId'),
        (N'[TEST] UPD_ASSIGNEE_AVAILABLE_OPEN', 10, 'SET_STATUS', N'{"status":"OPEN"}', 'AUTOMATION', 'status'),
        (N'[TEST] UPD_REQUESTER_REPLY_REOPEN', 10, 'SET_STATUS', N'{"status":"OPEN"}', 'AUTOMATION', 'status'),
        (N'[TEST] UPD_AGENT_REPLY_WAIT', 10, 'SET_STATUS', N'{"status":"PENDING"}', 'AUTOMATION', 'status'),
        (N'[TEST] SCH_RESOLVED_CLOSE_48H', 10, 'SET_STATUS', N'{"status":"CLOSED"}', 'AUTOMATION', 'status'),
        (N'[TEST] SCH_OPEN_ESCALATE_24H', 10, 'ASSIGN_GROUP', N'{"groupId":"' + CONVERT(NVARCHAR(36), @GroupEscalation) + N'"}', 'AUTOMATION', 'groupId'),
        (N'[TEST] SCH_PENDING_REMINDER_12H', 10, 'SEND_NOTIFICATION', N'{"template":"PENDING_TICKET_REMINDER"}', 'APPLICATION', NULL);

    MERGE dbo.AutomationTriggerActions AS target
    USING
    (
        SELECT t.Id AS TriggerId, s.ActionOrder, s.ActionType, s.ActionValue,
               s.ExecutionTarget, s.TargetField
        FROM #ActionSeed s
        JOIN dbo.AutomationTriggers t ON t.Name = s.TriggerName
    ) AS source
    ON target.TriggerId = source.TriggerId AND target.ActionOrder = source.ActionOrder
    WHEN MATCHED THEN
        UPDATE SET ActionType = source.ActionType, ActionValue = source.ActionValue,
                   ExecutionTarget = source.ExecutionTarget, TargetField = source.TargetField
    WHEN NOT MATCHED THEN
        INSERT (Id, TriggerId, ActionOrder, ActionType, ActionValue, ExecutionTarget, TargetField)
        VALUES (NEWID(), source.TriggerId, source.ActionOrder, source.ActionType,
                source.ActionValue, source.ExecutionTarget, source.TargetField);

    IF (SELECT COUNT(*) FROM dbo.AutomationTriggers WHERE Name IN (SELECT Name FROM #TriggerSeed)) <> 13
        THROW 52201, 'Common rule test seed did not create all 13 trigger definitions.', 1;

    COMMIT TRANSACTION;

    SELECT COUNT(*) AS SeededTriggerCount,
           SUM(CASE WHEN IsActive = 1 THEN 1 ELSE 0 END) AS ActiveTriggerCount
    FROM dbo.AutomationTriggers
    WHERE Name IN (SELECT Name FROM #TriggerSeed);

    SELECT COUNT(*) AS SeededRuleCount
    FROM dbo.AutomationTriggerRules r
    JOIN dbo.AutomationTriggerBlocks b ON b.Id = r.TriggerBlockId
    JOIN dbo.AutomationTriggers t ON t.Id = b.TriggerId
    WHERE t.Name IN (SELECT Name FROM #TriggerSeed);

    SELECT COUNT(*) AS SeededActionCount
    FROM dbo.AutomationTriggerActions a
    JOIN dbo.AutomationTriggers t ON t.Id = a.TriggerId
    WHERE t.Name IN (SELECT Name FROM #TriggerSeed);

    PRINT 'PASS: common rule test seed applied successfully.';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO
