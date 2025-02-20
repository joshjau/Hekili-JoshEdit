--[[
CallbackHandler-1.0
------------------
A library for managing callbacks and events in World of Warcraft addons.

Features:
- Efficient event dispatching with safety limits
- Memory-optimized callback storage
- Automatic garbage collection through weak references
- Protected callback execution with error handling
- Queue system for managing callback registration during event processing

Example Usage:
    local CH = LibStub("CallbackHandler-1.0")
    local myObject = {}
    local callbacks = CH:New(myObject)
    
    -- Register a callback
    myObject:RegisterCallback("MyEvent", function(event, ...) print("Event fired!", ...) end)
    
    -- Fire an event
    callbacks:Fire("MyEvent", "arg1", "arg2")

Author: Nevcairiel, Hekili Contributors
Version: $Id: CallbackHandler-1.0.lua 26 2022-12-12 15:09:39Z nevcairiel $
--]]

local MAJOR, MINOR = "CallbackHandler-1.0", 8
local CallbackHandler = LibStub:NewLibrary(MAJOR, MINOR)

if not CallbackHandler then return end -- No upgrade needed

-- Metatable optimization - use direct table for better performance
-- Uses weak keys to allow proper garbage collection of callback objects
local meta = {
	__index = function(tbl, key)
		local newTable = setmetatable({}, { __mode = "k" }) -- weak keys for better garbage collection
		tbl[key] = newTable
		return newTable
	end
}

-- Lua APIs - localized for performance
local pcall, error = pcall, error
local setmetatable, rawget, rawset = setmetatable, rawget, rawset
local next, select, pairs, type, tostring = next, select, pairs, type, tostring
local tinsert, tremove, wipe = table.insert, table.remove, table.wipe
local format = string.format

-- Constants for safety limits
-- These values are tuned for WoW addon environment and common usage patterns
local MAX_HANDLERS = 200 -- Maximum number of handlers per event to prevent table overflow
local MAX_RECURSION = 100 -- Maximum recursion depth to prevent stack overflow

-- Common error messages - upvalued for memory efficiency and consistent messaging
local ERR_BAD_SELF = "bad 'self'"
local ERR_EVENTNAME_TYPE = "'eventname' - string expected"
local ERR_METHOD_TYPE = "'methodname' - string or function expected"
local ERR_SELF_TYPE = "'self or addonId': table or string or thread expected"

--[[
    Dispatches an event to all registered handlers
    
    @param handlers (table) Table of event handlers to call
    @param eventname (string) Name of the event being fired
    @param ... (any) Additional arguments to pass to handlers
    
    Notes:
    - Implements handler count limits to prevent table overflow
    - Uses pcall for protected execution of handlers
    - Reports errors through Hekili's error system if available
--]]
local function Dispatch(handlers, eventname, ...)
	if not handlers then return end
	
	local index, method = next(handlers)
	if not method then return end

	local handlerCount = 0
	repeat
		handlerCount = handlerCount + 1
		if handlerCount > MAX_HANDLERS then
			if _G.Hekili then
				_G.Hekili:Error("CallbackHandler: Too many handlers (%d) for event %s", handlerCount, eventname or "unknown")
			end
			break
		end

		-- Protected call to prevent errors in handlers from breaking event dispatch
		local success, err = pcall(method, eventname, ...)
		
		-- Error reporting through Hekili's system if available
		if not success and _G.Hekili then
			_G.Hekili:Error("CallbackHandler: %s in event %s", err or "unknown error", eventname or "unknown")
		end
		
		index, method = next(handlers, index)
	until not method
end

--------------------------------------------------------------------------
-- CallbackHandler:New
--
--   target            - target object to embed public APIs in
--   RegisterName      - name of the callback registration API, default "RegisterCallback"
--   UnregisterName    - name of the callback unregistration API, default "UnregisterCallback"
--   UnregisterAllName - name of the API to unregister all callbacks, default "UnregisterAllCallbacks". false == don't publish this API.

function CallbackHandler.New(_self, target, RegisterName, UnregisterName, UnregisterAllName)
	RegisterName = RegisterName or "RegisterCallback"
	UnregisterName = UnregisterName or "UnregisterCallback"
	if UnregisterAllName == nil then
		UnregisterAllName = "UnregisterAllCallbacks"
	end

	-- Create the registry object with optimized table initialization
	local events = setmetatable({}, meta)
	local registry = { recurse = 0, events = events }

	--[[
		Fires an event to all registered handlers
		
		@param eventname (string) Name of the event to fire
		@param ... (any) Arguments to pass to handlers
		
		Features:
		- Recursion protection
		- Queued callback processing
		- Automatic cleanup of processed queues
		- OnUsed/OnUnused callback support
	--]]
	function registry:Fire(eventname, ...)
		local eventTable = rawget(events, eventname)
		if not eventTable or not next(eventTable) then return end
		
		local oldrecurse = registry.recurse
		registry.recurse = oldrecurse + 1

		-- Prevent infinite recursion
		if registry.recurse > MAX_RECURSION then
			if _G.Hekili then
				_G.Hekili:Error("CallbackHandler: Maximum recursion depth (%d) exceeded for event %s", MAX_RECURSION, eventname)
			end
			registry.recurse = oldrecurse
			return
		end

		Dispatch(eventTable, eventname, ...)

		registry.recurse = oldrecurse

		-- Process queued callbacks when we're back at the root level
		if registry.insertQueue and oldrecurse == 0 then
			local insertQueue = registry.insertQueue
			registry.insertQueue = nil -- Clear before processing to prevent recursion issues
			
			for event, callbacks in pairs(insertQueue) do
				local first = not rawget(events, event) or not next(events[event])
				local eventTable = events[event]
				
				-- Process and cleanup queued callbacks
				for object, func in pairs(callbacks) do
					rawset(eventTable, object, func)
					callbacks[object] = nil -- Clean up as we go
					
					if first then
						if registry.OnUsed then
							registry.OnUsed(registry, target, event)
						end
						first = false
					end
				end
			end
		end
	end

	--[[
		Registers a callback for an event
		
		@param self (table|string|thread) The object or addon registering the callback
		@param eventname (string) The event to register for
		@param method (string|function) The method or function to call
		@param ... (any) Optional argument to pass to the callback
		
		Features:
		- Fast path for simple function callbacks
		- Optimized closure creation
		- Queue system for registration during event processing
		- Automatic OnUsed callback handling
	--]]
	target[RegisterName] = function(self, eventname, method, ... --[[actually just a single arg]])
		if type(eventname) ~= "string" then
			error(format("Usage: %s(eventname, method[, arg]): %s", RegisterName, ERR_EVENTNAME_TYPE), 2)
		end

		method = method or eventname

		-- Fast path for function callbacks (most common case)
		if type(method) == "function" and select("#", ...) == 0 then
			local eventTable = events[eventname]
			local isNew = not rawget(events, eventname) or not next(eventTable)
			rawset(eventTable, self, method)
			
			-- Only check OnUsed if necessary
			if isNew and registry.OnUsed then
				registry.OnUsed(registry, target, eventname)
			end
			return
		end

		-- Validate method type
		if type(method) ~= "string" and type(method) ~= "function" then
			error(format("Usage: %s(\"eventname\", \"methodname\"): %s", RegisterName, ERR_METHOD_TYPE), 2)
		end

		local regfunc
		if type(method) == "string" then
			-- Validate self for string methods
			if type(self) ~= "table" then
				error(format("Usage: %s(\"eventname\", \"methodname\"): self was not a table", RegisterName), 2)
			elseif self == target then
				error(format("Usage: %s(\"eventname\", \"methodname\"): do not use Library:%s(), use your own 'self'", RegisterName, RegisterName), 2)
			elseif type(self[method]) ~= "function" then
				error(format("Usage: %s(\"eventname\", \"methodname\"): method '%s' not found on self.", RegisterName, tostring(method)), 2)
			end

			-- Optimize closure creation
			local arg = select(1, ...)
			if arg ~= nil then
				regfunc = function(...) self[method](self, arg, ...) end
			else
				regfunc = self[method]
			end
		else
			-- Validate self type for function refs
			if type(self) ~= "table" and type(self) ~= "string" and type(self) ~= "thread" then
				error(format("Usage: %s(self or \"addonId\", eventname, method): %s", RegisterName, ERR_SELF_TYPE), 2)
			end

			-- Optimize closure creation for function refs
			local arg = select(1, ...)
			if arg ~= nil then
				regfunc = function(...) method(arg, ...) end
			else
				regfunc = method
			end
		end

		-- Optimized callback storage
		local eventTable = events[eventname]
		if eventTable[self] or registry.recurse < 1 then
			local isNew = not rawget(events, eventname) or not next(eventTable)
			rawset(eventTable, self, regfunc)
			
			-- Only check OnUsed for new registrations
			if isNew and registry.OnUsed then
				registry.OnUsed(registry, target, eventname)
			end
		else
			-- Queue system with optimized table handling
			if not registry.insertQueue then
				registry.insertQueue = setmetatable({}, meta)
			end
			rawset(registry.insertQueue[eventname], self, regfunc)
		end
	end

	--[[
		Unregisters a callback for an event
		
		@param self (table|string|thread) The object or addon unregistering the callback
		@param eventname (string) The event to unregister from
		
		Features:
		- Automatic cleanup of empty event tables
		- OnUnused callback support
		- Cleanup of queued callbacks
	--]]
	target[UnregisterName] = function(self, eventname)
		if not self or self == target then
			error(format("Usage: %s(eventname): %s", UnregisterName, ERR_BAD_SELF), 2)
		end
		if type(eventname) ~= "string" then
			error(format("Usage: %s(eventname): %s", UnregisterName, ERR_EVENTNAME_TYPE), 2)
		end

		local eventTable = rawget(events, eventname)
		if eventTable and eventTable[self] then
			eventTable[self] = nil
			
			-- Only check OnUnused if the event table is empty
			if registry.OnUnused and not next(eventTable) then
				registry.OnUnused(registry, target, eventname)
			end
		end

		-- Clean up queued callbacks if necessary
		if registry.insertQueue then
			local queueTable = rawget(registry.insertQueue, eventname)
			if queueTable and queueTable[self] then
				queueTable[self] = nil
			end
		end
	end

	--[[
		Unregisters all callbacks for one or more objects/addons
		
		@param ... (table|string|thread) The objects or addons to unregister
		
		Features:
		- Bulk unregistration for cleanup
		- Automatic event table cleanup
		- OnUnused callback support
	--]]
	if UnregisterAllName then
		target[UnregisterAllName] = function(...)
			if select("#", ...) < 1 then
				error(format("Usage: %s([whatFor]): missing 'self' or \"addonId\" to unregister events for.", UnregisterAllName), 2)
			end

			for i = 1, select("#", ...) do
				local self = select(i, ...)
				
				-- Clean up queued callbacks
				if registry.insertQueue then
					for eventname, callbacks in pairs(registry.insertQueue) do
						callbacks[self] = nil
					end
				end
				
				-- Clean up registered callbacks
				for eventname, callbacks in pairs(events) do
					if callbacks[self] then
						callbacks[self] = nil
						-- Check OnUnused only when needed
						if registry.OnUnused and not next(callbacks) then
							registry.OnUnused(registry, target, eventname)
						end
					end
				end
			end
		end
	end

	return registry
end

-- CallbackHandler purposefully does NOT do explicit embedding. Nor does it
-- try to upgrade old implicit embeds since the system is selfcontained and
-- relies on closures to work.

