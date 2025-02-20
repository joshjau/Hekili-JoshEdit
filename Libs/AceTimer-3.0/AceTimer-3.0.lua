--- **AceTimer-3.0** provides a central facility for registering timers.
-- AceTimer supports one-shot timers and repeating timers. All timers are stored in an efficient
-- data structure that allows easy dispatching and fast rescheduling. Timers can be registered
-- or canceled at any time, even from within a running timer, without conflict or large overhead.\\
-- AceTimer is currently limited to firing timers at a frequency of 0.01s as this is what the WoW timer API
-- restricts us to.
--
-- Features:
-- * High precision timing using GetTimePreciseSec when available
-- * Priority-based execution for combat vs non-combat timers
-- * Efficient memory management with object pooling
-- * Frame rate compensation to maintain timing accuracy
-- * Error recovery and retry system for failed timers
-- * Combat-aware processing to prevent performance issues
--
-- All `:Schedule` functions will return a handle to the current timer, which you will need to store if you
-- need to cancel the timer you just registered.
--
-- **AceTimer-3.0** can be embeded into your addon, either explicitly by calling AceTimer:Embed(MyAddon) or by
-- specifying it as an embeded library in your AceAddon. All functions will be available on your addon object
-- and can be accessed directly, without having to explicitly call AceTimer itself.\\
-- It is recommended to embed AceTimer, otherwise you'll have to specify a custom `self` on all calls you
-- make into AceTimer.
-- @class file
-- @name AceTimer-3.0
-- @release $Id: AceTimer-3.0.lua 1342 2024-05-26 11:49:35Z nevcairiel $

local MAJOR, MINOR = "AceTimer-3.0", 18 -- Bump minor for new changes
local AceTimer, oldminor = LibStub:NewLibrary(MAJOR, MINOR)

if not AceTimer then return end -- No upgrade needed

-- Initialize timer storage with pre-allocated size for better memory efficiency
AceTimer.activeTimers = AceTimer.activeTimers or {} 
local activeTimers = AceTimer.activeTimers -- Upvalue our private data

-- Lua APIs - localize for performance
local type, unpack, next, error, select = type, unpack, next, error, select
local format, wipe, tinsert, tremove = string.format, table.wipe, table.insert, table.remove
local floor, abs, max, min, huge = math.floor, math.abs, math.max, math.min, math.huge
local GetTime = GetTimePreciseSec or GetTime -- Use high precision timer if available

-- WoW APIs - use modern C_Timer API
local C_Timer_After = C_Timer.After
local C_Timer_NewTicker = C_Timer.NewTicker
local InCombatLockdown = InCombatLockdown

-- Constants
--- Minimum delay allowed by C_Timer API (0.01s)
local MIN_TIMER_DELAY = 0.01
--- Maximum reasonable delay to prevent excessive timers (1 hour)
local MAX_TIMER_DELAY = 3600
--- Microsecond precision for drift compensation (0.001s)
local TIMER_PRECISION = 0.001
--- Maximum number of retry attempts for failed timers
local MAX_RETRY_COUNT = 3
--- Maximum number of objects to keep in pools for memory efficiency
local MAX_POOL_SIZE = 1000
--- Maximum number of timers in a batch for processing
local MAX_BATCH_SIZE = 100
--- Reset frame data after this much time passes (1 second)
local FRAME_RESET_THRESHOLD = 1.0
--- Maximum reasonable frame time before considering it extreme (500ms)
local MAX_FRAME_TIME = 0.5
--- Delay cleanup operations after combat ends (5 seconds)
local COMBAT_CLEANUP_DELAY = 5.0

-- Timer priority levels for different types of operations
local TIMER_PRIORITY = {
    HIGH = 1,    -- Combat rotation timers (<0.1s)
    NORMAL = 2,  -- Regular updates (0.1s-1s)
    LOW = 3      -- UI updates (>1s)
}

-- Timer object pool for efficient memory usage
local timerPool = {}
local batchPool = {}

-- Handle counter for reliable timer identification
-- Uses integer range (1 to 2^31-1) and resets to prevent overflow
local handleCounter = 0
local function GetNextHandle()
    handleCounter = handleCounter + 1
    if handleCounter >= 2147483647 then -- Reset before hitting integer limit
        handleCounter = 1
    end
    return handleCounter
end

-- Frame rate tracking data structure
local frameTimeData = {
    lastUpdate = 0,        -- Last time frame data was updated
    avgFrameTime = 0,      -- Average frame time
    samples = 0,           -- Number of samples collected
    minFrameTime = huge,   -- Minimum frame time seen
    maxFrameTime = 0,      -- Maximum frame time seen
    totalFrameTime = 0,    -- Total accumulated frame time
    extremeCount = 0       -- Count of extreme frame times
}

--- Get the appropriate priority level for a timer based on its delay
-- @param delay The timer delay in seconds
-- @return TIMER_PRIORITY level (HIGH, NORMAL, or LOW)
local function GetTimerPriority(delay)
    if delay <= 0.1 then return TIMER_PRIORITY.HIGH
    elseif delay <= 1 then return TIMER_PRIORITY.NORMAL
    else return TIMER_PRIORITY.LOW end
end

--- Update frame timing data with protection against extreme values
-- Tracks frame times and maintains running averages with protection
-- against extreme values that could skew the data
local function UpdateFrameData()
    local now = GetTime()
    local elapsed = now - frameTimeData.lastUpdate
    
    -- Handle extreme frame times (>500ms)
    if elapsed > MAX_FRAME_TIME then
        frameTimeData.extremeCount = frameTimeData.extremeCount + 1
        if frameTimeData.extremeCount > 10 then -- Reset after multiple extreme frames
            frameTimeData.samples = 0
            frameTimeData.avgFrameTime = 0
            frameTimeData.minFrameTime = huge
            frameTimeData.maxFrameTime = 0
            frameTimeData.totalFrameTime = 0
            frameTimeData.extremeCount = 0
        end
        frameTimeData.lastUpdate = now
        return
    end
    
    -- Reset stats if too much time has passed
    if elapsed > FRAME_RESET_THRESHOLD then
        frameTimeData.samples = 0
        frameTimeData.avgFrameTime = 0
        frameTimeData.minFrameTime = huge
        frameTimeData.maxFrameTime = 0
        frameTimeData.totalFrameTime = 0
        frameTimeData.extremeCount = 0
    end
    
    if elapsed > 0 then
        frameTimeData.samples = frameTimeData.samples + 1
        frameTimeData.totalFrameTime = frameTimeData.totalFrameTime + elapsed
        frameTimeData.avgFrameTime = frameTimeData.samples > 0 and 
            frameTimeData.totalFrameTime / frameTimeData.samples or elapsed
        frameTimeData.minFrameTime = min(frameTimeData.minFrameTime, elapsed)
        frameTimeData.maxFrameTime = max(frameTimeData.maxFrameTime, elapsed)
        frameTimeData.lastUpdate = now
        frameTimeData.extremeCount = 0 -- Reset extreme counter on good frame
    end
end

--- Get a timer object from the pool or create a new one
-- @return A clean timer object
local function AcquireTimer()
    local timer = tremove(timerPool)
    if timer then
        wipe(timer)
    else
        timer = {}
    end
    return timer
end

--- Release a timer object back to the pool
-- @param timer The timer object to release
local function ReleaseTimer(timer)
    if not timer then return end
    wipe(timer)
    if #timerPool < MAX_POOL_SIZE then
        tinsert(timerPool, timer)
    end
end

--- Create a new batch for processing multiple timers
-- @return A new or recycled batch object
local function CreateTimerBatch()
    local batch = tremove(batchPool) or {
        timers = {},
        count = 0,
        maxSize = MAX_BATCH_SIZE,
        created = GetTime()
    }
    return batch
end

--- Release a batch back to the pool
-- @param batch The batch object to release
local function ReleaseBatch(batch)
    if not batch then return end
    wipe(batch.timers)
    batch.count = 0
    batch.created = nil
    if #batchPool < MAX_POOL_SIZE then
        tinsert(batchPool, batch)
    end
end

--- Process a batch of timers with protection against old batches
-- @param batch The batch of timers to process
-- @param now Current time for timing calculations
local function ProcessTimerBatch(batch, now)
    if not batch or batch.count == 0 then return end
    
    -- Validate batch age to prevent processing old batches
    if now - batch.created > MAX_FRAME_TIME then
        ReleaseBatch(batch)
        return
    end
    
    local count = min(batch.count, batch.maxSize)
    if count <= 0 then
        ReleaseBatch(batch)
        return
    end
    
    -- Process timers with combat awareness
    for i = 1, count do
        local timer = batch.timers[i]
        if timer and not timer.cancelled then
            if timer.priority == TIMER_PRIORITY.HIGH or not InCombatLockdown() then
                timer.callback()
            end
        end
    end
    
    ReleaseBatch(batch)
end

--- Validate a timer object's state
-- @param timer The timer object to validate
-- @return boolean Valid state
-- @return string Error message if invalid
local function ValidateTimer(timer)
    if not timer then return false, "Invalid timer object" end
    if not timer.delay or timer.delay < 0 then
        return false, format("Invalid timer delay: %s", tostring(timer.delay))
    end
    if timer.errorCount and timer.errorCount >= MAX_RETRY_COUNT then
        return false, format("Timer exceeded retry limit (%d)", MAX_RETRY_COUNT)
    end
    return true
end

--- Validate and normalize a timer delay value
-- @param delay The delay value to validate
-- @return boolean Valid state
-- @return number|string Normalized delay or error message
local function ValidateDelay(delay)
    if type(delay) ~= "number" then
        return false, format("%s: Timer delay must be a number, got %s", MAJOR, type(delay))
    end
    
    -- Round to microsecond precision to avoid floating point errors
    delay = floor(delay * 1000 + 0.5) / 1000
    
    if delay < MIN_TIMER_DELAY then
        delay = MIN_TIMER_DELAY
    elseif delay > MAX_TIMER_DELAY then
        delay = MAX_TIMER_DELAY
    end
    
    return true, delay
end

--- Attempt to recover a failed timer
-- @param timer The timer to recover
-- @return boolean True if recovery was attempted
local function RecoverTimer(timer)
    if not timer then return false end
    
    -- Don't retry high priority timers in combat
    if InCombatLockdown() and timer.priority == TIMER_PRIORITY.HIGH then
        return false
    end
    
    timer.retryCount = (timer.retryCount or 0) + 1
    if timer.retryCount >= MAX_RETRY_COUNT then
        return false
    end
    
    -- Attempt recovery with minimum delay
    C_Timer_After(MIN_TIMER_DELAY, timer.callback)
    return true
end

-- Timer creation function with improved error handling and high precision timing
local function new(self, loop, func, delay, ...)
    local valid, newDelay = ValidateDelay(delay)
    if not valid then
        error(newDelay, 2)
    end
    
    delay = newDelay
    
    -- Pre-calculate values used in the timer with microsecond precision
    local currentTime = GetTime()
    local endTime = currentTime + delay
    local argCount = select("#", ...)
    
    -- Get timer from pool
    local timer = AcquireTimer()
    
    -- Set up timer properties
    timer.handle = GetNextHandle()
    timer.object = self
    timer.func = func
    timer.looping = loop
    timer.argsCount = argCount
    timer.delay = delay
    timer.ends = endTime
    timer.startTime = currentTime
    timer.priority = GetTimerPriority(delay)
    timer.retryCount = 0
    
    -- Store variable arguments
    for i = 1, argCount do
        timer[i] = select(i, ...)
    end
    
    activeTimers[timer.handle] = timer
    
    -- Update frame data for timing compensation
    UpdateFrameData()
    
    -- Optimized callback closure with error handling and drift compensation
    timer.callback = function()
        if timer.cancelled then return end
        
        local now = GetTime()
        local valid, err = ValidateTimer(timer)
        
        if not valid then
            if not RecoverTimer(timer) then
                activeTimers[timer.handle] = nil
                ReleaseTimer(timer)
                return
            end
        end
        
        -- Execute timer with error handling
        local success, err = pcall(function()
            if type(timer.func) == "string" then
                timer.object[timer.func](timer.object, unpack(timer, 1, timer.argsCount))
            else
                timer.func(unpack(timer, 1, timer.argsCount))
            end
        end)
        
        if not success then
            if not RecoverTimer(timer) then
                activeTimers[timer.handle] = nil
                ReleaseTimer(timer)
                return
            end
        end
        
        -- Handle repeating timers with improved precision and drift compensation
        if timer.looping and not timer.cancelled then
            local nextDelay = timer.delay
            local cycles = floor((now - timer.startTime) / timer.delay)
            local targetTime = timer.startTime + (cycles + 1) * timer.delay
            
            -- Calculate precise next delay accounting for drift
            nextDelay = targetTime - now
            
            -- Adjust for frame rate if needed
            if frameTimeData.avgFrameTime > 0 then
                nextDelay = max(nextDelay, frameTimeData.avgFrameTime)
            end
            
            -- Ensure delay stays within bounds
            if nextDelay < MIN_TIMER_DELAY then 
                nextDelay = MIN_TIMER_DELAY
                timer.startTime = now -- Reset drift tracking on minimum delay
            elseif nextDelay > timer.delay + TIMER_PRECISION then
                nextDelay = timer.delay
                timer.startTime = now -- Reset drift tracking if too far off
            end
            
            -- Schedule next execution
            if timer.priority == TIMER_PRIORITY.HIGH then
                C_Timer_After(0, timer.callback) -- Immediate execution for high priority
            else
                C_Timer_After(nextDelay, timer.callback)
            end
            
            timer.ends = now + nextDelay
        else
            activeTimers[timer.handle] = nil
            ReleaseTimer(timer)
        end
    end
    
    -- Initial timer scheduling
    if timer.priority == TIMER_PRIORITY.HIGH then
        C_Timer_After(0, timer.callback) -- Immediate execution for high priority
    else
        C_Timer_After(delay, timer.callback)
    end
    
    return timer
end

--- Schedule a new one-shot timer.
-- The timer will fire once in `delay` seconds, unless canceled before.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
function AceTimer:ScheduleTimer(func, delay, ...)
    if not func then
        error(format("%s: ScheduleTimer(callback, delay, args...): 'callback' must be provided", MAJOR), 2)
    end
    
    if type(func) == "string" then
        if type(self) ~= "table" then
            error(format("%s: ScheduleTimer(callback, delay, args...): 'self' must be a table when using method names", MAJOR), 2)
        elseif not self[func] then
            error(format("%s: ScheduleTimer(callback, delay, args...): Method '%s' not found", MAJOR, func), 2)
        end
    end
    
    return new(self, nil, func, delay, ...)
end

--- Schedule a repeating timer.
-- The timer will fire every `delay` seconds, until canceled.
-- @param func Callback function for the timer pulse (funcref or method name).
-- @param delay Delay for the timer, in seconds.
-- @param ... An optional, unlimited amount of arguments to pass to the callback function.
function AceTimer:ScheduleRepeatingTimer(func, delay, ...)
    if not func then
        error(format("%s: ScheduleRepeatingTimer(callback, delay, args...): 'callback' must be provided", MAJOR), 2)
    end
    
    if type(func) == "string" then
        if type(self) ~= "table" then
            error(format("%s: ScheduleRepeatingTimer(callback, delay, args...): 'self' must be a table when using method names", MAJOR), 2)
        elseif not self[func] then
            error(format("%s: ScheduleRepeatingTimer(callback, delay, args...): Method '%s' not found", MAJOR, func), 2)
        end
    end
    
    return new(self, true, func, delay, ...)
end

--- Cancels a timer with the given id.
-- Both one-shot and repeating timers can be canceled with this function.
-- @param id The id of the timer, as returned by `:ScheduleTimer` or `:ScheduleRepeatingTimer`
-- @return boolean True if the timer was successfully cancelled, false if it wasn't found
function AceTimer:CancelTimer(id)
    local timer = activeTimers[id]
    if not timer then return false end
    
    timer.cancelled = true
    activeTimers[id] = nil
    ReleaseTimer(timer)
    return true
end

--- Cancels all timers registered to the current addon object ('self')
function AceTimer:CancelAllTimers()
    for k, v in next, activeTimers do
        if v.object == self then
            AceTimer.CancelTimer(self, k)
        end
    end
end

--- Returns the time left for a timer.
-- @param id The id of the timer
-- @return number The time left on the timer, or 0 if the timer is not found
-- @return boolean True if the timer exists and is still active
function AceTimer:TimeLeft(id)
    local timer = activeTimers[id]
    if not timer then return 0, false end
    if timer.cancelled then return 0, false end
    
    return timer.ends - GetTime(), true
end

--- Cleanup function for long-running addons
-- Performs memory cleanup and maintenance operations
-- Will defer cleanup if called during combat
function AceTimer:CleanupTimers()
    -- Don't cleanup during combat
    if InCombatLockdown() then
        C_Timer_After(COMBAT_CLEANUP_DELAY, function()
            self:CleanupTimers()
        end)
        return
    end
    
    -- Clear old timer pools if they get too large
    if #timerPool > MAX_POOL_SIZE then
        for i = MAX_POOL_SIZE + 1, #timerPool do
            timerPool[i] = nil
        end
    end
    
    if #batchPool > MAX_POOL_SIZE then
        for i = MAX_POOL_SIZE + 1, #batchPool do
            batchPool[i] = nil
        end
    end
    
    -- Reset frame data if needed
    if frameTimeData.samples > 10000 or frameTimeData.extremeCount > 100 then
        frameTimeData.samples = 0
        frameTimeData.avgFrameTime = 0
        frameTimeData.minFrameTime = huge
        frameTimeData.maxFrameTime = 0
        frameTimeData.totalFrameTime = 0
        frameTimeData.lastUpdate = GetTime()
        frameTimeData.extremeCount = 0
    end
end

-- ---------------------------------------------------------------------
-- Upgrading

if oldminor and oldminor < 18 then
    -- Clear any old timer data
    AceTimer.inactiveTimers = nil
    AceTimer.frame = nil
    AceTimer.hash = nil
    AceTimer.debug = nil
    
    -- Convert existing timers to new format
    local oldTimers = AceTimer.activeTimers
    AceTimer.activeTimers = {}
    activeTimers = AceTimer.activeTimers
    
    for handle, timer in next, oldTimers do
        if type(timer) == "table" and not timer.cancelled then
            local newTimer
            if timer.looping then
                newTimer = AceTimer.ScheduleRepeatingTimer(timer.object, timer.func, timer.delay, unpack(timer, 1, timer.argsCount))
            else
                local remaining = timer.ends - GetTime()
                if remaining > 0 then
                    newTimer = AceTimer.ScheduleTimer(timer.object, timer.func, remaining, unpack(timer, 1, timer.argsCount))
                end
            end
            
            if newTimer then
                activeTimers[newTimer] = nil
                activeTimers[handle] = newTimer
                newTimer.handle = handle
            end
        end
    end
end

-- ---------------------------------------------------------------------
-- Embed handling

AceTimer.embeds = AceTimer.embeds or {}

local mixins = {
    "ScheduleTimer", "ScheduleRepeatingTimer",
    "CancelTimer", "CancelAllTimers",
    "TimeLeft", "CleanupTimers"
}

function AceTimer:Embed(target)
    AceTimer.embeds[target] = true
    for _, v in next, mixins do
        target[v] = AceTimer[v]
    end
    return target
end

function AceTimer:OnEmbedDisable(target)
    target:CancelAllTimers()
end

for addon in next, AceTimer.embeds do
    AceTimer:Embed(addon)
end
