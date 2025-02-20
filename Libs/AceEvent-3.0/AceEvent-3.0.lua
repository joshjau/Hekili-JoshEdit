--- AceEvent-3.0 provides event registration and secure dispatching.
-- All dispatching is done using **CallbackHandler-1.0**. AceEvent is a simple wrapper around
-- CallbackHandler, and dispatches all game events or addon message to the registrees.
--
-- **AceEvent-3.0** can be embeded into your addon, either explicitly by calling AceEvent:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceEvent itself.\\
-- It is recommended to embed AceEvent, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceEvent.
-- @class file
-- @name AceEvent-3.0
-- @release $Id: AceEvent-3.0.lua 1202 2024-02-15 23:11:22Z nevcairiel $
-- @website https://warcraft.wiki.gg/wiki/COMBAT_LOG_EVENT
local CallbackHandler = LibStub("CallbackHandler-1.0")

local MAJOR, MINOR = "AceEvent-3.0", 5  -- Bumped minor version for new features
local AceEvent = LibStub:NewLibrary(MAJOR, MINOR)

if not AceEvent then return end

-- Lua APIs
local pairs = pairs
local type = type
local select = select
local GetTime = GetTime

-- WoW APIs
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

-- Constants for Hekili-specific optimizations
local COMBAT_EVENTS = {
    -- Cast Events
    SPELL_CAST_START = true,
    SPELL_CAST_SUCCESS = true,
    SPELL_CAST_FAILED = true,
    SPELL_EMPOWER_START = true,  -- Added for empowered spells
    SPELL_EMPOWER_END = true,    -- Added for empowered spells
    SPELL_EMPOWER_INTERRUPT = true, -- Added for empowered spells
    
    -- Damage Events
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_MISSED = true,
    RANGE_DAMAGE = true,
    SWING_DAMAGE = true,
    ENVIRONMENTAL_DAMAGE = true,
    
    -- Aura Events
    SPELL_AURA_APPLIED = true,
    SPELL_AURA_REMOVED = true,
    SPELL_AURA_REFRESH = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REMOVED_DOSE = true,
    SPELL_AURA_BROKEN = true,
    SPELL_AURA_BROKEN_SPELL = true,
    
    -- Resource Events
    SPELL_ENERGIZE = true,
    SPELL_PERIODIC_ENERGIZE = true,
    SPELL_DRAIN = true,
    SPELL_LEECH = true,
    
    -- Unit Events
    UNIT_DIED = true,
    UNIT_DESTROYED = true,
    UNIT_DISSIPATES = true,
    
    -- Interrupt Events
    SPELL_INTERRUPT = true,
    
    -- Dispel Events
    SPELL_DISPEL = true,
    SPELL_STOLEN = true,
    
    -- Healing Events (for certain class mechanics)
    SPELL_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
}

-- Enhanced empowerment tracking
local EMPOWERED_SPELLS = {
    -- Devastation
    [382266] = true, -- Fire Breath (Font of Magic)
    [357208] = true, -- Fire Breath
    [382411] = true, -- Eternity Surge (Font of Magic)
    [359073] = true, -- Eternity Surge
    -- Preservation
    [355936] = true, -- Dream Breath
    [382614] = true, -- Dream Breath (Font of Magic)
    -- Augmentation
    [396286] = true, -- Upheaval
    [408092] = true, -- Upheaval (Font of Magic)
}

-- Local cache for frequent operations
local wipe = wipe
local unpack = unpack
local next = next
---@type fun(): number
local GetTime = GetTime
---@type fun(): number
local GetTimePreciseSec = GetTimePreciseSec
local min = math.min
local max = math.max
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
---@type fun(unit: string, stage: number): number
local GetUnitEmpowerStageDuration = C_UnitAuras and C_UnitAuras.GetUnitEmpowerStageDuration or GetUnitEmpowerStageDuration
---@type fun(unit: string): number
local GetUnitEmpowerHoldAtMaxTime = C_UnitAuras and C_UnitAuras.GetUnitEmpowerHoldAtMaxTime or GetUnitEmpowerHoldAtMaxTime
local events = AceEvent.events

-- Timing optimization for different scenarios
local function GetHighPrecisionTime()
    return GetTimePreciseSec() or GetTime()
end

-- Performance optimizations
local BUFFER_THRESHOLD = 0.1  -- 100ms threshold for event buffering
local MAX_BUFFER_SIZE = 100   -- Maximum number of buffered events
local PRECISE_TIMING_EVENTS = {
    SPELL_EMPOWER_START = true,
    SPELL_EMPOWER_END = true,
    SPELL_EMPOWER_INTERRUPT = true,
    SPELL_CAST_START = true,
    SPELL_CAST_SUCCESS = true,
    SPELL_CAST_FAILED = true
}

-- Create our event frame with modern frame features
---@type Frame
AceEvent.frame = AceEvent.frame or CreateFrame("Frame", "AceEvent30Frame", UIParent, "SecureHandlerBaseTemplate")
AceEvent.frame:SetFrameStrata("LOW")  -- Lower strata for better performance
AceEvent.embeds = AceEvent.embeds or {} -- what objects embed this lib
AceEvent.eventBuffer = {} -- Event buffering for high-frequency events
AceEvent.lastEventTime = 0 -- Timestamp tracking for event throttling

-- APIs and registry for blizzard events, using CallbackHandler lib
---@class AceEvent-3.0
---@field events table
---@field events.callbacks table<string, table>
if not AceEvent.events then
    AceEvent.events = CallbackHandler:New(AceEvent,
        "RegisterEvent", "UnregisterEvent", "UnregisterAllEvents")
    AceEvent.events.callbacks = AceEvent.events.callbacks or {}
end

-- APIs and registry for IPC messages, with enhanced error handling
if not AceEvent.messages then
    AceEvent.messages = CallbackHandler:New(AceEvent,
        "RegisterMessage", "UnregisterMessage", "UnregisterAllMessages"
    )
    AceEvent.SendMessage = AceEvent.messages.Fire
end

-- Memory and garbage collection optimizations
local UpdateAddOnMemoryUsage = UpdateAddOnMemoryUsage
local GetAddOnMemoryUsage = GetAddOnMemoryUsage
local gcinfo = gcinfo
local collectgarbage = collectgarbage
local C_Timer = C_Timer

-- Timer handling for buffered events
local BUFFER_PROCESS_INTERVAL = 0.1 -- Process buffered events every 100ms
local bufferTimer = nil

-- Process buffered events safely
local function ProcessBufferedEvents()
    if not AceEvent.eventBuffer then return end
    
    local currentTime = GetTime()
    local processedCount = 0
    
    -- Process up to 50 events per batch to prevent frame drops
    while processedCount < 50 and #AceEvent.eventBuffer > 0 do
        local eventData = table.remove(AceEvent.eventBuffer, 1)
        if eventData then
            AceEvent.events:Fire(eventData.eventType, eventData)
            ReleaseEventData(eventData)
            processedCount = processedCount + 1
        end
    end
    
    -- Schedule next processing if there are remaining events
    if #AceEvent.eventBuffer > 0 then
        bufferTimer = C_Timer.After(BUFFER_PROCESS_INTERVAL, ProcessBufferedEvents)
    else
        bufferTimer = nil
    end
end

-- Enhanced event buffering
local function BufferEvent(eventData)
    if not AceEvent.eventBuffer then
        AceEvent.eventBuffer = {}
    end
    
    if #AceEvent.eventBuffer < MAX_BUFFER_SIZE then
        AceEvent.eventBuffer[#AceEvent.eventBuffer + 1] = eventData
        
        -- Start processing timer if not already running
        if not bufferTimer then
            bufferTimer = C_Timer.After(BUFFER_PROCESS_INTERVAL, ProcessBufferedEvents)
        end
        return true
    end
    
    return false
end

-- Initialize core tables
AceEvent.eventPool = AceEvent.eventPool or {}
local eventPool = AceEvent.eventPool

-- Define events that should be buffered for batch processing
local BUFFER_EVENTS = {
    -- High frequency combat events
    SPELL_DAMAGE = true,
    SPELL_PERIODIC_DAMAGE = true,
    SPELL_HEAL = true,
    SPELL_PERIODIC_HEAL = true,
    SWING_DAMAGE = true,
    
    -- Important state tracking events that may occur frequently
    SPELL_AURA_APPLIED = true,
    SPELL_AURA_REMOVED = true,
    SPELL_AURA_APPLIED_DOSE = true,
    SPELL_AURA_REMOVED_DOSE = true,
    
    -- Resource tracking events
    SPELL_ENERGIZE = true,
    SPELL_PERIODIC_ENERGIZE = true
}

AceEvent.empowerment = AceEvent.empowerment or {
    active = false,
    spell = nil,
    start = 0,
    preciseStart = 0,
    finish = 0,
    hold = 0,
    currentStage = 0,
    maxStages = 0,
    stages = {},
    lastUpdate = 0
}

-- Enhanced memory pool management for modern high-end systems
local poolSize = 0
local MAX_POOL_SIZE = 4000 -- Doubled for high-memory systems
local POOL_GROWTH_THRESHOLD = 0.8 -- 80% pool utilization triggers growth
local BUFFER_THRESHOLD = 0.1  -- 100ms threshold for normal events
local INSTANT_THRESHOLD = 0.0  -- No delay for instant-cast abilities
local MAX_BUFFER_SIZE = 400   -- Doubled buffer size for high-performance systems
local GC_INTERVAL = 300 -- 5 minutes
local MEMORY_THRESHOLD = 1024 * 1024 * 100 -- Increased to 100MB for high-memory systems

-- Define instant-cast abilities that need zero-delay processing
local INSTANT_CAST_EVENTS = {
    SPELL_INTERRUPT = true,
    SPELL_CAST_SUCCESS = {
        -- Interrupts
        [1766] = true,   -- Kick
        [2139] = true,   -- Counterspell
        [6552] = true,   -- Pummel
        [47528] = true,  -- Mind Freeze
        [57994] = true,  -- Wind Shear
        [96231] = true,  -- Rebuke
        [106839] = true, -- Skull Bash
        [116705] = true, -- Spear Hand Strike
        [147362] = true, -- Counter Shot
        [183752] = true, -- Disrupt
        [187707] = true, -- Muzzle
        -- Stuns
        [408] = true,    -- Kidney Shot
        [1833] = true,   -- Cheap Shot
        [5211] = true,   -- Mighty Bash
        [30283] = true,  -- Shadowfury
        [46968] = true,  -- Shockwave
        [107570] = true, -- Storm Bolt
        [119381] = true, -- Leg Sweep
        [179057] = true, -- Chaos Nova
        [198304] = true, -- Psychic Scream
        [207171] = true, -- Winter is Coming
        -- Other critical instant abilities
        [19647] = true,  -- Spell Lock
        [78675] = true,  -- Solar Beam
        [89766] = true   -- Axe Toss
    }
}

-- Enhanced event processing with instant-cast priority
local function ShouldProcessInstantly(eventType, spellID)
    return INSTANT_CAST_EVENTS[eventType] or 
           (eventType == "SPELL_CAST_SUCCESS" and INSTANT_CAST_EVENTS[eventType] and INSTANT_CAST_EVENTS[eventType][spellID])
end

-- Pre-allocate larger initial event pool for better performance
for i = 1, 200 do -- Doubled initial pool size
    eventPool[{}] = true
    poolSize = poolSize + 1
end

-- Enhanced memory cleanup with WoW's garbage collector
local lastGCTime = 0

--- Checks and manages addon memory usage.
-- Implements WoW-specific garbage collection strategies.
-- @note Forces collection if memory exceeds threshold or timer expires
-- @note Resets pool if memory pressure is high
local function CheckMemoryUsage()
    local currentTime = GetTime()
    -- Only check periodically to reduce overhead
    if currentTime - lastGCTime > GC_INTERVAL then
        UpdateAddOnMemoryUsage()
        local currentMemory = GetAddOnMemoryUsage("Hekili")
        
        -- Force collection if memory threshold exceeded
        if currentMemory > MEMORY_THRESHOLD then
            -- Use WoW's garbage collector with collect mode
            collectgarbage("collect")
            lastGCTime = currentTime
            
            -- Reset pool if memory usage is high
            if poolSize > MAX_POOL_SIZE / 2 then
                wipe(eventPool)
                -- Reinitialize with smaller pool
                for i = 1, 50 do
                    eventPool[{}] = true
                end
                poolSize = 50
            end
        end
    end
end

--- Manages the event pool size and growth.
-- Implements adaptive pool sizing based on usage patterns.
-- @note Grows pool when utilization is high
-- @note Prevents unbounded growth
local function ManageEventPool()
    local currentUsage = #AceEvent.eventBuffer / MAX_BUFFER_SIZE
    if currentUsage > POOL_GROWTH_THRESHOLD and poolSize < MAX_POOL_SIZE then
        -- Grow pool if heavily utilized
        local growth = math.min(200, MAX_POOL_SIZE - poolSize)
        for i = 1, growth do
            eventPool[{}] = true
            poolSize = poolSize + 1
        end
    end
end

-- Event data acquisition and release with optimized pooling
local function AcquireEventData()
    local data = next(eventPool)
    if data then
        eventPool[data] = nil
        poolSize = poolSize - 1
        return data
    end
    -- Grow pool if needed
    if poolSize < MAX_POOL_SIZE / 2 then
        local growth = math.min(200, MAX_POOL_SIZE - poolSize) -- Increased growth step
        for i = 1, growth do
            eventPool[{}] = true
            poolSize = poolSize + 1
        end
        data = next(eventPool)
        if data then
            eventPool[data] = nil
            poolSize = poolSize - 1
            return data
        end
    end
    return {}
end

local function ReleaseEventData(data)
    if type(data) ~= "table" then return end
    if poolSize > MAX_POOL_SIZE then
        -- Let GC handle it if pool is too large
        data = nil
        return
    end
    wipe(data)
    eventPool[data] = true
    poolSize = poolSize + 1
end

--[[ Event Registration System
The event registration system handles the registration and unregistration of events
with optimized performance tracking and memory management. It supports both standard
WoW events and custom messages.

Features:
- Automatic event validation
- Performance metrics tracking
- Memory-efficient event handling
- Combat log optimization
- Precise timing for critical events

@see https://warcraft.wiki.gg/wiki/Events
@see https://warcraft.wiki.gg/wiki/COMBAT_LOG_EVENT
--]]

--- Enhanced event registration with validation and performance tracking.
-- @param target table The target object registering the event
-- @param eventname string The name of the event to register
-- @return boolean Whether the event was successfully registered
-- @note Automatically initializes performance tracking for the event
function AceEvent.events:OnUsed(target, eventname)
    if type(eventname) ~= "string" then
        error(("Bad argument #2 to `RegisterEvent` (string expected, got %s)"):format(type(eventname)), 2)
    end
    
    -- Enhanced event name validation
    if not eventname:match("^[%u_]+$") then
        error(("Invalid event name format: %s (expected uppercase with underscores)"):format(eventname), 2)
    end
    
    -- Track registration order for optimal event processing
    if not AceEvent.eventOrder then AceEvent.eventOrder = {} end
    if not AceEvent.eventOrder[eventname] then
        AceEvent.eventOrder[eventname] = #AceEvent.eventOrder + 1
    end
    
    -- Initialize event-specific optimizations
    if PRECISE_TIMING_EVENTS[eventname] then
        if not AceEvent.preciseEvents then AceEvent.preciseEvents = {} end
        AceEvent.preciseEvents[eventname] = true
    end
    
    -- Performance optimization for combat log events
    if eventname == "COMBAT_LOG_EVENT_UNFILTERED" then
        if not AceEvent.combatLogInitialized then
            AceEvent.combatLogInitialized = true
            -- Pre-allocate combat log event pool
            for i = 1, 50 do -- Pre-allocate 50 event objects
                eventPool[{}] = true
            end
        end
    end
    
    local registered = AceEvent.frame:RegisterEvent(eventname)
    if registered then
        -- Initialize event-specific data structures
        if not AceEvent.eventData then AceEvent.eventData = {} end
        if not AceEvent.eventData[eventname] then
            AceEvent.eventData[eventname] = {
                lastFired = 0,
                processCount = 0,
                averageProcessTime = 0
            }
        end
    end
    return registered
end

-- Enhanced event unregistration with better cleanup
function AceEvent.events:OnUnused(target, eventname)
    if type(eventname) ~= "string" then
        error(("Bad argument #2 to `UnregisterEvent` (string expected, got %s)"):format(type(eventname)), 2)
    end
    
    -- Performance optimization: Check if event is actually registered
    if not AceEvent.eventData or not AceEvent.eventData[eventname] then
        return false
    end
    
    -- Enhanced cleanup for event-specific data
    if AceEvent.eventData[eventname] then
        if AceEvent.eventData[eventname].processCount > 0 then
            local data = AceEvent.eventData[eventname]
            if not AceEvent.performanceHistory then AceEvent.performanceHistory = {} end
            if not AceEvent.performanceHistory[eventname] then
                AceEvent.performanceHistory[eventname] = {
                    totalProcessTime = 0,
                    processCount = 0,
                    averageProcessTime = 0,
                    lastUnregistered = GetTime()
                }
            end
            local history = AceEvent.performanceHistory[eventname]
            history.totalProcessTime = history.totalProcessTime + (data.averageProcessTime * data.processCount)
            history.processCount = history.processCount + data.processCount
            history.averageProcessTime = history.totalProcessTime / history.processCount
            history.lastUnregistered = GetTime()
        end
        AceEvent.eventData[eventname] = nil
    end
    
    -- Cleanup buffered events
    if BUFFER_EVENTS[eventname] then
        local i = 1
        local removed = 0
        while i <= #AceEvent.eventBuffer do
            local bufferedEvent = AceEvent.eventBuffer[i]
            if bufferedEvent and bufferedEvent.eventType == eventname then
                ReleaseEventData(bufferedEvent)
                table.remove(AceEvent.eventBuffer, i)
                removed = removed + 1
            else
                i = i + 1
            end
        end
        
        -- Check memory after significant cleanup
        if removed > MAX_BUFFER_SIZE / 4 then
            CheckMemoryUsage()
        end
    end
    
    -- Cleanup tracking tables
    if AceEvent.preciseEvents then
        AceEvent.preciseEvents[eventname] = nil
    end
    
    if AceEvent.eventOrder and AceEvent.eventOrder[eventname] then
        local oldOrder = AceEvent.eventOrder[eventname]
        AceEvent.eventOrder[eventname] = nil
        if oldOrder < #AceEvent.eventOrder then
            for event, order in pairs(AceEvent.eventOrder) do
                if order > oldOrder then
                    AceEvent.eventOrder[event] = order - 1
                end
            end
        end
    end
    
    -- Special handling for combat log
    if eventname == "COMBAT_LOG_EVENT_UNFILTERED" then
        if AceEvent.combatLogInitialized then
            AceEvent.combatLogInitialized = false
            if not next(AceEvent.events.callbacks) then
                wipe(eventPool)
                poolSize = 0
            end
        end
    end
    
    local success = AceEvent.frame:UnregisterEvent(eventname)
    
    -- Check memory state after unregistration
    if success and AceEvent.eventData and not next(AceEvent.eventData) then
        CheckMemoryUsage()
    end
    
    return success
end

-- Enhanced empowerment handling
---@param spellID number
---@param isStart boolean
local function HandleEmpowerment(spellID, isStart)
    if not EMPOWERED_SPELLS[spellID] then return end
    
    local emp = AceEvent.empowerment
    local currentTime = GetTime() -- Use regular GetTime for frame-based updates
    local preciseTime = GetHighPrecisionTime() -- Use precise time for duration calculations
    
    if isStart then
        wipe(emp.stages)
        emp.active = true
        emp.spell = spellID
        emp.start = currentTime
        emp.preciseStart = preciseTime
        emp.maxStages = 0
        emp.currentStage = 0
        emp.lastUpdate = currentTime
        
        -- Calculate stage timings with error handling
        for i = 1, 4 do
            local duration = GetUnitEmpowerStageDuration("player", i - 1)
            if not duration or duration == 0 then break end
            
            emp.maxStages = i
            if i == 1 then
                emp.stages[i] = emp.preciseStart + (duration * 0.001)
            else
                emp.stages[i] = emp.stages[i - 1] + (duration * 0.001)
            end
        end
        
        if emp.maxStages > 0 then
            emp.finish = emp.stages[emp.maxStages]
            local holdTime = GetUnitEmpowerHoldAtMaxTime("player")
            emp.hold = emp.finish + (holdTime and holdTime * 0.001 or 0)
            
            -- Fire event with complete empowerment data
            AceEvent.events:Fire("EMPOWERMENT_START", spellID, {
                stages = emp.stages,
                maxStages = emp.maxStages,
                start = emp.start,
                preciseStart = emp.preciseStart,
                finish = emp.finish,
                hold = emp.hold,
                currentStage = emp.currentStage,
                predictedDuration = emp.finish - emp.preciseStart
            })
        end
    else
        -- Handle empowerment end/interrupt
        if emp.active and emp.spell == spellID then
            local eventType = preciseTime >= emp.finish and "EMPOWERMENT_COMPLETE" or "EMPOWERMENT_INTERRUPTED"
            local actualDuration = preciseTime - emp.preciseStart
            
            AceEvent.events:Fire(eventType, spellID, {
                finalStage = emp.currentStage,
                duration = actualDuration,
                preciseEnd = preciseTime,
                expectedDuration = emp.finish - emp.preciseStart
            })
            
            emp.active = false
            emp.spell = nil
            emp.start = 0
            emp.preciseStart = 0
            emp.finish = 0
            emp.hold = 0
            emp.currentStage = 0
            emp.lastUpdate = currentTime
            wipe(emp.stages)
            emp.maxStages = 0
        end
    end
end

-- Combat Log Event Base Parameters (11 base values)
local BASE_COMBAT_LOG_PARAMS = {
    [1] = "timestamp",      -- number: Time of event (GetTime() format)
    [2] = "eventType",      -- string: Full event type (e.g., "SPELL_DAMAGE")
    [3] = "hideCaster",     -- boolean: Whether source is hidden
    [4] = "sourceGUID",     -- string: Full GUID of source entity
    [5] = "sourceName",     -- string: Name of source unit
    [6] = "sourceFlags",    -- number: Unit flags for source (bitmask)
    [7] = "sourceRaidFlags",-- number: Raid target index for source
    [8] = "destGUID",       -- string: Full GUID of destination entity
    [9] = "destName",       -- string: Name of destination unit
    [10] = "destFlags",     -- number: Unit flags for destination (bitmask)
    [11] = "destRaidFlags"  -- number: Raid target index for destination
}

-- Enhanced event data handling
local function ProcessEventData(...)
    local numArgs = select("#", ...)
    local eventData = AcquireEventData()
    
    -- Store base parameters
    for i = 1, min(11, numArgs) do
        eventData[i] = select(i, ...)
    end
    
    -- Store extra parameters based on event type
    local eventType = eventData[2]
    if numArgs > 11 then
        if eventType:match("^SPELL") or eventType:match("^RANGE") then
            -- Spell/Ability Events (12-15)
            eventData.spellID = select(12, ...)
            eventData.spellName = select(13, ...)
            eventData.spellSchool = select(14, ...)
            
            -- Additional parameters for specific events
            if eventType:match("_DAMAGE$") then
                eventData.amount = select(15, ...)
                eventData.overkill = select(16, ...)
                eventData.school = select(17, ...)
                eventData.resisted = select(18, ...)
                eventData.blocked = select(19, ...)
                eventData.absorbed = select(20, ...)
                eventData.critical = select(21, ...)
                eventData.glancing = select(22, ...)
                eventData.crushing = select(23, ...)
            elseif eventType:match("_MISSED$") then
                eventData.missType = select(15, ...)
                eventData.isOffHand = select(16, ...)
                eventData.amountMissed = select(17, ...)
            elseif eventType:match("_HEAL") then
                eventData.amount = select(15, ...)
                eventData.overhealing = select(16, ...)
                eventData.absorbed = select(17, ...)
                eventData.critical = select(18, ...)
            elseif eventType:match("_AURA") then
                -- Enhanced aura tracking for better DPS calculations
                if eventType:match("_APPLIED") or eventType:match("_REMOVED") or eventType:match("_REFRESH") then
                    eventData.auraType = select(15, ...) -- BUFF or DEBUFF
                    if eventType:match("_DOSE$") then
                        eventData.amount = select(16, ...) -- Stack count
                    end
                elseif eventType:match("_BROKEN") then
                    if eventType == "SPELL_AURA_BROKEN_SPELL" then
                        eventData.extraSpellID = select(15, ...)
                        eventData.extraSpellName = select(16, ...)
                        eventData.extraSchool = select(17, ...)
                        eventData.auraType = select(18, ...)
                    else
                        eventData.auraType = select(15, ...)
                    end
                end
            elseif eventType:match("_ENERGIZE$") then
                -- Track resource gains for better rotation suggestions
                eventData.amount = select(15, ...)
                eventData.powerType = select(16, ...)
            elseif eventType:match("_DRAIN") or eventType:match("_LEECH") then
                -- Track resource drains
                eventData.amount = select(15, ...)
                eventData.powerType = select(16, ...)
                eventData.extraAmount = select(17, ...)
            elseif eventType:match("_INTERRUPT") then
                -- Track interrupts for better cooldown suggestions
                eventData.extraSpellID = select(15, ...)
                eventData.extraSpellName = select(16, ...)
                eventData.extraSchool = select(17, ...)
            elseif eventType:match("_DISPEL") or eventType == "SPELL_STOLEN" then
                -- Track dispels and steals
                eventData.extraSpellID = select(15, ...)
                eventData.extraSpellName = select(16, ...)
                eventData.extraSchool = select(17, ...)
                eventData.auraType = select(18, ...)
            end
        elseif eventType:match("^SWING") then
            -- Swing Events
            if eventType == "SWING_DAMAGE" then
                eventData.amount = select(12, ...)
                eventData.overkill = select(13, ...)
                eventData.school = select(14, ...)
                eventData.resisted = select(15, ...)
                eventData.blocked = select(16, ...)
                eventData.absorbed = select(17, ...)
                eventData.critical = select(18, ...)
                eventData.glancing = select(19, ...)
                eventData.crushing = select(20, ...)
                eventData.isOffHand = select(21, ...)
            elseif eventType == "SWING_MISSED" then
                eventData.missType = select(12, ...)
                eventData.isOffHand = select(13, ...)
                eventData.amountMissed = select(14, ...)
            end
        elseif eventType:match("^ENVIRONMENTAL") then
            -- Environmental damage tracking
            eventData.environmentalType = select(12, ...)
            eventData.amount = select(13, ...)
            eventData.overkill = select(14, ...)
            eventData.school = select(15, ...)
            eventData.resisted = select(16, ...)
            eventData.blocked = select(17, ...)
            eventData.absorbed = select(18, ...)
            eventData.critical = select(19, ...)
            eventData.glancing = select(20, ...)
            eventData.crushing = select(21, ...)
        end
    end
    
    return eventData
end

-- Combat Log Event Processing with Performance Optimizations
local function ProcessCombatLogEvent()
    local eventData = AcquireEventData()
    local timestamp, eventType, hideCaster, sourceGUID, sourceName, sourceFlags, 
          sourceRaidFlags, destGUID, destName, destFlags, destRaidFlags, 
          spellID, spellName, spellSchool, amount, overkill, school, 
          resisted, blocked, absorbed, critical, glancing, crushing = CombatLogGetCurrentEventInfo()
    
    -- Fast path for instant-cast abilities and high-priority events
    if ShouldProcessInstantly(eventType, spellID) or PRECISE_TIMING_EVENTS[eventType] then
        eventData.timestamp = GetHighPrecisionTime()
        eventData.eventType = eventType
        eventData.sourceGUID = sourceGUID
        eventData.sourceName = sourceName
        eventData.destGUID = destGUID
        eventData.destName = destName
        eventData.spellID = spellID
        eventData.spellName = spellName
        eventData.spellSchool = spellSchool
        
        -- Process immediately with zero delay
        AceEvent.events:Fire(eventType, eventData)
        ReleaseEventData(eventData)
        return
    end
    
    -- Fast path for high-priority events
    if PRECISE_TIMING_EVENTS[eventType] then
        eventData.timestamp = GetHighPrecisionTime()
        eventData.eventType = eventType
        eventData.sourceGUID = sourceGUID
        eventData.sourceName = sourceName
        eventData.destGUID = destGUID
        eventData.destName = destName
        eventData.spellID = spellID
        eventData.spellName = spellName
        eventData.spellSchool = spellSchool
        
        -- Enhanced DPS tracking data
        if eventType:match("_DAMAGE$") then
            eventData.amount = amount
            eventData.overkill = overkill
            eventData.school = school
            eventData.resisted = resisted
            eventData.blocked = blocked
            eventData.absorbed = absorbed
            eventData.critical = critical
            eventData.glancing = glancing
            eventData.crushing = crushing
            
            -- Track DPS metrics
            if sourceGUID == UnitGUID("player") then
                local currentTime = GetHighPrecisionTime()
                eventData.dpsTimestamp = currentTime
                eventData.effectiveAmount = (amount or 0) - (overkill or 0)
            end
        end
        
        AceEvent.events:Fire(eventType, eventData)
        ReleaseEventData(eventData)
        return
    end
    
    -- Standard path for normal priority events
    local currentTime = GetTime()
    if BUFFER_EVENTS[eventType] and (currentTime - AceEvent.lastEventTime) < BUFFER_THRESHOLD then
        -- Prepare event data for buffering
        eventData.timestamp = timestamp
        eventData.eventType = eventType
        eventData.sourceGUID = sourceGUID
        eventData.destGUID = destGUID
        eventData.spellID = spellID
        
        -- Try to buffer the event
        if not BufferEvent(eventData) then
            ReleaseEventData(eventData)
        end
        return
    end
    
    -- Process event immediately
    eventData.timestamp = timestamp
    eventData.eventType = eventType
    eventData.hideCaster = hideCaster
    eventData.sourceGUID = sourceGUID
    eventData.sourceName = sourceName
    eventData.sourceFlags = sourceFlags
    eventData.sourceRaidFlags = sourceRaidFlags
    eventData.destGUID = destGUID
    eventData.destName = destName
    eventData.destFlags = destFlags
    eventData.destRaidFlags = destRaidFlags
    eventData.spellID = spellID
    eventData.spellName = spellName
    eventData.spellSchool = spellSchool
    
    if amount then
        eventData.amount = amount
        eventData.overkill = overkill
        eventData.school = school
        eventData.resisted = resisted
        eventData.blocked = blocked
        eventData.absorbed = absorbed
        eventData.critical = critical
        eventData.glancing = glancing
        eventData.crushing = crushing
    end
    
    AceEvent.lastEventTime = currentTime
    AceEvent.events:Fire(eventType, eventData)
    ReleaseEventData(eventData)
end

-- Embedding and embed handling with validation
local mixins = {
    "RegisterEvent", "UnregisterEvent",
    "RegisterMessage", "UnregisterMessage",
    "SendMessage",
    "UnregisterAllEvents", "UnregisterAllMessages",
}

-- Embeds AceEvent into the target object with type checking
function AceEvent:Embed(target)
    if type(target) ~= "table" then
        error(("Bad argument #1 to `Embed` (table expected, got %s)"):format(type(target)), 2)
    end
    
    for k, v in pairs(mixins) do
        target[v] = self[v]
    end
    self.embeds[target] = true
    return target
end

-- Enhanced cleanup handling with optimized memory management
function AceEvent:OnEmbedDisable(target)
    if not self.embeds[target] then return end
    
    -- Store metrics before cleanup
    if self.eventData then
        for eventname, data in pairs(self.eventData) do
            if data.processCount > 0 then
                if not self.performanceHistory then self.performanceHistory = {} end
                if not self.performanceHistory[eventname] then
                    self.performanceHistory[eventname] = {
                        totalProcessTime = 0,
                        processCount = 0,
                        averageProcessTime = 0,
                        lastUnregistered = GetTime()
                    }
                end
                local history = self.performanceHistory[eventname]
                history.totalProcessTime = history.totalProcessTime + (data.averageProcessTime * data.processCount)
                history.processCount = history.processCount + data.processCount
                history.averageProcessTime = history.totalProcessTime / history.processCount
                history.lastUnregistered = GetTime()
            end
        end
    end
    
    target:UnregisterAllEvents()
    target:UnregisterAllMessages()
    
    if self.events and self.events.callbacks and not next(self.events.callbacks) then
        -- Cleanup all buffered events
        for i = 1, #self.eventBuffer do
            ReleaseEventData(self.eventBuffer[i])
            self.eventBuffer[i] = nil
        end
        wipe(self.eventBuffer)
        
        -- Reset all tracking tables
        if self.eventData then wipe(self.eventData) end
        if self.eventOrder then wipe(self.eventOrder) end
        if self.preciseEvents then wipe(self.preciseEvents) end
        
        -- Reset combat log optimizations
        if self.combatLogInitialized then
            self.combatLogInitialized = false
            wipe(eventPool)
            poolSize = 0
        end
        
        -- Final memory cleanup
        CheckMemoryUsage()
    end
end

--[[ Script Handler System
The script handler system manages various WoW script events with optimized handling
for different event types. It includes special handling for combat log events,
combat text updates, and empowered spell events.

Features:
- Optimized combat log processing
- Smart event buffering
- Memory-efficient event handling
- Performance tracking
--]]

--- Enhanced script handlers with type safety and performance optimization
---@type table<string, function>
local scriptHandlers = {
    --- Handles cleanup when the player logs out
    -- @note Ensures proper cleanup of all event data and memory pools
    PLAYER_LOGOUT = function()
        -- Cleanup all event data
        for i = 1, #AceEvent.eventBuffer do
            ReleaseEventData(AceEvent.eventBuffer[i])
            AceEvent.eventBuffer[i] = nil
        end
        wipe(AceEvent.eventBuffer)
        wipe(eventPool)
    end,
    
    --- Processes combat log events with optimized handling
    -- @note Uses fast path for high-priority events
    COMBAT_LOG_EVENT_UNFILTERED = ProcessCombatLogEvent,

    --- Handles combat text updates with priority-based processing
    -- @param event string The event name
    -- @param type string The combat text type
    -- @param ... any Additional event-specific parameters
    COMBAT_TEXT_UPDATE = function(event, type, ...)
        if not PRECISE_TIMING_EVENTS[type] then return end
        
        local currentTime = GetHighPrecisionTime()
        local eventData = AcquireEventData()
        
        eventData.type = type
        eventData.timestamp = currentTime
        
        -- Process different types of combat text events
        if type == "SPELL_ACTIVE" then
            eventData.spellID = ...
        elseif type == "SPELL_CAST" then
            eventData.spellName = ...
        elseif type == "SPELL_CAST_START" or type == "SPELL_CAST_SUCCESS" or type == "SPELL_CAST_FAILED" then
            eventData.spellName, eventData.lineID = ...
        elseif type == "SPELL_DAMAGE" or type == "SPELL_HEAL" then
            eventData.amount, eventData.critical = ...
            if eventData.critical then
                eventData.timestamp_precise = true -- Mark for precise timing tracking
            end
        end
        
        -- Process high-priority combat text immediately
        if eventData.timestamp_precise then
            AceEvent.events:Fire(type, eventData)
            ReleaseEventData(eventData)
        else
            -- Buffer non-critical events
            if #AceEvent.eventBuffer < MAX_BUFFER_SIZE then
                AceEvent.eventBuffer[#AceEvent.eventBuffer + 1] = eventData
            else
                ReleaseEventData(eventData)
            end
        end
    end,
    
    --- Handles the start of an empowered spell cast
    -- @param unit string The unit casting the spell
    UNIT_SPELLCAST_EMPOWER_START = function(unit)
        if unit == "player" then
            AceEvent.events:Fire("UNIT_SPELLCAST_EMPOWER_START", unit)
        end
    end,
    
    --- Handles the end of an empowered spell cast
    -- @param unit string The unit casting the spell
    UNIT_SPELLCAST_EMPOWER_STOP = function(unit)
        if unit == "player" then
            AceEvent.events:Fire("UNIT_SPELLCAST_EMPOWER_STOP", unit)
        end
    end,
    
    --- Handles updates to an empowered spell cast
    -- @param unit string The unit casting the spell
    UNIT_SPELLCAST_EMPOWER_UPDATE = function(unit)
        if unit == "player" then
            AceEvent.events:Fire("UNIT_SPELLCAST_EMPOWER_UPDATE", unit)
        end
    end
}

-- Enhanced main event handler with performance tracking
local function MainEventHandler(frame, event, ...)
    local startTime = GetHighPrecisionTime()
    
    local handler = scriptHandlers[event]
    if handler then
        handler(event, ...)
    else
        AceEvent.events:Fire(event, ...)
    end
    
    -- Update event performance metrics
    if AceEvent.eventData and AceEvent.eventData[event] then
        local data = AceEvent.eventData[event]
        local processTime = GetHighPrecisionTime() - startTime
        data.processCount = data.processCount + 1
        data.averageProcessTime = (data.averageProcessTime * (data.processCount - 1) + processTime) / data.processCount
        data.lastFired = startTime
    end
end

-- Set up the frame with optimized event handling
AceEvent.frame:SetScript("OnEvent", MainEventHandler)

-- Register core events with order preservation
for event in pairs(scriptHandlers) do
    if not AceEvent.eventOrder then AceEvent.eventOrder = {} end
    if not AceEvent.eventOrder[event] then
        AceEvent.eventOrder[event] = #AceEvent.eventOrder + 1
    end
    AceEvent.frame:RegisterEvent(event)
end

-- Upgrade existing embeds
for target, v in pairs(AceEvent.embeds) do
    AceEvent:Embed(target)
end

--[[ Memory Management and Event Buffering System
This system provides optimized memory handling for combat events in World of Warcraft.
It uses a pool-based approach to reduce garbage collection pressure and provides efficient
event buffering for high-frequency combat situations.

Key Features:
- Pre-allocated event pools to reduce memory churn
- Smart buffer sizing for combat event spikes
- Adaptive memory management based on system resources
- Optimized garbage collection timing
- High-performance event processing for modern systems

@website https://warcraft.wiki.gg/wiki/COMBAT_LOG_EVENT
@see https://warcraft.wiki.gg/wiki/API_C_Timer.After
@see https://warcraft.wiki.gg/wiki/API_GetTime
--]]

-- Import WoW API functions for memory management
---@type fun(): nil
local UpdateAddOnMemoryUsage = UpdateAddOnMemoryUsage
---@type fun(addonName: string): number
local GetAddOnMemoryUsage = GetAddOnMemoryUsage
---@type fun(): number
local gcinfo = gcinfo
---@type fun(opt: string, arg?: number): number|nil
local collectgarbage = collectgarbage

--[[ Core Memory Tables
Initialize the primary data structures used for event handling and empowerment tracking.
These tables are preserved across addon reloads but reinitialized if nil.
--]]
AceEvent.eventPool = AceEvent.eventPool or {}
local eventPool = AceEvent.eventPool

--[[ Empowerment State Tracking
Maintains the state of empowered spells with precise timing information.
This structure tracks:
- Current empowerment state
- Spell being empowered
- Timing information for stages
- Maximum stages available
- Hold duration at maximum charge
@table empowerment
--]]
AceEvent.empowerment = AceEvent.empowerment or {
    active = false,          -- Whether an empowerment is currently active
    spell = nil,            -- SpellID of the current empowerment
    start = 0,              -- Standard timestamp of empowerment start
    preciseStart = 0,       -- High-precision timestamp for accurate duration calculation
    finish = 0,             -- When the empowerment will complete naturally
    hold = 0,              -- How long the empowerment can be held at max stages
    currentStage = 0,       -- Current stage of empowerment (0-based)
    maxStages = 0,         -- Maximum stages available for this empowerment
    stages = {},           -- Table of stage completion times
    lastUpdate = 0         -- Last time the empowerment state was updated
}

--[[ Memory Pool Configuration
These constants define the behavior of the memory pool system.
Values are tuned for high-performance systems with 32GB+ RAM.
--]]
local poolSize = 0                              -- Current size of the event pool
local MAX_POOL_SIZE = 4000                      -- Maximum number of pooled events (4000 for 32GB+ RAM)
local POOL_GROWTH_THRESHOLD = 0.8               -- Grow pool when 80% utilized
local BUFFER_THRESHOLD = 0.1                    -- Buffer events within 100ms window
local MAX_BUFFER_SIZE = 400                     -- Maximum buffered events (400 for high-performance)
local GC_INTERVAL = 300                         -- Force GC every 5 minutes if needed
local MEMORY_THRESHOLD = 1024 * 1024 * 100      -- 100MB threshold for forced GC

--[[ Initial Pool Allocation
Pre-allocate a significant pool of event objects to reduce initial memory churn.
This improves performance during the first few seconds of combat when many
events may occur simultaneously.
@note: 200 initial objects for high-end systems
--]]
for i = 1, 200 do
    eventPool[{}] = true
    poolSize = poolSize + 1
end

--[[ Event Data Management Functions
These functions handle the acquisition and release of event data objects.
They implement a pool-based memory management system to reduce garbage collection.
--]]

--- Acquires an event data object from the pool or creates a new one.
-- Implements smart pool growth when running low on objects.
-- @return table A clean event data object
-- @note Grows pool by up to 200 objects when below 50% capacity
local function AcquireEventData()
    -- Try to get an object from the pool first
    local data = next(eventPool)
    if data then
        eventPool[data] = nil
        poolSize = poolSize - 1
        return data
    end
    
    -- If pool is running low, grow it proactively
    if poolSize < MAX_POOL_SIZE / 2 then
        local growth = math.min(200, MAX_POOL_SIZE - poolSize)
        for i = 1, growth do
            eventPool[{}] = true
            poolSize = poolSize + 1
        end
        -- Try again with newly allocated pool
        data = next(eventPool)
        if data then
            eventPool[data] = nil
            poolSize = poolSize - 1
            return data
        end
    end
    
    -- Fall back to creating a new object if pool is depleted
    return {}
end

--- Releases an event data object back to the pool.
-- Implements pool size management and garbage collection.
-- @param data table The event data object to release
-- @note Objects are released to GC if pool is full
local function ReleaseEventData(data)
    -- Validate input
    if type(data) ~= "table" then return end
    
    -- Let GC handle it if pool is too large
    if poolSize > MAX_POOL_SIZE then
        data = nil
        return
    end
    
    -- Clean and return to pool
    wipe(data)
    eventPool[data] = true
    poolSize = poolSize + 1
end
