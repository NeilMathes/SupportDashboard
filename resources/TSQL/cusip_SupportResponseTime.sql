USE [Footprints]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[cusip_SupportResponseTime] 
AS 
BEGIN

DECLARE @Today SMALLDATETIME = (SELECT CAST(GETDATE() AS DATE))
DECLARE @StartTime DATETIME = DATEADD(hour,7,@Today)
DECLARE @EndTime DATETIME = DATEADD(hour,18,@Today)

SELECT 
	ISNULL(DATEDIFF(minute,MIN(mrUPDATEDATE),(GETDATE())),0) AS WaitTime
FROM 
	master4 m
INNER JOIN
	MASTER4_ABDATA ma
ON
	m.mrid=ma.mrID
WHERE
	m.mrSTATUS IN ('_REQUEST_','Open','Contact__bAttempted') 
--AND 
--	m.mrASSIGNEES = 'Support'
AND --Check for Support as the only assignee after stripping CCs (which always come at the end of the assignee string)
	RTRIM(LEFT(m.mrASSIGNEES,(
				CASE 
					WHEN CHARINDEX('cc',m.mrAssignees) > 0 THEN CHARINDEX('cc',m.mrAssignees) - 1
					ELSE LEN(m.mrAssignees)
				END
	))) = 'Support'
AND
(
	Scheduled__bCall IS NULL 
OR
	(
		Scheduled__bCall >= @StartTime
	AND 
		Scheduled__bCall <= @EndTime
	)
)

END
