-- T-SQL

-- Input parameters
DECLARE @SiteDbName VARCHAR(200) = '%SiteDb_Woodmere%'
DECLARE @BeginDate DATETIME = '2017-04-01 00:00:00'
DECLARE @EndDate DATETIME = '2017-05-01 00:00:00'
DECLARE @latitude FLOAT = (SELECT Latitude FROM [VantageMaster].[dbo].[Locations] WHERE LocationId = (SELECT LocationId FROM [VantageMaster].[dbo].[Sites] WHERE SiteDbName LIKE @SiteDbName)) -- UOM in degrees.
DECLARE @longitude FLOAT = (SELECT Longitude FROM [VantageMaster].[dbo].[Locations] WHERE LocationId = (SELECT LocationId FROM [VantageMaster].[dbo].[Sites] WHERE SiteDbName LIKE @SiteDbName)) -- UOM in degrees.
DECLARE @ArrayTilt FLOAT = 0 -- UOM in degrees
DECLARE @ArrayAzimuth FLOAT = 180 -- UOM in degrees
DECLARE @TimeZone INT = (
	SELECT TOP 1 DATEPART(TZOFFSET, IntervalEndTime)/60
	FROM [dbo].[PointHistory]
	WHERE PointId = (SELECT TOP 1 PointId FROM [dbo].[Points] WHERE Display LIKE '%dew%')
	AND CAST(IntervalEndTime AS DATETIME) = @BeginDate
	ORDER BY IntervalEndTime DESC)

-- Constants used in the model
DECLARE @Ba FLOAT = 0.84 -- Ratio of forward scatter irradiance to the total irradiance
DECLARE @K1 FLOAT = 0.0933 -- Aerosol absorptance coefficient
DECLARE @Tau380 FLOAT = 0.3538 -- Atmospheric turbidity
DECLARE @Tau500 FLOAT = 0.2661 -- Atmospheric turbidity
DECLARE @Uo FLOAT = 0.34 -- Atmospheric Ozone
DECLARE @SolarConstant INT = 1367.7 -- Solar constant
DECLARE @R_g FLOAT = 0.4 -- Ground albedo

DECLARE @ControlDate DATETIME = @BeginDate
DECLARE @ValueTable TABLE ([Date] DATETIME, SolarZenith DECIMAL(20,3), SolarElevation DECIMAL(20,3), SolarAzimuth DECIMAL(20,3), DNI DECIMAL(20,3), DHI DECIMAL(20,3), GHI DECIMAL(20,3), AOI DECIMAL(20,3), POA DECIMAL(20,3))

IF OBJECT_ID('tempdb.dbo.#DewTable') IS NOT NULL DROP TABLE #DewTable
CREATE TABLE #DewTable (IntervalEndTime DATETIME, DewValue FLOAT)
INSERT INTO #DewTable
SELECT IntervalEndTime, AVG(LastValue) FROM [dbo].[PointHistory]
WHERE PointId IN (SELECT PointId FROM [dbo].[Points] WHERE Display LIKE '%dew%')
AND CAST(IntervalEndTime AS DATETIME) BETWEEN @BeginDate AND @EndDate
GROUP BY IntervalEndTime
ORDER BY IntervalEndTime

WHILE @ControlDate <= @EndDate
	BEGIN
		DECLARE @t_mn FLOAT = CASE WHEN DATEPART(MONTH, @ControlDate)<=2 THEN DATEPART(MONTH, @ControlDate)+12 ELSE DATEPART(MONTH, @ControlDate) END -- Month
		DECLARE @t_yr FLOAT = CASE WHEN DATEPART(MONTH, @ControlDate)<=2 THEN DATEPART(YEAR, @ControlDate)-1 ELSE DATEPART(YEAR, @ControlDate) END -- Year
		DECLARE @t_dd FLOAT = DATEPART(DAY, @ControlDate)+CONVERT(FLOAT, DATEPART(MINUTE, @ControlDate))/1440 -- Decimal day
		DECLARE @JD FLOAT = (FLOOR(365.25*(@t_yr+4716))+FLOOR(30.6001*(@t_mn+1))+@t_dd+(2-FLOOR(@t_yr/100)+FLOOR(FLOOR(@t_yr/100)/4))-1524.5) -- Julian Ephemeris Day
		DECLARE @t FLOAT = (@JD-2451545)/36525 -- Julian century

		DECLARE @Theta_LO FLOAT = CONVERT(DECIMAL(20,10), 280.46646+@t*(36000.76983+0.0003032*@t))%CONVERT(DECIMAL(20,10), 360) -- Geometric mean logitude of the sun in degrees
		DECLARE @Theta_LO_Rn FLOAT = @Theta_LO*PI()/180 -- Change to radians

		DECLARE @M FLOAT = 357.52911+@t*(35999.05029-0.0001537*@t) -- Geometric mean anomaly of the sun in degrees
		DECLARE @M_Rn FLOAT = @M*PI()/180 -- Change to radians

		DECLARE @e FLOAT = 0.016708634-@t*(0.000042037+0.0000001267*@t) -- Eccentricity of Earth's orbit
		DECLARE @c FLOAT = SIN(@M_Rn)*(1.914602-@t*(0.004817+0.000014*@t))+SIN(2*@M_Rn)*(0.019993-0.000101*@t)+0.000289*SIN(3*@M_Rn) -- Center for the sun in degrees
		DECLARE @Theta_TLO FLOAT = @Theta_LO+@c -- True longitude of the sun in degrees

		DECLARE @v FLOAT = @M+@c -- True anomaly of the sun in degrees
		DECLARE @v_Rn FLOAT = @v*PI()/180 -- Change to radians

		DECLARE @r FLOAT = (1.000001018*(1-@e*@e))/(1+@e*COS(@v_Rn)) -- Distance between the Earth and the Sun

		DECLARE @lambda FLOAT = @Theta_TLO-0.00569-0.00478*SIN((125.04-1934.136*@t)*PI()/180) -- Apparent longitude of the sun in degrees
		DECLARE @lambda_Rn FLOAT = @lambda*PI()/180 -- Change to radians

		DECLARE @Epsilon_0 FLOAT = 23+(26+((21.448-@t*(46.815+@t*(0.00059-0.001813*@t)))/60))/60 -- Mean obliquity of the ecliptic in degrees

		DECLARE @Epsilon_p FLOAT = @Epsilon_0+0.00256*COS((125.04-1934.136*@t)*PI()/180) -- Corrected obliquity of the ecliptic in degrees
		DECLARE @Epsilon_p_Rn FLOAT = @Epsilon_p*PI()/180 --Change to radians

		DECLARE @delta_Rn FLOAT = ASIN(SIN(@Epsilon_p_Rn)*SIN(@lambda_Rn)) -- Declination of the sun in radians
		DECLARE @delta FLOAT = @delta_Rn*180/PI() -- Change to degrees

		DECLARE @y FLOAT = POWER(TAN(@Epsilon_p_Rn/2),2)
		DECLARE @EqnTime FLOAT = (@y*SIN(2*@Theta_LO_Rn)-2*@e*SIN(@M_Rn)+4*@e*@y*SIN(@M_Rn)*COS(2*@Theta_LO_Rn)-0.5*@y*@y*SIN(4*@Theta_LO_Rn)-1.25*@e*@e*SIN(2*@M_Rn))*4*180/PI() -- Equation of time in minutes

		DECLARE @HourAngleSunrise_Rn FLOAT = ACOS(COS(90.833*PI()/180)/(COS(@latitude*PI()/180)*COS(@delta_Rn))-TAN(@latitude*PI()/180)*TAN(@delta_Rn)) -- Hour angle sunrise in radians
		DECLARE @HourAngleSunrise FLOAT = @HourAngleSunrise_Rn*180/PI()
		DECLARE @SolarNoon FLOAT = (720-4*@longitude-@EqnTime+@TimeZone*60)/1440
		DECLARE @SunriseTime FLOAT = @SolarNoon-@HourAngleSunrise*4/1440
		DECLARE @SunsetTime FLOAT = @SolarNoon+@HourAngleSunrise*4/1440
		DECLARE @SunlightDuration FLOAT = @HourAngleSunrise*8

		DECLARE @TimeOffset FLOAT = @EqnTime+4*@longitude-60*@TimeZone -- UOM in minutes
		DECLARE @TrueSolarTime FLOAT = DATEPART(HOUR, @ControlDate)*60+DATEPART(MINUTE, @ControlDate)+DATEPART(SECOND, @ControlDate)/60+@TimeOffset -- UOM in minutes
		DECLARE @HourAngle FLOAT = CASE WHEN @TrueSolarTime<0 THEN @TrueSolarTime/4+180 ELSE @TrueSolarTime/4-180 END -- UOM in degrees

		-- Zenith angle
		DECLARE @zenith FLOAT = ACOS(COS(@latitude*PI()/180)*COS(@delta_Rn)*COS(@HourAngle*PI()/180)+SIN(@latitude*PI()/180)*SIN(@delta_Rn)) -- Returns UOM in radians

		DECLARE @SolarElevation FLOAT = 90-@zenith*180/PI() -- UOM in degrees

		-- UOM in degrees
		DECLARE @RC DECIMAL(30, 6) = CASE
			WHEN @SolarElevation>= 85 THEN 0
			WHEN @SolarElevation>= 5 AND @SolarElevation<85 THEN (58.1/TAN(@SolarElevation*PI()/180)-0.07/POWER(TAN(@SolarElevation*PI()/180), 3)+0.000084/POWER(TAN(@SolarElevation*PI()/180), 5))/3600
			WHEN @SolarElevation>= -0.575 AND @SolarElevation<5 THEN (1735-518.2*@SolarElevation+103.4*POWER(@SolarElevation, 2)-12.79*POWER(@SolarElevation, 3)+0.711*POWER(@SolarElevation, 4))/3600
			WHEN @SolarElevation<-0.575 THEN (-20.774/TAN(@SolarElevation*PI()/180))/3600 END
		DECLARE @A_o_RC FLOAT = @SolarElevation+@RC

		-- Solar azimuth angle in degrees
		DECLARE @SolarAzimuth FLOAT =
			CASE
				WHEN @HourAngle>0 THEN CONVERT(NUMERIC(20,10), ACOS((SIN(@latitude*PI()/180)*COS(@zenith)-SIN(@delta_Rn))/(COS(@latitude*PI()/180)*SIN(@zenith)))*180/PI()+180)%CONVERT(DECIMAL(10,5),360)
				ELSE CONVERT(NUMERIC(20,10), 540-ACOS((SIN(@latitude*PI()/180)*COS(@zenith)-SIN(@delta_Rn))/(COS(@latitude*PI()/180)*SIN(@zenith)))*180/PI())%CONVERT(DECIMAL(10,5),360)
			END

		-- Air mass
		-- DECLARE @AirMass FLOAT = CASE WHEN @zenith*180/PI()>=89 THEN 0 ELSE 1/(COS(@zenith)+0.50572*POWER(96.07995-@zenith*180/PI(), -1.6364)) END
		DECLARE @AirMass FLOAT = CASE
			WHEN @zenith*180/PI()>=83 AND @zenith*180/PI()<=87 THEN (1-0.0012*(POWER(1/COS(@zenith), 2)-1))/COS(@zenith)
			WHEN @zenith*180/PI()>=89 THEN 0
			ELSE 1/(COS(@zenith)+0.50572*POWER(96.07995-@zenith*180/PI(), -1.6364)) END

		-- Transmittance of Rayleigh scattering in the atmosphere
		DECLARE @T_R FLOAT = EXP(-0.0903*POWER(@AirMass, 2)*(1+@AirMass-POWER(@AirMass, 1.01)))

		-- Amount of Ozone in a slanted path
		DECLARE @Xo FLOAT = @Uo*@AirMass

		-- Transmittance of Ozone content
		DECLARE @T_Ozone FLOAT = 1-0.1611*@Xo*POWER(1+139.48*@Xo, -0.3035)-0.002715*@Xo*POWER((1+0.044*@Xo+0.0003*POWER(@Xo, 2)), -1)

		-- Transmittance of carbon dioxide and oxygen
		DECLARE @T_UM FLOAT = EXP(-0.0127*POWER(@AirMass, 0.26))

		DECLARE @AvgDew FLOAT = (
			SELECT DewValue FROM #DewTable
			WHERE DATEPART(MINUTE, IntervalEndTime) = DATEPART(MINUTE, @ControlDate)
			AND CAST(IntervalEndTime AS DATE) = CAST(@COntrolDate AS DATE)
			AND DATEPART(HOUR, IntervalEndTime) = DATEPART(HOUR, @ControlDate))

		-- Precipitable water content
		DECLARE @w FLOAT = EXP(-0.0592+0.06912*@AvgDew)

		-- Precipitable water content in a slanted path
		DECLARE @Xw FLOAT = @w*@AirMass

		-- Transmittance of water vapor
		DECLARE @T_w FLOAT = 1-(2.4959*@Xw)/(POWER(1+79.034*@Xw, 0.6828)+6.385*@Xw)

		-- Atmospheric turbidity
		DECLARE @TauA FLOAT = 0.2758*@Tau380+0.35*@Tau500

		-- Transmittance of aerosol absorptance and scattering
		DECLARE @T_A FLOAT = EXP(-POWER(@TauA, 0.873)*(1+@TauA-POWER(@TauA, 0.7088))*POWER(@AirMass, 0.9108))

		-- Transmittance of aerosol absorptance
		DECLARE @T_AA FLOAT = 1-@K1*(1-@AirMass+POWER(@AirMass, 1.06))*(1-@T_A)

		-- Atmospheric albedo
		DECLARE @r_s FLOAT = 0.0685+(1-@Ba)*(1-@T_A/@T_AA)

		DECLARE @Tau_d FLOAT = 2*PI()*(FLOOR(@JD)-1)/365 -- UOM in radians
		DECLARE @Eo FLOAT = 1.00011+0.034221*COS(@Tau_d)+0.00128*SIN(@Tau_d)+0.000719*COS(2*@Tau_d)+0.000077*SIN(2*@Tau_d) -- Eccentricity correction

		-- Extraterrestrial solar irradiance
		DECLARE @ExtSolar FLOAT = @SolarConstant*@Eo*SIN(@A_o_RC*PI()/180)

		DECLARE @DNI FLOAT = CASE WHEN @AirMass<=0 THEN 0 ELSE 0.9662*@ExtSolar*@T_A*@T_w*@T_UM*@T_Ozone*@T_R END
		DECLARE @DHI FLOAT = 0.79*@ExtSolar*@T_AA*@T_w*@T_UM*@T_Ozone*(0.5*(1-@T_R)+@Ba*(1-@T_A/@T_AA))/(1-@AirMass+POWER(@AirMass, 1.02))
		DECLARE @GHI FLOAT = (@DNI+@DHI)/(1-@R_g*@r_s)

		DECLARE @AOI FLOAT = ACOS(COS(@zenith)*COS(@ArrayTilt*PI()/180)+SIN(@zenith)*SIN(@ArrayTilt*PI()/180)*COS((@SolarAzimuth-@ArrayAzimuth)*PI()/180)) -- Angle of incidence in radians
		DECLARE @A_i FLOAT = (@GHI-@DHI)/@ExtSolar

		DECLARE @POA_dir FLOAT = (@GHI-@DHI)/SIN(@A_o_RC*PI()/180)
		DECLARE @POA_refl FLOAT = @GHI*0.2*((1-COS(@ArrayTilt*PI()/180))/2)
		DECLARE @POA_sky FLOAT = @DHI*(@A_i*COS(@AOI)+(1-@A_i)*((1+COS(@ArrayTilt*PI()/180))/2))
		DECLARE @POA FLOAT = @POA_dir+@POA_refl+@POA_sky

		INSERT INTO @ValueTable SELECT @ControlDate, @zenith*180/PI(), @A_o_RC, @SolarAzimuth, @DNI, @DHI, @GHI, COS(@AOI), @POA

		SET @ControlDate = DATEADD(MINUTE, 5, @ControlDate)
	END

SELECT * FROM @ValueTable ORDER BY [Date]
