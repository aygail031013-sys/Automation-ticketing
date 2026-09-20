-- Runs the integration suite in observable mode. Unlike the default runner, this commits uniquely
-- tagged test tickets and their complete automation pipeline so the processed data can be inspected.
USE OneDeskDb;
GO
EXEC sys.sp_set_session_context @key = N'PersistAutomationTestData', @value = 1;
GO
:r .Agent\test\AUTOMATION_INTEGRATION_TESTS.sql
