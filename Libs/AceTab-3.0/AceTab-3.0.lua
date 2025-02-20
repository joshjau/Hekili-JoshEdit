--- AceTab-3.0 provides support for tab-completion.
-- Note: This library is not yet finalized.
-- @class file
-- @name AceTab-3.0
-- @release $Id: AceTab-3.0.lua 1287 2022-09-25 09:15:57Z nevcairiel $

local ACETAB_MAJOR, ACETAB_MINOR = 'AceTab-3.0', 9
local AceTab, oldminor = LibStub:NewLibrary(ACETAB_MAJOR, ACETAB_MINOR)

if not AceTab then return end -- No upgrade needed

-- Type definitions for EditBox extensions
---@class _G
---@field ChatEdit_CustomTabPressed function Function to handle custom tab press behavior

---@class AceTabEditBox : EditBox
---@field hookedByAceTab3 boolean Whether the editbox has been hooked by AceTab
---@field at3curMatch number Current match index in the cycle
---@field at3matches table<string, table> Table of completion matches by descriptor
---@field at3lastMatch string|nil Last matched completion
---@field at3lastWord string|nil Last matched word
---@field at3origMatch string|nil Original match before cycling
---@field at3origWord string|nil Original word before cycling
---@field at3matchStart number|nil Start position of current match
---@field at3_last_precursor string|nil Last text before cursor

AceTab.registry = AceTab.registry or {}

-- local upvalues
local _G = _G
local pairs = pairs
local ipairs = ipairs
local type = type
local registry = AceTab.registry
local next = next
local select = select
local wipe = wipe
local pcall = pcall

local strfind = string.find
local strsub = string.sub
local strlower = string.lower
local strformat = string.format
local strmatch = string.match

-- Function parameter type definitions
---@alias AceTabWordList fun(candidates: table, text: string, pos: number, word: string)
---@alias AceTabUsageFunc fun(candidates: table, matches: table, substring: string, precursor: string?): string?
---@alias AceTabPostFunc fun(match: string, pos: number, text: string): string

local function printf(...)
	DEFAULT_CHAT_FRAME:AddMessage(strformat(...))
end

---@param this AceTabEditBox
---@param start? number
local function getTextBeforeCursor(this, start)
	return strsub(this:GetText(), start or 1, this:GetCursorPosition())
end

-- Hook management with optimized memory usage and error handling
local hookStore = setmetatable({}, { 
    __mode = "k", -- Weak table to prevent memory leaks
    __index = function(t, k)
        -- Validate frame exists and is an EditBox
        if not k or not k.GetObjectType or k:GetObjectType() ~= "EditBox" then
            return nil
        end
        return rawget(t, k)
    end
})

-- Performance monitoring with detailed stats
local hookStats = {
    calls = 0,
    errors = 0,
    totalTime = 0,
    lastCleanup = GetTime(),
    cleanupInterval = 60, -- Cleanup check every minute
    maxHookAge = 300, -- 5 minutes max hook age
    errorLog = {} -- Track last 10 errors
}

-- Secure hook wrapper with error handling and stats
local function secureHookWrapper(f, hookType, handler)
    return function(self, ...)
        hookStats.calls = hookStats.calls + 1
        local startTime = debugprofilestop()
        
        local success, result = pcall(function(...)
            -- Check frame validity
            if not f:IsObjectType("EditBox") then
                error("Invalid frame type for hook: " .. tostring(f:GetObjectType()))
            end
            
            -- Track hook age and cleanup if needed
            if GetTime() - hookStats.lastCleanup > hookStats.cleanupInterval then
                for frame, data in pairs(hookStore) do
                    if GetTime() - data.startTime > hookStats.maxHookAge and not frame:IsVisible() then
                        if frame:GetScript(hookType) then
                            frame:SetScript(hookType, data.origHandler)
                        end
                        hookStore[frame] = nil
                    end
                end
                hookStats.lastCleanup = GetTime()
            end
            
            local result = handler(self, ...)
            return result
        end, ...)
        
        hookStats.totalTime = hookStats.totalTime + (debugprofilestop() - startTime)
        if not success then
            hookStats.errors = hookStats.errors + 1
            -- Log error with timestamp
            table.insert(hookStats.errorLog, 1, {
                time = GetTime(),
                error = result,
                hookType = hookType
            })
            -- Keep only last 10 errors
            if #hookStats.errorLog > 10 then
                table.remove(hookStats.errorLog)
            end
            return false
        end
        
        return result
    end
end

---@param f AceTabEditBox
local function hookFrame(f)
    if hookStore[f] then return end
    
    -- Store original handlers with validation
    local origTabPressed = f:GetScript('OnTabPressed')
    if type(origTabPressed) ~= 'function' then
        origTabPressed = function() end
    end
    
    hookStore[f] = {
        origTabPressed = origTabPressed,
        startTime = GetTime(),
        handlers = {}
    }
    
    -- Add secure hooks with error handling
	if f == ChatEdit_GetActiveWindow() then
		local origCTP = ChatEdit_CustomTabPressed
        _G.ChatEdit_CustomTabPressed = secureHookWrapper(f, 'OnTabPressed', function(...)
			if AceTab:OnTabPressed(f) then
				return origCTP(...)
			else
				return true
			end
        end)
    else
        f:SetScript('OnTabPressed', secureHookWrapper(f, 'OnTabPressed', function(self, ...)
			if AceTab:OnTabPressed(f) then
                return origTabPressed()
			end
        end))
	end
    
    -- Initialize frame state with pre-allocated table
	f.at3curMatch = 0
	f.at3matches = {}
    f.at3matchStart = 1
    
    -- Add cleanup handler with error recovery
    f:HookScript("OnHide", function()
        if not f:IsShown() and hookStore[f] then
            local age = GetTime() - hookStore[f].startTime
            if age > hookStats.maxHookAge then
                local success = pcall(function()
                    f:SetScript('OnTabPressed', hookStore[f].origTabPressed)
                    for _, handler in pairs(hookStore[f].handlers) do
                        if type(handler.cleanup) == 'function' then
                            handler.cleanup()
                        end
                    end
                    hookStore[f] = nil
                    f.at3matches = nil
                    f.at3curMatch = nil
                    f.at3matchStart = nil
                end)
                if not success then
                    -- Emergency cleanup
                    hookStore[f] = nil
                    f.at3matches = nil
                end
            end
        end
    end)
end

-- Enhanced hook stats reporting
function AceTab:GetHookStats()
    local activeHooks = 0
    local oldestHook = 0
    for _, data in pairs(hookStore) do
        activeHooks = activeHooks + 1
        local age = GetTime() - data.startTime
        if age > oldestHook then
            oldestHook = age
        end
    end
    
    return {
        totalCalls = hookStats.calls,
        errorRate = hookStats.errors / math.max(hookStats.calls, 1),
        averageTime = hookStats.totalTime / math.max(hookStats.calls, 1),
        activeHooks = activeHooks,
        oldestHookAge = oldestHook,
        lastErrors = hookStats.errorLog,
        memoryUsage = collectgarbage("count") -- Track memory usage
    }
end

local fallbacks, notfallbacks = {}, {}  -- classifies completions into those which have preconditions and those which do not.  Those without preconditions are only considered if no other completions have matches.
local pmolengths = {}  -- holds the number of characters to overwrite according to pmoverwrite and the current prematch
-- ------------------------------------------------------------------------------
-- RegisterTabCompletion( descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite )
-- See http://www.wowace.com/wiki/AceTab-2.0 for detailed API documentation
--
-- descriptor	string					Unique identifier for this tab completion set
--
-- prematches	string|table|nil		String match(es) AFTER which this tab completion will apply.
--										AceTab will ignore tabs NOT preceded by the string(s).
--										If no value is passed, will check all tabs pressed in the specified editframe(s) UNLESS a more-specific tab complete applies.
--
-- wordlist		function|table			Function that will be passed a table into which it will insert strings corresponding to all possible completions, or an equivalent table.
--										The text in the editbox, the position of the start of the word to be completed, and the uncompleted partial word
--										are passed as second, third, and fourth arguments, to facilitate pre-filtering or conditional formatting, if desired.
--
-- usagefunc	function|boolean|nil	Usage statement function.  Defaults to the wordlist, one per line.  A boolean true squelches usage output.
--
-- listenframes	string|table|nil		EditFrames to monitor.  Defaults to ChatFrameEditBox.
--
-- postfunc		function|nil			Post-processing function.  If supplied, matches will be passed through this function after they've been identified as a match.
--
-- pmoverwrite	boolean|number|nil		Offset the beginning of the completion string in the editbox when making a completion.  Passing a boolean true indicates that we want to overwrite
--										the entire prematch string, and passing a number will overwrite that many characters prior to the cursor.
--										This is useful when you want to use the prematch as an indicator character, but ultimately do not want it as part of the text, itself.
--
-- no return
-- ------------------------------------------------------------------------------

---@class AceTabRegistry
---@field prematches string[]|string Table of prematch strings or single prematch
---@field wordlist AceTabWordList|table Function or table for word completion
---@field usagefunc AceTabUsageFunc|boolean|nil Function for usage display or true to suppress
---@field listenframes AceTabEditBox[] Frames to monitor for tab completion
---@field postfunc AceTabPostFunc|nil Function for post-processing matches
---@field pmoverwrite boolean|number|nil Whether/how to overwrite prematch text

function AceTab:RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite)
	-- Validate descriptor
	if type(descriptor) ~= 'string' then 
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'descriptor' - string expected.", 3)
	end
	
	-- Validate prematches
	if prematches and type(prematches) ~= 'string' and type(prematches) ~= 'table' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'prematches' - string, table, or nil expected.", 3)
	end
	
	-- Validate wordlist
	if type(wordlist) ~= 'function' and type(wordlist) ~= 'table' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'wordlist' - function or table expected.", 3)
	end
	
	-- Validate usagefunc
	if usagefunc and type(usagefunc) ~= 'function' and type(usagefunc) ~= 'boolean' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'usagefunc' - function or boolean expected.", 3)
	end
	
	-- Validate listenframes
	if listenframes and type(listenframes) ~= 'string' and type(listenframes) ~= 'table' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'listenframes' - string or table expected.", 3)
	end
	
	-- Validate postfunc
	if postfunc and type(postfunc) ~= 'function' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'postfunc' - function expected.", 3)
	end
	
	-- Validate pmoverwrite
	if pmoverwrite and type(pmoverwrite) ~= 'boolean' and type(pmoverwrite) ~= 'number' then
		error("Usage: RegisterTabCompletion(descriptor, prematches, wordlist, usagefunc, listenframes, postfunc, pmoverwrite): 'pmoverwrite' - boolean or number expected.", 3)
	end

	-- Check for duplicate registration
	if registry[descriptor] then
		error(strformat("Tab completion '%s' is already registered", descriptor), 3)
	end

	local pmtable

	if type(prematches) == 'table' then
		pmtable = prematches
		notfallbacks[descriptor] = true
	else
		pmtable = {}
		-- Mark this group as a fallback group if no value was passed.
		if not prematches then
			pmtable[1] = ""
			fallbacks[descriptor] = true
		-- Make prematches into a one-element table if it was passed as a string.
		elseif type(prematches) == 'string' then
			pmtable[1] = prematches
			if prematches == "" then
				fallbacks[descriptor] = true
			else
				notfallbacks[descriptor] = true
			end
		end
	end

	-- Make listenframes into a one-element table if it was not passed a table of frames.
	if not listenframes then  -- default
		listenframes = {}
		for i = 1, NUM_CHAT_WINDOWS do
			listenframes[i] = _G["ChatFrame"..i.."EditBox"]
		end
	elseif type(listenframes) ~= 'table' or type(listenframes[0]) == 'userdata' and type(listenframes.IsObjectType) == 'function' then  -- single frame or framename
		listenframes = { listenframes }
	end

	-- Hook each registered listenframe and give it a matches table.
	for _, f in pairs(listenframes) do
		if type(f) == 'string' then
			f = _G[f]
		end
		if not f or type(f) ~= 'table' or type(f[0]) ~= 'userdata' or type(f.IsObjectType) ~= 'function' then
			error(strformat(ACETAB_MAJOR..": Cannot register frame %q; it does not exist", tostring(f and f:GetName() and f:GetName() or f)))
		end
		
			if f:GetObjectType() ~= 'EditBox' then
				error(strformat(ACETAB_MAJOR..": Cannot register frame %q; it is not an EditBox", f:GetName()))
		end
		
		---@cast f AceTabEditBox
				hookFrame(f)
	end

	-- Everything checks out; register this completion.
	registry[descriptor] = {
		prematches = pmtable,
		wordlist = wordlist,
		usagefunc = usagefunc,
		listenframes = listenframes,
		postfunc = postfunc,
		pmoverwrite = pmoverwrite
	}
end

function AceTab:IsTabCompletionRegistered(descriptor)
	return registry and registry[descriptor]
end

function AceTab:UnregisterTabCompletion(descriptor)
	registry[descriptor] = nil
	pmolengths[descriptor] = nil
	fallbacks[descriptor] = nil
	notfallbacks[descriptor] = nil
end

-- ------------------------------------------------------------------------------
--- Finds the greatest common substring at the beginning of two strings.
-- This function is used to find the common prefix between multiple possible completions.
-- @param s1 string First string to be compared, or nil to use s2
-- @param s2 string Second string to be compared, or nil to use s1
-- @return string|nil The greatest common substring, or nil if both inputs are nil
-- ------------------------------------------------------------------------------
local function gcbs(s1, s2)
	-- Handle nil cases
	if not s1 and not s2 then return nil end
	if not s1 then s1 = s2 end
	if not s2 then s2 = s1 end
	
	-- Ensure s1 is the shorter string for efficiency
	if #s2 < #s1 then
		s1, s2 = s2, s1
	end
	
	-- Check if s1 is a prefix of s2 (case-insensitive)
	if strfind(strlower(s2), "^"..strlower(s1)) then
		return s1
	else
		-- Recursively try with one character less from s1
		return gcbs(strsub(s1, 1, -2), s2)
	end
end

-- Local variables for tab cycling
local cursor -- Holds cursor position. Set in :OnTabPressed()
local cMatch -- Counter across all sets
local matched -- Tracks if we found a match in the current cycle
local previousLength -- Previous text length
local postmatch -- Post-match text
local text_precursor, text_all, text_pmendToCursor -- Text state variables
local pms, pme, pmt, prematchStart, prematchEnd, text_prematch, entry -- Pattern matching state

--- Cycles through multiple possible tab completions.
-- This function is called when a tab press has multiple possible completions.
-- It allows the user to press tab repeatedly to cycle through different matches.
-- The function stops being called after OnTextChanged() is triggered by something 
-- other than AceTab (i.e. the user inputs a character).
-- @param this table The editbox frame being processed
-- @return nil
---@param this AceTabEditBox
local function cycleTab(this)
	if not this or not this.at3matches then
		return
	end

	cMatch = 0  -- Counter across all sets. The pseudo-index relevant to this value and corresponding to the current match is held in this.at3curMatch
	matched = false

	-- Check each completion group registered to this frame.
	for desc, compgrp in pairs(this.at3matches) do
		if type(compgrp) ~= "table" then
			this.at3matches[desc] = nil
			return
		end

		-- Loop through the valid completions for this set.
		for m, pm in pairs(compgrp) do
			cMatch = cMatch + 1
			if cMatch == this.at3curMatch then  -- we're back to where we left off last time through the combined list
				this.at3lastMatch = m
				this.at3lastWord = pm
				this.at3curMatch = cMatch + 1 -- save the new cMatch index
				matched = true
				break
			end
		end
		if matched then break end
	end

	-- If our index is beyond the end of the list, reset the original uncompleted substring 
	-- and let the cycle start over next time tab is pressed.
	if not matched then
		this.at3lastMatch = this.at3origMatch
		this.at3lastWord = this.at3origWord
		this.at3curMatch = 1
	end

	-- Insert the completion.
	if this.at3matchStart and cursor then
	this:HighlightText(this.at3matchStart-1, cursor)
	this:Insert(this.at3lastWord or '')
	this.at3_last_precursor = getTextBeforeCursor(this) or ''
	end
end

local IsSecureCmd = IsSecureCmd

local candUsage = {}
local numMatches = 0
local firstMatch, hasNonFallback, allGCBS, setGCBS, usage
local text_precursor, text_all, text_pmendToCursor

-- Fills the matches tables with matching completion pairs.
-- @param this table The editbox frame being processed
-- @param desc string The descriptor for the completion set
-- @param fallback boolean Whether this is a fallback completion
-- @return nil
local function fillMatches(this, desc, fallback)
	if not this or not desc then return end
	
	entry = registry[desc]
	if not entry then return end
	
	-- See what frames are registered for this completion group.
	-- If the frame in which we pressed tab is one of them, then we start building matches.
	for _, f in ipairs(entry.listenframes) do
		if f == this then
			-- Try each precondition string registered for this completion group.
			for _, prematch in ipairs(entry.prematches) do
				-- Test if our prematch string is satisfied.
				-- If it is, then we find its last occurence prior to the cursor,
				-- calculate and store its pmoverwrite value (if applicable),
				-- and start considering completions.
				if fallback then 
					prematch = "%s" 
				end

				-- Find the last occurence of the prematch before the cursor.
				pms, pme, pmt = nil, 1, ''
				text_prematch, prematchEnd, prematchStart = nil, nil, nil
				
				while true do
					pms, pme, pmt = strfind(text_precursor, "("..prematch..")", pme)
					if pms then
						prematchStart, prematchEnd, text_prematch = pms, pme, pmt
						pme = pme + 1
					else
						break
					end
				end

				if not prematchStart and fallback then
					prematchStart, prematchEnd, text_prematch = 0, 0, ''
				end
				
				if prematchStart then
					-- text_pmendToCursor should be the sub-word/phrase to be completed.
					text_pmendToCursor = strsub(text_precursor, prematchEnd + 1)

					-- How many characters should we eliminate before the completion before writing it in.
					pmolengths[desc] = entry.pmoverwrite == true and #text_prematch or entry.pmoverwrite or 0

					-- This is where we will insert completions, taking the prematch overwrite into account.
					---@cast this AceTabEditBox
					this.at3matchStart = prematchEnd + 1 - (pmolengths[desc] or 0)

					-- We're either a non-fallback set or all completions thus far have been fallback sets,
					-- and the precondition matches.
					-- Create cands from the registered wordlist, filling it with all potential (unfiltered) completion strings.
					local wordlist = entry.wordlist
					local cands = type(wordlist) == 'table' and wordlist or {}
					
					if type(wordlist) == 'function' then
						wordlist(cands, text_all, prematchEnd + 1, text_pmendToCursor)
					end
					
					if cands ~= false then
						local matches = this.at3matches[desc] or {}
						wipe(matches)

						-- Check each of the entries in cands to see if it completes the word before the cursor.
						-- Finally, increment our match count and set firstMatch, if appropriate.
						for _, m in ipairs(cands) do
							if strfind(strlower(m), strlower(text_pmendToCursor), 1, true) == 1 then  -- we have a matching completion!
								hasNonFallback = hasNonFallback or (not fallback)
								matches[m] = entry.postfunc and entry.postfunc(m, prematchEnd + 1, text_all) or m
								numMatches = numMatches + 1
								if numMatches == 1 then
									firstMatch = matches[m]
								end
							end
						end
						
						if next(matches) then
							this.at3matches[desc] = matches
						else
							this.at3matches[desc] = nil
						end
					end
				end
			end
		end
	end
end

--- Handles tab key presses for registered frames.
-- This is the main tab completion handler that processes tab key presses
-- and manages the completion cycle.
-- @param this table The editbox frame that received the tab press
-- @return boolean True to allow default tab handling, false to suppress it
function AceTab:OnTabPressed(this)
	if not this or not this:GetText() or this:GetText() == '' then 
		return true 
	end

	-- Allow Blizzard to handle slash commands
	if this == ChatEdit_GetActiveWindow() then
		local command = this:GetText()
		if strfind(command, "^/[%a%d_]+$") then
			return true
		end
		local cmd = strmatch(command, "^/[%a%d_]+")
		if cmd and IsSecureCmd(cmd) then
			return true
		end
	end

	cursor = this:GetCursorPosition()
	if not cursor then return true end

	text_all = this:GetText()
	---@cast this AceTabEditBox
	text_precursor = getTextBeforeCursor(this) or ''

	-- If we've already found some matches and haven't done anything since the last tab press,
	-- then (continue) cycling matches. Otherwise, reset this frame's matches and proceed
	-- to creating our list of possible completions.
	this.at3lastMatch = this.at3curMatch > 0 and (this.at3lastMatch or this.at3origWord)
	
	-- Detects if we've made any edits since the last tab press.
	-- If not, continue cycling completions.
	if text_precursor == this.at3_last_precursor then
		---@cast this AceTabEditBox
		return cycleTab(this)
	else
		wipe(this.at3matches)
		this.at3curMatch = 0
		this.at3origWord = nil
		this.at3origMatch = nil
		this.at3lastWord = nil
		this.at3lastMatch = nil
		this.at3_last_precursor = text_precursor
	end

	numMatches = 0
	firstMatch = nil
	hasNonFallback = false
	wipe(pmolengths)

	-- First try non-fallback completions
	for desc in pairs(notfallbacks) do
		fillMatches(this, desc)
	end
	
	-- If no non-fallback completions found, try fallbacks
	if not hasNonFallback then
		for desc in pairs(fallbacks) do
			fillMatches(this, desc, true)
		end
	end

	-- No matches found, allow default tab behavior
	if not firstMatch then
		this.at3_last_precursor = "\0"
		return true
	end

	-- We want to replace the entire word with our completion, so highlight it up to the cursor.
	-- If only one match exists, then stick it in there and append a space.
	if numMatches == 1 then
		-- HighlightText takes the value AFTER which the highlighting starts,
		-- so we have to subtract 1 to have it start before the first character.
		this:HighlightText(this.at3matchStart-1, cursor)
		this:Insert(firstMatch)
		this:Insert(" ")
	else
		-- Otherwise, we want to begin cycling through the valid completions.
		-- Beginning a cycle also causes the usage statement to be printed, if one exists.

		-- Print usage statements for each possible completion
		-- (and gather up the GCBS of all matches while we're walking the tables).
		allGCBS = nil
		for desc, matches in pairs(this.at3matches) do
			-- Don't print usage statements for fallback completion groups
			-- if we have 'real' completion groups with matches.
			if hasNonFallback and fallbacks[desc] then 
				break 
			end

			-- Use the group's description as a heading for its usage statements.
			DEFAULT_CHAT_FRAME:AddMessage(desc..":")

			local usagefunc = registry[desc].usagefunc
			if not usagefunc then
				-- No special usage processing; just print a list of the (formatted) matches.
				for m, fm in pairs(matches) do
					DEFAULT_CHAT_FRAME:AddMessage(fm)
					allGCBS = gcbs(allGCBS, m)
				end
			else
				-- Print a usage statement based on the corresponding registered usagefunc.
				-- candUsage is the table passed to usagefunc to be filled with
				-- candidate = usage_statement pairs.
				if type(usagefunc) == 'function' then
					wipe(candUsage)

					-- usagefunc takes the greatest common substring of valid matches
					-- as one of its args, so let's find that now.
					setGCBS = nil
					for m in pairs(matches) do
						setGCBS = gcbs(setGCBS, m)
					end
					allGCBS = gcbs(allGCBS, setGCBS)
					usage = usagefunc(candUsage, matches, setGCBS, strsub(text_precursor, 1, prematchEnd))

					-- If the usagefunc returns a string, then the entire usage statement
					-- has been taken care of by usagefunc, and we need only to print it...
					if type(usage) == 'string' then
						DEFAULT_CHAT_FRAME:AddMessage(usage)
					-- ...otherwise, it should have filled candUsage with
					-- candidate-usage statement pairs, and we need to print the matching ones.
					elseif next(candUsage) and numMatches > 0 then
						for m, fm in pairs(matches) do
							if candUsage[m] then 
								DEFAULT_CHAT_FRAME:AddMessage(strformat("%s - %s", fm, candUsage[m])) 
							end
						end
					end
				end
			end

			if next(matches) then
				-- Replace the original string with the greatest common substring
				-- of all valid completions.
				this.at3curMatch = 1
				this.at3origWord = (strsub(text_precursor, this.at3matchStart, this.at3matchStart + pmolengths[desc] - 1) .. allGCBS) or ""
				this.at3origMatch = allGCBS or ""
				this.at3lastWord = this.at3origWord
				this.at3lastMatch = this.at3origMatch

				this:HighlightText(this.at3matchStart-1, cursor)
				this:Insert(this.at3origWord)
				this.at3_last_precursor = getTextBeforeCursor(this) or ''
			end
		end
	end
	
	return false
end

--- Registers a spell-aware tab completion set.
-- This specialized registration handles spell name completion with proper localization
-- and spell data validation.
-- @param descriptor string Unique identifier for this tab completion set
-- @param spellFilter function Optional filter function to limit which spells are included
-- @param postfunc function Optional post-processing function for spell matches
-- @param listenframes table|string|nil EditFrames to monitor. Defaults to ChatFrameEditBox
function AceTab:RegisterSpellCompletion(descriptor, spellFilter, postfunc, listenframes)
	if type(descriptor) ~= 'string' then
		error("Usage: RegisterSpellCompletion(descriptor, spellFilter, postfunc, listenframes): 'descriptor' - string expected.", 3)
	end
	
	-- Cache tables for spell lookups with optimized structure
	local spellCache = setmetatable({}, {
		__mode = "kv" -- Allow garbage collection of unused entries
	})
	local talentCache = setmetatable({}, {
		__mode = "kv"
	})
	local specCache = setmetatable({}, {
		__mode = "kv"
	})

	-- Create event frame for cache management with error recovery
	local cacheFrame = CreateFrame("Frame")
	cacheFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	cacheFrame:RegisterEvent("PLAYER_TALENT_UPDATE")
	cacheFrame:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
	cacheFrame:RegisterEvent("SPELLS_CHANGED")
	cacheFrame:SetScript("OnEvent", function(_, event)
		-- Use pcall for error recovery during cache updates
		local success, err = pcall(function()
			if event == "PLAYER_SPECIALIZATION_CHANGED" then
				wipe(specCache)
				wipe(talentCache)
			elseif event == "PLAYER_TALENT_UPDATE" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
				wipe(talentCache)
			elseif event == "SPELLS_CHANGED" then
				-- Only wipe entries that need updating
				for spellID in pairs(spellCache) do
					if not C_Spell.IsSpellDataCached(spellID) then
						spellCache[spellID] = nil
					end
				end
			end
		end)
		if not success then
			-- Recover from error by wiping all caches
			wipe(spellCache)
			wipe(talentCache)
			wipe(specCache)
		end
	end)

	-- Optimized spell validation with batching
	local function validateSpellBatch(spellIDs)
		local results = {}
		local toValidate = {}
		
		-- Check cache first
		for _, spellID in ipairs(spellIDs) do
			if spellCache[spellID] ~= nil then
				results[spellID] = spellCache[spellID]
			else
				toValidate[#toValidate + 1] = spellID
			end
		end
		
		-- Batch validate remaining spells
		if #toValidate > 0 then
			for _, spellID in ipairs(toValidate) do
				local success, exists = pcall(C_Spell.DoesSpellExist, spellID)
				if success and exists then
					local success2, name = pcall(C_Spell.GetSpellInfo, spellID)
					if success2 and name then
						spellCache[spellID] = {
							name = name,
							subtext = nil,
							valid = true
						}
						results[spellID] = spellCache[spellID]
					else
						spellCache[spellID] = false
						results[spellID] = false
					end
				else
					spellCache[spellID] = false
					results[spellID] = false
				end
			end
		end
		
		return results
	end

	-- Add optimized spell lookup function
	local function addSpell(spellID, candidates, spellFilter)
		-- Quick cache check (most common path)
		local cached = spellCache[spellID]
		if cached then
			if cached.valid then
				candidates[cached.name] = true
				candidates[tostring(spellID)] = true
				if cached.subtext then
					candidates[cached.name .. "(" .. cached.subtext .. ")"] = true
				end
			end
			return
		end
		
		-- Validate spell
		local validation = validateSpellBatch({spellID})
		local spellData = validation[spellID]
		
		if spellData and spellData.valid then
			-- Apply filter if provided
			if spellFilter then
				local success, result = pcall(spellFilter, spellID, spellData)
				if not success or not result then
					return
				end
			end
			
			-- Add completions
			candidates[spellData.name] = true
			candidates[tostring(spellID)] = true
			if spellData.subtext then
				candidates[spellData.name .. "(" .. spellData.subtext .. ")"] = true
			end
			
			-- Check for overrides
			local success, overrideID = pcall(C_Spell.GetOverrideSpell, spellID)
			if success and overrideID and overrideID ~= spellID then
				addSpell(overrideID, candidates, spellFilter)
			end
		end
	end

	-- Optimized talent validation with batching
	local function validateTalentBatch(configID, nodeIDs)
		local results = {}
		local toValidate = {}
		
		-- Check cache first
		for _, nodeID in ipairs(nodeIDs) do
			if talentCache[nodeID] ~= nil then
				results[nodeID] = talentCache[nodeID]
			else
				toValidate[#toValidate + 1] = nodeID
			end
		end
		
		-- Batch validate remaining talents
		if #toValidate > 0 and C_Talent then
			local success, configInfo = pcall(C_Talent.GetConfigInfo, configID)
			if success and configInfo then
				for _, nodeID in ipairs(toValidate) do
					local success2, nodeInfo = pcall(C_Talent.GetNodeInfo, configID, nodeID)
					if success2 and nodeInfo and nodeInfo.activeEntry then
						local success3, entryInfo = pcall(C_Talent.GetEntryInfo, configID, nodeInfo.activeEntry.entryID)
						if success3 and entryInfo then
							talentCache[nodeID] = {
								spellID = entryInfo.spellID,
								modifiedSpellID = entryInfo.modifiedSpellID,
								valid = true
							}
							results[nodeID] = talentCache[nodeID]
						else
							talentCache[nodeID] = false
							results[nodeID] = false
						end
					else
						talentCache[nodeID] = false
						results[nodeID] = false
					end
				end
			end
		end
		
		return results
	end

	-- Add optimized spell book management
	local spellBookState = {
		numSkillLines = 0,
		lastUpdate = 0,
		updateInterval = 0.5, -- Throttle updates
		cache = setmetatable({}, {
			__mode = "kv" -- Allow garbage collection of unused entries
		})
	}

	-- Create event frame for spell book management
	local spellBookFrame = CreateFrame("Frame")
	spellBookFrame:RegisterEvent("SPELLS_CHANGED")
	spellBookFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
	spellBookFrame:RegisterEvent("SKILL_LINES_CHANGED")
	spellBookFrame:SetScript("OnEvent", function(_, event)
		-- Mark cache for update
		spellBookState.lastUpdate = 0
	end)

	-- Add timer for throttled updates
	spellBookFrame:SetScript("OnUpdate", function(_, elapsed)
		if spellBookState.lastUpdate + spellBookState.updateInterval > GetTime() then
			return
		end
		
		-- Update spell book state
		local success, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
		if success and numLines then
			spellBookState.numSkillLines = numLines
		end
		
		spellBookState.lastUpdate = GetTime()
	end)

	-- Optimized spell book scanning function
	local function scanSpellBook()
		-- Check if cache is valid
		if next(spellBookState.cache) and spellBookState.lastUpdate + spellBookState.updateInterval > GetTime() then
			return spellBookState.cache
		end
		
		local results = {}
		if spellBookState.numSkillLines == 0 then
			-- Update immediately if we have no data
			local success, numLines = pcall(C_SpellBook.GetNumSpellBookSkillLines)
			if success and numLines then
				spellBookState.numSkillLines = numLines
			else
				return results
			end
		end
		
		-- Pre-allocate tables for better performance
		local spellsToValidate = {}
		local specsToUpdate = {}
		
		-- Batch process skill lines
		for i = 1, spellBookState.numSkillLines do
			local success, skillLineInfo = pcall(C_SpellBook.GetSkillLineInfo, i)
			if success and skillLineInfo and not skillLineInfo.isHidden and not skillLineInfo.isTradeskill then
				local numSpells = skillLineInfo.numAvailableSpells or 0
				local firstIndex = skillLineInfo.firstSpellIndex or 0
				local lastIndex = skillLineInfo.lastSpellIndex or 0
				
				if numSpells > 0 and firstIndex > 0 and lastIndex >= firstIndex then
					-- Store skill line info
					results[i] = {
						info = skillLineInfo,
						spells = {},
						skillLineSpecID = skillLineInfo.specID,
						categoryID = skillLineInfo.categoryID
					}
					
					-- Batch collect spells with error handling
					for j = firstIndex, lastIndex do
						local success2, spellType, spellID = pcall(GetSpellBookItemInfo, j, "spell")
						if success2 and spellID and (spellType == "SPELL" or spellType == "FUTURESPELL") then
							spellsToValidate[#spellsToValidate + 1] = spellID
							results[i].spells[#results[i].spells + 1] = spellID
							
							if skillLineInfo.skillLineSpecID then
								specsToUpdate[skillLineInfo.skillLineSpecID] = specsToUpdate[skillLineInfo.skillLineSpecID] or {}
								table.insert(specsToUpdate[skillLineInfo.skillLineSpecID], spellID)
							end
						end
					end
				end
			end
		end
		
		-- Update cache
		spellBookState.cache = results
		spellBookState.lastUpdate = GetTime()
		
		return results
	end

	-- Optimize spell lookup in spellWordList
	local function spellWordList(candidates, text, pos, word)
		-- Get cached spell book data with error handling
		local success, skillLines = pcall(scanSpellBook)
		if not success then return end
		
		-- Pre-allocate tables for better performance
		local spellsToAdd = {}
		local talentsToProcess = {}
		
		-- Process skill lines in batch
		for _, skillLine in pairs(skillLines) do
			for _, spellID in ipairs(skillLine.spells) do
				spellsToAdd[#spellsToAdd + 1] = spellID
			end
		end
		
		-- Process spells in batch with validation
		if #spellsToAdd > 0 then
			local validations = validateSpellBatch(spellsToAdd)
			for spellID, validation in pairs(validations) do
				if validation and validation.valid then
					candidates[validation.name] = true
					candidates[tostring(spellID)] = true
					if validation.subtext then
						candidates[validation.name .. "(" .. validation.subtext .. ")"] = true
					end
				end
			end
		end
		
		-- Continue with talent processing...
		local numSkillLines = C_SpellBook.GetNumSpellBookSkillLines()
		if not numSkillLines then return end
		
		-- Pre-allocate tables for better performance
		local spellsToAdd = {}
		local specsToUpdate = {}
		
		for i = 1, numSkillLines do
			local skillLineInfo = C_SpellBook.GetSkillLineInfo(i)
			if skillLineInfo and not skillLineInfo.isHidden and not skillLineInfo.isTradeskill then
				local numSpells = skillLineInfo.numAvailableSpells or 0
				local firstIndex = skillLineInfo.firstSpellIndex or 0
				local lastIndex = skillLineInfo.lastSpellIndex or 0
				
				if numSpells > 0 and firstIndex > 0 and lastIndex >= firstIndex then
					-- Batch process spells
					for j = firstIndex, lastIndex do
						local spellType, spellID = GetSpellBookItemInfo(j, "spell")
						if spellID and (spellType == "SPELL" or spellType == "FUTURESPELL") then
							spellsToAdd[#spellsToAdd + 1] = spellID
							if skillLineInfo.skillLineSpecID then
								specsToUpdate[skillLineInfo.skillLineSpecID] = specsToUpdate[skillLineInfo.skillLineSpecID] or {}
								table.insert(specsToUpdate[skillLineInfo.skillLineSpecID], spellID)
							end
						end
					end
				end
			end
		end
		
		-- Process batched spells
		for _, spellID in ipairs(spellsToAdd) do
			addSpell(spellID)
		end
		
		-- Update spec caches in batch
		for specID, spells in pairs(specsToUpdate) do
			if not specCache[specID] then
				specCache[specID] = {}
			end
			for _, spellID in ipairs(spells) do
				table.insert(specCache[specID], spellID)
			end
		end
	end
	
	-- Register with standard completion system
	self:RegisterTabCompletion(
		descriptor,
		nil, -- No prematches, available for all text
		spellWordList,
		false, -- No special usage output
		listenframes,
		postfunc
	)
end

--- Registers a priority-based tab completion set for Hekili.
-- This specialized registration handles priority/action list completions.
-- @param descriptor string Unique identifier for this tab completion set
-- @param spec string|number Optional specialization name or ID to filter priorities
-- @param listenframes table|string|nil EditFrames to monitor
function AceTab:RegisterPriorityCompletion(descriptor, spec, listenframes)
	if type(descriptor) ~= 'string' then
		error("Usage: RegisterPriorityCompletion(descriptor, spec, listenframes): 'descriptor' - string expected.", 3)
	end
	
	-- Create priority completion wordlist function
	local function priorityWordList(candidates, text, pos, word)
		-- Add standard Hekili commands
		local commands = {
			"/hekili",
			"/hekili toggle",
			"/hekili pause",
			"/hekili snapshot",
			"/hekili config",
			"/hekili priority"
		}
		
		for _, cmd in ipairs(commands) do
			candidates[cmd] = true
		end
		
		-- If Hekili is loaded, add actual priorities
		if Hekili and Hekili.DB and Hekili.DB.profile then
			local priorities = Hekili.DB.profile.priorities
			if priorities then
				for name, prio in pairs(priorities) do
					if not spec or prio.spec == spec then
						candidates["/hekili priority " .. name] = true
					end
				end
			end
		end
	end
	
	-- Register with standard completion system
	self:RegisterTabCompletion(
		descriptor,
		"/", -- Only match after slash commands
		priorityWordList,
		function(candidates, matches, substring)
			-- Generate usage information
			local usage = "Available Hekili commands:\n"
			for match in pairs(matches) do
				usage = usage .. "  " .. match .. "\n"
			end
			return usage
		end,
		listenframes
	)
end

--- Registers a talent build completion set for Hekili.
-- Provides intelligent tab completion for talent builds and related commands.
-- Handles talent string import/export, saved builds, and current spec talents.
-- @version 11.0.7
-- @see https://warcraft.wiki.gg/wiki/API_C_ClassTalents.GetActiveConfigID
-- @see https://warcraft.wiki.gg/wiki/API_C_Talent.GenerateImportString
-- @param descriptor string A unique identifier for this completion set
-- @param spec string|number Optional spec name or ID to filter talent builds
-- @param listenframes table|string|nil EditBox frames to monitor for completion
function AceTab:RegisterTalentCompletion(descriptor, spec, listenframes)
	if type(descriptor) ~= 'string' then
		error("Usage: RegisterTalentCompletion(descriptor, spec, listenframes): 'descriptor' - string expected.", 3)
	end
	
	--- Internal function to handle talent build completion word list generation
	-- @param candidates table Table to populate with valid completion options
	-- @param text string Current text in the EditBox
	-- @param pos number Cursor position in the text
	-- @param word string Word being completed
	local function talentWordList(candidates, text, pos, word)
		-- Register core talent management commands
		local commands = {
			"/hekili talents",
			"/hekili talents import",
			"/hekili talents export",
			"/hekili talents save",
			"/hekili talents load"
		}
		
		for _, cmd in ipairs(commands) do
			candidates[cmd] = true
		end
		
		-- Process saved talent builds from Hekili's database
		if Hekili and Hekili.DB and Hekili.DB.profile then
			local builds = Hekili.DB.profile.talents
			if builds then
				for name, build in pairs(builds) do
					if not spec or build.spec == spec then
						candidates["/hekili talents load " .. name] = true
					end
				end
			end
		end
		
		-- Add current specialization's active talent configuration
		if C_Talent then
			local success, configID = pcall(C_ClassTalents.GetActiveConfigID)
			if success and configID then
				local success2, exportString = pcall(C_Talent.GenerateImportString, configID)
				if success2 and exportString then
					candidates["/hekili talents import " .. exportString] = true
				end
			end
		end
	end
	
	-- Register with AceTab completion system
	self:RegisterTabCompletion(
		descriptor,
		"/", -- Restrict to slash command context
		talentWordList,
		function(candidates, matches, substring)
			-- Format available talent commands in a readable list
			local usage = "Available talent commands:\n"
			for match in pairs(matches) do
				if not strfind(match, "import ") then -- Exclude lengthy import strings from display
					usage = usage .. "  " .. match .. "\n"
				end
			end
			return usage
		end,
		listenframes
	)
end

--- Registers a specialization-aware tab completion set.
-- Provides intelligent tab completion for WoW specializations with class context.
-- Handles both spec names and IDs, with optional filtering capabilities.
-- @version 11.0.7
-- @see https://warcraft.wiki.gg/wiki/API_GetSpecializationInfoByID
-- @param descriptor string A unique identifier for this completion set
-- @param specFilter function|nil Optional filter function(specID, specInfo) that returns true to include the spec
-- @param listenframes table|string|nil EditBox frames to monitor for completion. Defaults to all chat frames
function AceTab:RegisterSpecCompletion(descriptor, specFilter, listenframes)
	if type(descriptor) ~= 'string' then
		error("Usage: RegisterSpecCompletion(descriptor, specFilter, listenframes): 'descriptor' - string expected.", 3)
	end
	
	--- Internal function to handle spec completion word list generation
	-- @param candidates table Table to populate with valid completion options
	-- @param text string Current text in the EditBox
	-- @param pos number Cursor position in the text
	-- @param word string Word being completed
	local function specWordList(candidates, text, pos, word)
		--- Adds a single specialization to the completion candidates
		-- Handles conversion, validation and formatting of spec data
		-- @param specID number|string The specialization ID to process
		local function addSpec(specID)
			if not specID then return end
			
			-- Ensure numeric specID for API calls
			specID = tonumber(specID)
			if not specID then return end
			
			-- Retrieve spec info with error handling
			local success, specName, _, _, _, _, classID = pcall(GetSpecializationInfoByID, specID)
			if not success or not specName then return end
			
			-- Apply custom filtering if provided
			if specFilter and not specFilter(specID, {name = specName}) then
				return
			end
			
			-- Register both name and ID as valid completions
			candidates[specName] = true
			candidates[tostring(specID)] = true
			
			-- Add class-qualified spec name for clarity
			if classID then
				local success2, _, className = pcall(GetClassInfo, classID)
				if success2 and className then
					candidates[className .. " " .. specName] = true
				end
			end
		end
		
		-- Process all available specializations
		for i = 1, GetNumSpecializations() do
			local success, specID = pcall(GetSpecializationInfo, i)
			if success and specID then
				addSpec(specID)
			end
		end
	end
	
	-- Register with AceTab completion system
	self:RegisterTabCompletion(
		descriptor,
		nil, -- Available for all text input
		specWordList,
		function(candidates, matches, substring)
			-- Format available specs in a readable list
			local usage = "Available specializations:\n"
			for match in pairs(matches) do
				if not tonumber(match) then -- Exclude raw spec IDs from display
					usage = usage .. "  " .. match .. "\n"
				end
			end
			return usage
		end,
		listenframes
	)
end

--- Validates if a specialization ID is valid and available to the player
-- @param specID number The specialization ID to validate
-- @return boolean True if the spec exists and is available
-- @see https://warcraft.wiki.gg/wiki/API_GetSpecializationInfo
local function IsValidSpec(specID)
	if not specID then return false end
	
	-- Verify spec exists in game data
	local specInfo = GetSpecializationInfoByID(specID)
	if not specInfo then return false end
	
	-- Check if spec is available to current character
	for i = 1, GetNumSpecializations() do
		if GetSpecializationInfo(i) == specID then
			return true
		end
	end
	
	return false
end

--- Registers an action list completion set for Hekili.
-- This specialized registration handles action list completions.
-- @param descriptor string Unique identifier for this tab completion set
-- @param spec string|number Optional specialization name or ID to filter action lists
-- @param listenframes table|string|nil EditFrames to monitor
function AceTab:RegisterActionListCompletion(descriptor, spec, listenframes)
	if type(descriptor) ~= 'string' then
		error("Usage: RegisterActionListCompletion(descriptor, spec, listenframes): 'descriptor' - string expected.", 3)
	end
	
	-- Create action list completion wordlist function
	local function actionListWordList(candidates, text, pos, word)
		-- Add action list commands
		local commands = {
			"/hekili actionlist",
			"/hekili actionlist show",
			"/hekili actionlist hide",
			"/hekili actionlist toggle",
			"/hekili actionlist save",
			"/hekili actionlist load",
			"/hekili actionlist import",
			"/hekili actionlist export"
		}
		
		for _, cmd in ipairs(commands) do
			candidates[cmd] = true
		end
		
		-- If Hekili is loaded, add actual action lists
		if Hekili and Hekili.DB and Hekili.DB.profile then
			local lists = Hekili.DB.profile.actionLists
			if lists then
				for name, list in pairs(lists) do
					if not spec or list.spec == spec then
						candidates["/hekili actionlist load " .. name] = true
						candidates["/hekili actionlist show " .. name] = true
						candidates["/hekili actionlist hide " .. name] = true
						candidates["/hekili actionlist toggle " .. name] = true
					end
				end
			end
			
			-- Add action entries from current priority
			local priority = Hekili.DB.profile.priorities[Hekili.currentPriority]
			if priority and priority.actions then
				for _, action in ipairs(priority.actions) do
					if type(action) == "string" then
						candidates[action] = true
					end
				end
			end
		end
	end
	
	-- Register with standard completion system
	self:RegisterTabCompletion(
		descriptor,
		"/", -- Only match after slash commands
		actionListWordList,
		function(candidates, matches, substring)
			-- Generate usage information
			local usage = "Available action list commands:\n"
			for match in pairs(matches) do
				if strfind(match, "^/hekili") then
					usage = usage .. "  " .. match .. "\n"
				end
			end
			if Hekili and Hekili.currentPriority then
				usage = usage .. "\nCurrent priority actions:\n"
				for match in pairs(matches) do
					if not strfind(match, "^/") then
						usage = usage .. "  " .. match .. "\n"
					end
				end
			end
			return usage
		end,
		listenframes
	)
end

-- Add helper function for action validation
local function IsValidAction(action, spec)
	if not action or type(action) ~= "string" then return false end
	
	-- Check if action exists in current priority
	if Hekili and Hekili.DB and Hekili.DB.profile then
		local priority = Hekili.DB.profile.priorities[Hekili.currentPriority]
		if priority and priority.actions then
			for _, a in ipairs(priority.actions) do
				if a == action then
					return true
				end
			end
		end
	end
	
	return false
end

-- Add helper function for spell validation (restored)
local function IsSpellKnownOrOverridden(spellID)
	if not spellID then return false end
	
	-- Check if spell exists
	if not C_Spell.DoesSpellExist(spellID) then 
		return false 
	end
	
	-- Check if spell is known
	if IsSpellKnown(spellID) then
		return true
	end
	
	-- Check for talent-modified version
	local overrideID = C_Spell.GetOverrideSpell(spellID)
	if overrideID and overrideID ~= spellID then
		return IsSpellKnown(overrideID)
	end
	
	return false
end

-- Type definitions for SpellBook
---@class SpellBookSkillLineInfo
---@field categoryID number The category ID of the skill line
---@field skillLineName string The name of the spell line (General, Shadow, Fury, etc)
---@field skillLineID number The unique identifier for this skill line
---@field skillLineDisplayName string The display name for this skill line
---@field skillLineIconID number The spell icon texture fileID
---@field isTradeskill boolean Whether this is a tradeskill line
---@field isHidden boolean Whether this line should be hidden
---@field numAvailableSpells number The number of available spells
---@field firstSpellIndex number The first spell index in this line
---@field lastSpellIndex number The last spell index in this line
---@field skillLineSpecID number|nil The associated specialization ID, if any
---@field skillLineOffSpecID number|nil The associated off-spec ID, if any
