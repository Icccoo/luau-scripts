--Discord: Iconx9912 | Roblox: icozdev
--[[
	ServerInsight
	Server-sided performance monitoring.
	Made by: Iconx9912 | v1.3.0
	Created: Jan 30, 2026
	Last updated: October 3, 2026

	WHAT THIS DOES:
	This module helps you figure out why your server is lagging.
	It monitors performance in real time and points out the likely cause,
	whether that's too many scripts, physics overload, memory issues, or player behavior.

	Basically: error reports, but for lag.

	USAGE:
	1. Put this ModuleScript in ServerScriptService.
	2. Require it from a normal Script and start it:

		local ServerInsight = require(game.ServerScriptService.ServerInsight)
		ServerInsight.Start()

		--Optional config
		ServerInsight.Start({
			CheckInterval = 5,        --Seconds between checks
			WarnThreshold = 0.03,     --30ms frame time
			CriticalThreshold = 0.05, --50ms frame time
			EnableWarnings = true,
			TrackMemory = true,
			TrackScripts = true,
			TrackNetwork = true,
			TrackPlayers = true,
			DetectTrends = true,
			MemoryGrowthThreshold = 50, --MB of growth between checks
			PartLimit = 10000,
			MovingPartLimit = 500,
			ContactLimit = 1000,
			ScriptCountLimit = 500,
			CharacterPartLimit = 200,
			HighPlayerCount = 30
		})

	The module runs automatically and prints warnings when problems show up.

	EVENTS (OPTIONAL):
	You can hook into warnings or critical lag events to log, alert admins, etc.

		ServerInsight.OnWarning:Connect(function(report)
			print("Warning:", report.Cause)
		end)

		ServerInsight.OnCritical:Connect(function(report)
			print("CRITICAL:", report.Cause)
		end)

	OTHER FUNCTIONS:
		ServerInsight.Stop()                  --Stops monitoring
		ServerInsight.Check()                 --Runs one check right now and returns the report
		ServerInsight.GetCurrentStats()       --Returns a table of live server stats
		ServerInsight.GetPerformanceHistory() --Returns a copy of the recent frame times
		ServerInsight.ResetBaseline()         --Recalculates the baseline (only while stopped)

	REPORTS INCLUDE:
	- Cause (what's lagging the server)
	- Severity (Normal / Warning / Critical)
	- Frame time
	- Extra details + suggestions
	- Timestamp

	TIPS:
	- Don't check too often (under ~3s) or the monitor itself can add overhead
	- The cause is a best guess based on server stats, not a profiler
	- Memory warnings = something isn't being cleaned up

	CHANGELOG:
	v1.3.0 - Fixed OnWarning / OnCritical so :Connect works as documented.
	       - Memory breakdown now uses GetMemoryUsageMbForTag.
	       - Memory, network and trend data are sampled every check instead of only when lag is reported.
	       - Script count is cached instead of scanning the whole game on every report.
	       - Limits moved into config, and Start/Stop can no longer leave two loops running.
	v1.2.0 - Previous release.
]]

--Services used throughout the module.
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local Stats = game:GetService("Stats")

local ServerInsight = {}

--These events let other server scripts react to warnings without changing the monitoring loop.
local warningEvent = Instance.new("BindableEvent")
local criticalEvent = Instance.new("BindableEvent")

ServerInsight.OnWarning = warningEvent.Event
ServerInsight.OnCritical = criticalEvent.Event

--These limits control how much history is kept and how often more expensive checks run.
local MAX_HISTORY = 60
local FRAME_SAMPLES = 10
local SCRIPT_COUNT_REFRESH = 30

--These are the default thresholds and checks used by the monitor. Start() can override them.
local config = {
	CheckInterval = 5,
	WarnThreshold = 0.03,
	CriticalThreshold = 0.05,
	EnableWarnings = true,
	TrackMemory = true,
	TrackScripts = true,
	TrackNetwork = true,
	TrackPlayers = true,
	DetectTrends = true,
	MemoryGrowthThreshold = 50,
	PartLimit = 10000,
	MovingPartLimit = 500,
	ContactLimit = 1000,
	ScriptCountLimit = 500,
	CharacterPartLimit = 200,
	HighPlayerCount = 30
}

--Each monitoring session gets its own ID so an old loop cannot keep running after Stop() and Start().
local runId = 0
local isMonitoring = false
local baselineFrameTime = 0
local lastMemoryUsage = nil
local lastNetwork = nil
local performanceHistory = {}
--Scanning every descendant is relatively expensive, so the script count is cached between refreshes.
local scriptCountCache = {
	Count = 0,
	LastUpdate = -math.huge
}

--Reports use rounded values so small floating point differences do not make the output noisy.
local function round(value, places)
	local scale = 10 ^ places
	return math.floor(value * scale + 0.5) / scale
end

--Stats properties can differ between environments, so pcall prevents a missing stat from stopping the monitor.
local function readStat(name)
	local ok, value = pcall(function()
		return Stats[name]
	end)
	if ok and type(value) == "number" then
		return value
	end
	--Returning 0 keeps later comparisons safe when Roblox does not expose the requested stat.
	return 0
end

--Collect the counters that identify physics load and network activity.
local function getCounts()
	return {
		InstanceCount = readStat("InstanceCount"),
		PrimitivesCount = readStat("PrimitivesCount"),
		MovingPrimitivesCount = readStat("MovingPrimitivesCount"),
		ContactsCount = readStat("ContactsCount"),
		DataSendKbps = readStat("DataSendKbps"),
		DataReceiveKbps = readStat("DataReceiveKbps")
	}
end

--Keep the memory categories together because the report uses them to identify where growth is coming from.
local function getMemoryStats()
	return {
		Total = Stats:GetTotalMemoryUsageMb(),
		Script = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Script),
		Instances = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.Instances),
		PhysicsParts = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.PhysicsParts)
	}
end

--Averaging several Heartbeat samples makes the measurement less dependent on one unusually slow frame.
local function sampleFrameTime(count)
	local sum = 0
	for _ = 1, count do
		sum += RunService.Heartbeat:Wait()
	end
	return sum / count
end

--The baseline represents normal server performance before the monitor starts looking for spikes.
local function calculateBaseline()
	task.wait(5)

	local samples = {}
	for i = 1, 30 do
		samples[i] = sampleFrameTime(5)
		task.wait(0.5)
	end

	table.sort(samples)
	return samples[math.max(1, math.floor(#samples / 2))]
end

--The cache avoids repeatedly walking the entire game just to count active scripts.
local function getScriptCount()
	local now = os.clock()
	if now - scriptCountCache.LastUpdate < SCRIPT_COUNT_REFRESH then
		return scriptCountCache.Count
	end

	--Only enabled server Scripts count because disabled scripts are not doing work.
	local count = 0
	for _, descendant in ipairs(game:GetDescendants()) do
		if descendant:IsA("Script") and not descendant.Disabled then
			count += 1
		end
	end

	scriptCountCache.Count = count
	scriptCountCache.LastUpdate = now
	return count
end

--Network spikes are detected by comparing this sample with the previous committed sample.
local function checkNetwork(counts, commit)
	local sent = counts.DataSendKbps
	local received = counts.DataReceiveKbps
	local previous = lastNetwork

	--Only committed snapshots become the next comparison point. Manual checks pass false so they do not alter the monitoring loop.
	if commit then
		lastNetwork = {
			Sent = sent,
			Received = received
		}
	end

	if not previous then
		return {HasIssue = false}
	end

	local sentSpike = sent > previous.Sent * 3 and sent > 100
	local receivedSpike = received > previous.Received * 3 and received > 100

	if sentSpike or receivedSpike then
		return {
			HasIssue = true,
			SendKbps = round(sent, 1),
			ReceiveKbps = round(received, 1),
			Reason = sentSpike and "Outbound network spike" or "Inbound network spike"
		}
	end

	return {HasIssue = false}
end

--Large character hierarchies can add physics and replication work, so check them separately from the global counts.
local function findHeavyCharacters()
	local heavy = {}

	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character then
			local partCount = 0
			for _, obj in ipairs(character:GetDescendants()) do
				if obj:IsA("BasePart") then
					partCount += 1
				end
			end

			if partCount > config.CharacterPartLimit then
				table.insert(heavy, {
					PlayerName = player.Name,
					UserId = player.UserId,
					PartCount = partCount
				})
			end
		end
	end

	return heavy
end

--Keep recent frame times so later checks can determine whether performance is trending up or down.
local function recordFrameTime(frameTime)
	table.insert(performanceHistory, frameTime)
	if #performanceHistory > MAX_HISTORY then
		table.remove(performanceHistory, 1)
	end
end

--Compare the older half of the history with the newer half instead of reacting to one sample.
local function detectTrend()
	local count = #performanceHistory
	if count < 30 then
		return {HasTrend = false}
	end

	local midpoint = math.floor(count / 2)
	local firstSum = 0
	local secondSum = 0

	for i = 1, midpoint do
		firstSum += performanceHistory[i]
	end
	for i = midpoint + 1, count do
		secondSum += performanceHistory[i]
	end

	local firstAvg = firstSum / midpoint
	local secondAvg = secondSum / (count - midpoint)

	if firstAvg <= 0 then
		return {HasTrend = false}
	end

	if secondAvg > firstAvg * 1.3 then
		return {
			HasTrend = true,
			Type = "Degrading",
			ChangePercent = math.floor(((secondAvg - firstAvg) / firstAvg) * 100)
		}
	end

	if secondAvg < firstAvg * 0.7 then
		return {
			HasTrend = true,
			Type = "Improving",
			ChangePercent = math.floor(((firstAvg - secondAvg) / firstAvg) * 100)
		}
	end

	return {HasTrend = false}
end

--A snapshot groups related measurements together so one lag report is based on the same check.
local function takeSnapshot(commit)
	local counts = getCounts()
	local snapshot = {Counts = counts}

	if config.TrackMemory then
		local memory = getMemoryStats()
		snapshot.Memory = memory
		snapshot.MemoryGrowth = lastMemoryUsage and (memory.Total - lastMemoryUsage) or 0
		--Only monitoring snapshots update the previous value. Check() uses false so a manual check cannot reset the comparison used by the loop.
		if commit then
			lastMemoryUsage = memory.Total
		end
	end

	if config.TrackNetwork then
		snapshot.Network = checkNetwork(counts, commit)
	end

	return snapshot
end

--The first matching cause wins. That means the order of checks below determines which cause appears on the report when several problems exist.
local function setCause(report, cause)
	if report.Cause == "Unknown" then
		report.Cause = cause
	end
end

--Run the individual checks in a fixed order and add details or suggestions without changing the underlying measurements.
local function identifyLagSource(frameTime, snapshot)
	local report = {
		Cause = "Unknown",
		Severity = frameTime > config.CriticalThreshold and "Critical" or frameTime > config.WarnThreshold and "Warning" or "Normal",
		FrameTime = frameTime,
		Details = {},
		Timestamp = os.time(),
		Suggestions = {}
	}

	local counts = snapshot.Counts
	local physicsOverloaded = counts.PrimitivesCount > config.PartLimit
		or counts.MovingPrimitivesCount > config.MovingPartLimit
		or counts.ContactsCount > config.ContactLimit

	--Physics is checked first, so it gets priority if multiple possible causes are found.
	if physicsOverloaded then
		setCause(report, "Physics Overload")
		report.Details.TotalParts = counts.PrimitivesCount
		report.Details.MovingParts = counts.MovingPrimitivesCount
		report.Details.Contacts = counts.ContactsCount
		table.insert(report.Suggestions, "Consider reducing part count or using simpler collision shapes")
		if counts.MovingPrimitivesCount > config.MovingPartLimit then
			table.insert(report.Suggestions, "Too many moving parts - check for runaway physics or player abuse")
		end
		if counts.ContactsCount > config.ContactLimit then
			table.insert(report.Suggestions, "High contact count - parts may be vibrating or colliding excessively")
		end
	end

	--Memory growth is checked next because a rising total can point to cleanup or data problems.
	if snapshot.Memory and snapshot.MemoryGrowth > config.MemoryGrowthThreshold then
		local memory = snapshot.Memory
		setCause(report, "Memory Growth")
		report.Details.MemoryGrowthMB = round(snapshot.MemoryGrowth, 2)
		report.Details.TotalMemoryMB = round(memory.Total, 2)
		report.Details.ScriptMemoryMB = round(memory.Script, 2)
		report.Details.InstanceMemoryMB = round(memory.Instances, 2)
		report.Details.PhysicsMemoryMB = round(memory.PhysicsParts, 2)
		table.insert(report.Suggestions, "Something isn't cleaning up properly - check for memory leaks")

		if memory.Script > memory.Total * 0.5 then
			table.insert(report.Suggestions, "Scripts are using over 50% of memory - check for data leaks")
		end
	end

	--Script count is a separate signal because a high number of active scripts can create unnecessary server work.
	if config.TrackScripts then
		local scriptCount = getScriptCount()
		if scriptCount > config.ScriptCountLimit then
			setCause(report, "Script Issues")
			report.Details.ScriptIssues = {
				{Issue = "High script count", Count = scriptCount}
			}
			table.insert(report.Suggestions, "Many scripts are running - consider consolidating them into shared loops or modules")
		end
	end

	--Network spikes can point to excessive remotes or replication rather than local physics work.
	if snapshot.Network and snapshot.Network.HasIssue then
		setCause(report, "Network Spike")
		report.Details.NetworkSendKbps = snapshot.Network.SendKbps
		report.Details.NetworkReceiveKbps = snapshot.Network.ReceiveKbps
		report.Details.NetworkReason = snapshot.Network.Reason
		table.insert(report.Suggestions, "Check for excessive remote events or data replication")
	end

	--Player-specific checks help identify whether one or more characters are contributing unusual load.
	if config.TrackPlayers then
		local heavyCharacters = findHeavyCharacters()
		if #heavyCharacters > 0 then
			setCause(report, "Player Impact")
			report.Details.SuspiciousPlayers = heavyCharacters
			table.insert(report.Suggestions, "Some players have abnormally high part counts - possible exploiting")
		end
	end

	--Trend detection looks at the stored history to catch gradual degradation that a single sample would miss.
	if config.DetectTrends then
		local trend = detectTrend()
		if trend.HasTrend then
			report.Details.PerformanceTrend = trend.Type
			report.Details.TrendChange = trend.ChangePercent .. "%"

			if trend.Type == "Degrading" then
				table.insert(report.Suggestions, "Performance is degrading over time - investigate recent changes")
			end
		end
	end

	--Player count is checked last because it can contribute to overall load without identifying a specific system.
	local playerCount = #Players:GetPlayers()
	if playerCount > config.HighPlayerCount then
		report.Details.PlayerCount = playerCount
		setCause(report, "High Player Count")
		table.insert(report.Suggestions, "Performance degradation may be due to high player count")
	end

	if report.Cause == "Unknown" then
		--If every specific check misses, the report keeps the general cause.
		report.Cause = "General Performance Issue"
		table.insert(report.Suggestions, "Frame time spike detected - cause unclear")
		table.insert(report.Suggestions, "Check recent changes to your game or scripts")
	end

	return report
end

--Convert table entries into readable key=value text so nested report details can be printed.
local function describeItem(item)
	if type(item) ~= "table" then
		return tostring(item)
	end

	local keys = {}
	for key in pairs(item) do
		table.insert(keys, tostring(key))
	end
	table.sort(keys)

	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, key .. "=" .. tostring(item[key]))
	end
	return table.concat(parts, " ")
end

--Turn the structured report into console text while keeping large lists from flooding the output.
local function formatReport(report)
	local threshold = report.Severity == "Critical" and config.CriticalThreshold or config.WarnThreshold

	local lines = {
		string.format(
			"\n[ServerInsight] %s REPORT at %s",
			report.Severity:upper(),
			DateTime.fromUnixTimestamp(report.Timestamp):FormatLocalTime("LT", "en-us")
		),
		string.format("Cause: %s", report.Cause),
		string.format("Frame Time: %.2fms (threshold: %.2fms)", report.FrameTime * 1000, threshold * 1000)
	}

	local keys = {}
	for key in pairs(report.Details) do
		table.insert(keys, key)
	end
	table.sort(keys)

	if #keys > 0 then
		table.insert(lines, "Details:")
		for _, key in ipairs(keys) do
			local value = report.Details[key]
			if type(value) == "table" then
				table.insert(lines, string.format("  %s: [%d items]", key, #value))
				--Limit detailed list output so a large report does not fill the entire console.
				for i, item in ipairs(value) do
					if i > 3 then
						break
					end
					table.insert(lines, "    - " .. describeItem(item))
				end
				if #value > 3 then
					table.insert(lines, string.format("    ... and %d more", #value - 3))
				end
			else
				table.insert(lines, string.format("  %s: %s", key, tostring(value)))
			end
		end
	end

	if #report.Suggestions > 0 then
		table.insert(lines, "Suggestions:")
		for _, suggestion in ipairs(report.Suggestions) do
			table.insert(lines, "  - " .. suggestion)
		end
	end

	return table.concat(lines, "\n")
end

--This loop owns the live monitoring session. The ID check prevents an older spawned loop from surviving a Stop() followed by Start().
local function monitorLoop(id)
	--Establish normal performance before the regular interval checks begin.
	baselineFrameTime = calculateBaseline()
	if id ~= runId then
		return
	end

	--Commit the first snapshot so later network and memory checks have a previous value to compare against.
	takeSnapshot(true)
	print(string.format("[ServerInsight] Baseline frame time: %.2fms", baselineFrameTime * 1000))

	while isMonitoring and id == runId do
		task.wait(config.CheckInterval)
		if not isMonitoring or id ~= runId then
			break
		end

		local frameTime = sampleFrameTime(FRAME_SAMPLES)
		local snapshot = takeSnapshot(true)
		recordFrameTime(frameTime)

		print(string.format(
			"[ServerInsight] Frame time: %.2fms | Memory: %.1fMB | Players: %d",
			frameTime * 1000,
			Stats:GetTotalMemoryUsageMb(),
			#Players:GetPlayers()
			))

		--Only run detailed cause analysis after the frame time crosses the warning threshold.
		if frameTime > config.WarnThreshold then
			local report = identifyLagSource(frameTime, snapshot)

			if config.EnableWarnings then
				warn(formatReport(report))
			end

			if report.Severity == "Critical" then
				criticalEvent:Fire(report)
			else
				warningEvent:Fire(report)
			end
		end
	end
end

--Start one monitoring session and optionally replace only the settings supplied by the caller.
function ServerInsight.Start(customConfig)
	--Prevent two monitoring loops from running at the same time.
	if isMonitoring then
		warn("[ServerInsight] Already monitoring - call Stop() first to restart")
		return
	end

	--Apply only known configuration keys so unrelated values cannot alter the module state.
	if customConfig then
		for key, value in pairs(customConfig) do
			if config[key] ~= nil then
				config[key] = value
			end
		end
	end

	--Incrementing the ID invalidates any older loop before the new one starts.
	runId += 1
	isMonitoring = true

	print("[ServerInsight] Monitoring started with config:")
	print("Check Interval:", config.CheckInterval, "seconds")
	print("Warning Threshold:", config.WarnThreshold * 1000, "ms")
	print("Critical Threshold:", config.CriticalThreshold * 1000, "ms")
	print("Track Memory:", config.TrackMemory)
	print("Track Scripts:", config.TrackScripts)
	print("Track Network:", config.TrackNetwork)
	print("Track Players:", config.TrackPlayers)
	print("Detect Trends:", config.DetectTrends)

	--Run the monitor separately so Start() can return without waiting for the loop.
	task.spawn(monitorLoop, runId)
end

--Stop the current session and clear comparison values so the next session starts cleanly.
function ServerInsight.Stop()
	isMonitoring = false
	runId += 1
	lastMemoryUsage = nil
	lastNetwork = nil
	print("[ServerInsight] Monitoring stopped")
end

--Return a fresh snapshot without changing the stored monitoring state.
function ServerInsight.GetCurrentStats()
	local counts = getCounts()
	local memory = getMemoryStats()

	return {
		FrameTime = sampleFrameTime(FRAME_SAMPLES),
		MemoryUsageMB = memory.Total,
		MemoryBreakdown = memory,
		PlayerCount = #Players:GetPlayers(),
		InstanceCount = counts.InstanceCount,
		PrimitivesCount = counts.PrimitivesCount,
		MovingPrimitivesCount = counts.MovingPrimitivesCount,
		NetworkSendKbps = counts.DataSendKbps,
		NetworkReceiveKbps = counts.DataReceiveKbps,
		IsMonitoring = isMonitoring,
		BaselineFrameTime = baselineFrameTime
	}
end

--Return a copy so callers can inspect the history without modifying the module's internal table.
function ServerInsight.GetPerformanceHistory()
	return table.clone(performanceHistory)
end

--Recalculate the normal frame time only when the live monitor is stopped.
function ServerInsight.ResetBaseline()
	if isMonitoring then
		warn("[ServerInsight] Cannot reset baseline while monitoring - call Stop() first")
		return
	end

	baselineFrameTime = calculateBaseline()
	print(string.format("[ServerInsight] New baseline: %.2fms", baselineFrameTime * 1000))
end

--Run the same cause analysis manually, but do not commit its memory or network values as the next monitoring baseline.
function ServerInsight.Check()
	local frameTime = sampleFrameTime(FRAME_SAMPLES)
	local snapshot = takeSnapshot(false)
	local report = identifyLagSource(frameTime, snapshot)
	print(formatReport(report))
	return report
end

return ServerInsight
