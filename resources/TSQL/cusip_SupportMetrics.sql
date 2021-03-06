USE [Footprints]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER PROCEDURE [dbo].[cusip_SupportMetrics] 
(
	@i_Today SMALLDATETIME
	,@i_Period VARCHAR(8)
)
AS

BEGIN
SET NOCOUNT ON

DECLARE @ShiftStartTime TIME = '07:00:00'
DECLARE @ShiftEndTime TIME = '18:00:00'

DECLARE @ThisPeriodStart DATETIME
DECLARE @NextPeriodStart DATETIME

IF @i_Period = 'YEAR'
BEGIN
	SET @ThisPeriodStart = DATEADD(year,DATEDIFF(year,0,CAST(@i_Today AS DATETIME)),0)
	SET @NextPeriodStart = DATEADD(YEAR,1,@ThisPeriodStart)
END
ELSE IF @i_Period = 'MONTH'
BEGIN
	SET @ThisPeriodStart = DATEADD(month,DATEDIFF(month,0,CAST(@i_Today AS DATETIME)),0)
	SET @NextPeriodStart = DATEADD(MONTH,1,@ThisPeriodStart)
END
ELSE -- 'DAY' or something else that we'll treat as a day
BEGIN
	SET @ThisPeriodStart = CAST(@i_Today AS DATETIME)
	SET @NextPeriodStart = DATEADD(day,1,@ThisPeriodStart)
END

DECLARE @MetricGroups TABLE (
	idx INT IDENTITY(1,1)
	,MetricGroup VARCHAR(4)
)
INSERT INTO @MetricGroups 
	SELECT 'ALL' UNION
	SELECT 'UMS' UNION 
	SELECT 'CBSW'

DECLARE @ThisMetricGroup VARCHAR(4)
DECLARE @i INT = 0
DECLARE @cnt INT
SELECT @cnt = COUNT(MetricGroup) FROM @MetricGroups

IF OBJECT_ID('tempdb..#ResponseMetrics') IS NOT NULL
DROP TABLE #ResponseMetrics

CREATE TABLE #ResponseMetrics
(
	Period VARCHAR(24)
	,GroupName VARCHAR(4)
	,ClosedTickets INT
	,NewTickets INT
	,AverageResponseTime INT
	,SLA30 INT
	,SLA60 INT
	,SLA61 INT
	,InboundTickets INT
)

------------------------------------------------
-- DAYS
------------------------------------------------
DECLARE @Day DATETIME = @ThisPeriodStart
DECLARE @NextDay DATETIME
DECLARE @DayInt INT 

-- Loop for each day in the selected period
WHILE @Day < @NextPeriodStart
BEGIN

	-- Loop for each metric group within the day
	WHILE @i < @cnt
	BEGIN

		SET @i = @i + 1
		SELECT @ThisMetricGroup = MetricGroup FROM @MetricGroups WHERE idx=@i

		SET @NextDay = DATEADD(DAY,1,@Day)

		-- Only gather numbers for weekdays
		IF DATENAME(dw,@Day) NOT IN ('Saturday','Sunday')
		BEGIN
			SET @DayInt = CAST(@Day AS INT)
		
			INSERT INTO #ResponseMetrics
			SELECT 
				CONVERT(VARCHAR(12),@Day,101)
				,(SELECT MetricGroup FROM @MetricGroups WHERE idx=@i)
				,ClosedTickets.CountClosedTickets
				,NewTickets.CountNewTickets 
				,ISNULL(AvgRT.AverageResponseTime,0)
				,AvgRT.SLA30
				,AvgRT.SLA60
				,AvgRT.SLA61
				,InboundTickets.CountInboundTickets
			FROM (
				-- New ticket counts
				SELECT 
					@DayInt AS DayID
					,COUNT(*) AS CountNewTickets 
				FROM 
					MASTER4 m
				INNER JOIN
					MASTER4_ABDATA ma
				ON
					m.mrid=ma.mrID
				WHERE 
					m.mrSTATUS<>'_DELETED_'
					AND m.mrSUBMITDATE >= @Day
					AND m.mrSUBMITDATE < @NextDay
					AND ma.[Application] LIKE '%'+(CASE WHEN @ThisMetricGroup='ALL' THEN '' ELSE @ThisMetricGroup END)+'%'
					AND m.mrASSIGNEES LIKE 'Support%'
			) NewTickets 
			INNER JOIN (
				-- Closed ticket counts
				SELECT 
					@DayInt AS DayID
					,COUNT(*) AS CountClosedTickets 
				FROM
				(
					SELECT 
						fh.mrid
					FROM 
						MASTER4_FIELDHISTORY fh
					INNER JOIN 
						MASTER4 m
					ON 
						m.mrID=fh.mrID
					INNER JOIN
						MASTER4_ABDATA ma
					ON
						m.mrID=ma.mrID
					WHERE 
						fh.mrFIELDNAME='mrStatus'
						AND fh.mrNEWFIELDVALUE IN ('Resolved','Closed')
						AND fh.mrTIMESTAMP >= @Day
						AND fh.mrTIMESTAMP < @NextDay
						AND ma.[Application] LIKE '%'+(CASE WHEN @ThisMetricGroup='ALL' THEN '' ELSE @ThisMetricGroup END)+'%'
						AND m.mrASSIGNEES LIKE 'Support%'
					GROUP BY fh.mrID
				) CT
			) ClosedTickets
			ON ClosedTickets.DayID=NewTickets.DayID
			INNER JOIN (
				-- Inbound ticket counts
				SELECT 
					@DayInt AS DayID
					,COUNT(*) AS CountInboundTickets 
				FROM
				(
					SELECT 
						fh.mrid
					FROM 
						MASTER4_FIELDHISTORY fh
					INNER JOIN 
						MASTER4 m
					ON 
						m.mrID=fh.mrID
					INNER JOIN
						MASTER4_ABDATA ma
					ON
						m.mrID=ma.mrID
					WHERE 
						fh.mrFIELDNAME='mrStatus'
						AND fh.mrNEWFIELDVALUE IN ('Resolved','Closed')
						AND m.First__bContact__bResolution = 'on'
						AND fh.mrTIMESTAMP >= @Day
						AND fh.mrTIMESTAMP < @NextDay
						AND ma.[Application] LIKE '%'+(CASE WHEN @ThisMetricGroup='ALL' THEN '' ELSE @ThisMetricGroup END)+'%'
						AND m.mrASSIGNEES LIKE 'Support%'
					GROUP BY fh.mrID
				) CT
			) InboundTickets
			ON InboundTickets.DayID=NewTickets.DayID
			INNER JOIN (
				-- Response times and ticket counts within SLA levels
				SELECT 
					@DayInt AS DayID
					,AVG(A.ResponseTime) AverageResponseTime
					,ISNULL(SUM(CASE
						WHEN A.ResponseTime <= 30 THEN 1
						ELSE 0
					END),0) SLA30
					,ISNULL(SUM(CASE
						WHEN A.ResponseTime > 30 AND A.ResponseTime <= 60 THEN 1
						ELSE 0
					END),0) SLA60
					,ISNULL(SUM(CASE
						WHEN A.ResponseTime > 60 OR A.ResponseTime IS NULL THEN 1
						ELSE 0
					END),0) SLA61
				FROM (
					-- Response time calc
					SELECT 
						RT.mrID
						,DATEDIFF(
							MINUTE
							,(SELECT mrTimestamp FROM MASTER4_FIELDHISTORY WHERE mrSEQUENCE=rt.startsequence)
							,ISNULL((SELECT mrTimestamp FROM MASTER4_FIELDHISTORY WHERE mrSEQUENCE=rt.TakenSequence),(SELECT GETDATE()))
						) ResponseTime
					FROM 
					(
						-- Feed tickets to response time calc
						SELECT 
							master4.mrID
							,ss.StartSequence
							,ts.TakenSequence 
						FROM 
							MASTER4
						INNER JOIN (
							-- Start sequence ID
							SELECT 
								fh.mrID
								,MIN(fh.mrSEQUENCE) AS StartSequence
							FROM 
								MASTER4_FIELDHISTORY fh
							INNER JOIN (
								SELECT 
									m.mrID 
								FROM 
									MASTER4 m
								INNER JOIN
									MASTER4_ABDATA ma
								ON
									m.mrid=ma.mrID
								WHERE 
									m.mrSTATUS<>'_DELETED_'
									AND m.mrSUBMITDATE >= @Day
									AND m.mrSUBMITDATE < @NextDay
									AND ma.[Application] LIKE '%'+(CASE WHEN @ThisMetricGroup='ALL' THEN '' ELSE @ThisMetricGroup END)+'%'
							) TD --today's tickets
							ON TD.mrID=fh.mrID
							WHERE 
								fh.mrFIELDNAME='mrStatus'
								AND fh.mrOLDFIELDVALUE IS NULL
								--
								-- Response time start statuses
								--
								AND fh.mrNEWFIELDVALUE IN ('Open','_REQUEST_','Assigned')
								--
								-- END: Response time start statuses
								--
							GROUP BY fh.mrID
						) SS
						ON master4.mrID=ss.mrID
						LEFT JOIN (
							-- 'Taken' sequence ID
							SELECT 
								fh.mrID
								,MIN(fh.mrSEQUENCE) AS TakenSequence
							FROM 
								MASTER4_FIELDHISTORY fh
							INNER JOIN (
								SELECT 
									m.mrID 
								FROM 
									MASTER4 m
								INNER JOIN
									MASTER4_ABDATA ma
								ON
									m.mrid=ma.mrID
								WHERE 
									m.mrSTATUS<>'_DELETED_'
									AND m.mrSUBMITDATE >= @Day
									AND m.mrSUBMITDATE < @NextDay
									AND ma.[Application] LIKE '%'+(CASE WHEN @ThisMetricGroup='ALL' THEN '' ELSE @ThisMetricGroup END)+'%'
							) TD --today's tickets
							ON TD.mrID=fh.mrID
							WHERE 
								fh.mrFIELDNAME='mrStatus'
								--
								-- Response time end statuses
								--
								AND fh.mrNEWFIELDVALUE IN ('In__bProgress','Contact__bAttempted','Resolved','Closed','Escalated__b__u__bTier__b2','Pending')
								--
								-- END: Response time end statuses
								--
							GROUP BY fh.mrID
						) TS
						ON TS.mrID=master4.mrID
						WHERE MASTER4.mrASSIGNEES LIKE 'Support%'
						AND MASTER4.mrID NOT IN ( 
							-- Tickets EXCLUDED from response time stats
							SELECT 
								DISTINCT(mrID)
							FROM
								MASTER4_FIELDHISTORY
							WHERE
								mrNEWFIELDVALUE IN ('Contracted__bWork','Scheduled__bCall','_INACTIVE_','_PENDING_SOLUTION_','_SOLVED_')
						)
						-- Ticket creation date within "workspace time"
						AND CONVERT(TIME,MASTER4.mrSUBMITDATE) >= @ShiftStartTime
						AND CONVERT(TIME,MASTER4.mrSUBMITDATE) <= @ShiftEndTime
					) RT
				) A
			) AvgRT ON ClosedTickets.DayID=AvgRT.DayID

		END

	END
	SET @i = 0

	SET @Day = @NextDay
END

SELECT * FROM #ResponseMetrics
ORDER BY Period, GroupName

DROP TABLE #ResponseMetrics

SET NOCOUNT OFF
END
