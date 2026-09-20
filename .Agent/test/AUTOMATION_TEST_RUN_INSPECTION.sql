-- Change this token to inspect another committed observable run.
USE OneDeskDb;
GO
SET NOCOUNT ON;
GO

DECLARE @TestRunToken VARCHAR(8) = '852D217B';

DECLARE @RunTickets TABLE (TicketId UNIQUEIDENTIFIER NOT NULL PRIMARY KEY);
INSERT @RunTickets (TicketId)
SELECT Id
FROM dbo.Tickets
WHERE TicketNo LIKE '#AT' + @TestRunToken + '%';

SELECT 'RUN' AS ResultSet, @TestRunToken AS TestRunToken, COUNT(*) AS TicketCount
FROM @RunTickets;

SELECT 'TICKETS' AS ResultSet, t.*
FROM dbo.Tickets t
JOIN @RunTickets rt ON rt.TicketId = t.Id
ORDER BY t.TicketNo;

SELECT 'ACTIVITY_LOGS' AS ResultSet, l.*
FROM dbo.TicketActivityLogs l
JOIN @RunTickets rt ON rt.TicketId = l.TicketId
ORDER BY l.CreatedAt, l.Id;

SELECT 'QUEUE_SUMMARIES' AS ResultSet, q.*
FROM dbo.AutomationTriggerQueueSummary q
JOIN @RunTickets rt ON rt.TicketId = q.TicketId
ORDER BY q.CreatedAt, q.Id;

SELECT 'QUEUE_DELTAS' AS ResultSet, d.*
FROM dbo.AutomationTriggerQueueDelta d
JOIN dbo.AutomationTriggerQueueSummary q ON q.Id = d.QueueSummaryId
JOIN @RunTickets rt ON rt.TicketId = q.TicketId
ORDER BY d.QueueSummaryId, d.Id;

SELECT 'EVALUATIONS' AS ResultSet, e.*
FROM dbo.AutomationEvaluations e
JOIN @RunTickets rt ON rt.TicketId = e.TicketId
ORDER BY e.EvaluatedAt, e.SortOrder;

SELECT 'EVALUATION_BLOCKS' AS ResultSet, b.*
FROM dbo.AutomationEvaluationBlocks b
JOIN dbo.AutomationEvaluations e ON e.Id = b.EvaluationId
JOIN @RunTickets rt ON rt.TicketId = e.TicketId
ORDER BY b.EvaluatedAt, b.Id;

SELECT 'EVALUATION_RULES' AS ResultSet, r.*
FROM dbo.AutomationEvaluationRules r
JOIN dbo.AutomationEvaluations e ON e.Id = r.EvaluationId
JOIN @RunTickets rt ON rt.TicketId = e.TicketId
ORDER BY r.EvaluatedAt, r.Id;

SELECT 'EXECUTIONS' AS ResultSet, e.*
FROM dbo.AutomationExecutions e
JOIN @RunTickets rt ON rt.TicketId = e.TicketId
ORDER BY e.CreatedAt, e.Id;

SELECT 'QUEUE_ACTIONS' AS ResultSet, a.*
FROM dbo.AutomationTriggerQueueAction a
JOIN @RunTickets rt ON rt.TicketId = a.TicketId
ORDER BY a.CreatedAt, a.ActionSequence;

SELECT 'ACTION_HISTORIES' AS ResultSet, h.*
FROM dbo.AutomationActionHistories h
JOIN @RunTickets rt ON rt.TicketId = h.TicketId
ORDER BY h.CompletedAt, h.Id;

SELECT 'RUN_TRIGGERS' AS ResultSet, t.*
FROM dbo.AutomationTriggers t
WHERE LEFT(t.Name, 14) = N'[RUN ' + @TestRunToken + N']'
ORDER BY t.Priority;
GO
