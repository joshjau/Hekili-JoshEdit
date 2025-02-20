--- = Background =
-- LibSpellRange-1.0 provides enhanced spell range checking functionality
-- Updated for WoW 11.0.7 (The War Within) with modern API support
--
-- Features:
-- * Efficient range checking with caching
-- * Support for both player and pet spells
-- * Handles spell overrides from talents
-- * Modern API compatibility with fallbacks
-- * Async spell data loading support
--
-- @class file
-- @name LibSpellRange-1.0.lua
-- @release 28
-- @author Joshua James

local major = "SpellRange-1.0"
local minor = 28

assert(LibStub, format("%s requires LibStub.", major))

local Lib = LibStub:NewLibrary(major, minor)
if not Lib then return end

-- Localize globals for performance
local type = type
local select = select
local tonumber = tonumber
local strlower = strlower
local wipe = wipe
local format = format
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local GetTime = GetTime
local Spell = Spell

---@class SpellInfo
---@field timestamp number Time when this spell info was cached
---@field hasRange? boolean Whether this spell has range requirements
---@field isPetSpell? boolean Whether this is a pet ability
---@field petActionSlot? number The pet action bar slot if applicable
---@field checksRange? boolean Whether this spell checks range (pet spells)

-- Modern API references with descriptions
--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellInRange
local IsSpellInRange = C_Spell.IsSpellInRange -- Checks if target is within spell range

--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.SpellHasRange
local SpellHasRange = C_Spell.SpellHasRange -- Checks if spell has range requirements

--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.GetOverrideSpell
--- Gets the override spell ID for a given spell, if one exists.
--- This is commonly used for spells that are modified by talents or other effects.
local GetOverrideSpell = C_Spell.GetOverrideSpell -- Gets talent-modified version of spell

--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellInfo
local GetSpellInfo = C_Spell.GetSpellInfo -- Gets basic spell information

--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.DoesSpellExist
local DoesSpellExist = C_Spell.DoesSpellExist -- Checks if spell exists in game database

--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.GetSpellIDForSpellIdentifier
local GetSpellIDForSpellIdentifier = C_Spell.GetSpellIDForSpellIdentifier -- Gets spell ID from various inputs

--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.HasPetSpells
local HasPetSpells = C_SpellBook.HasPetSpells -- Gets number of pet spells and pet token

--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.GetSpellBookItemInfo
--- Gets information about a spell in the spellbook
--- Returns information about the specified spell book item, including:
--- - Spell type (SPELL, PETACTION, FUTURESPELL, etc.)
--- - Spell ID
--- - Whether it's a passive ability
--- - Whether it's disabled
--- - Whether it's an offensive ability
--- @type fun(index: number, spellBookType: Enum.SpellBookSpellBank): SpellBookItemInfo
local GetSpellBookItemInfo = C_SpellBook.GetSpellBookItemInfo -- Gets spellbook item information

---@enum SpellBookItemType
local SpellBookItemType = {
	None = 0,        -- No valid spell
	Spell = 1,       -- Regular player spell
	FutureSpell = 2, -- Spell not yet learned
	PetAction = 3,   -- Pet ability
	Flyout = 4       -- Spell flyout (like Warlock curses)
}

---@class SpellBookInfo
---@field spellID number The unique identifier for the spell
---@field itemType SpellBookItemType The type of spell book item
---@field name string The localized name of the spell
---@field subName string The spell's subtext (may be empty for flyouts or if spell data isn't loaded)
---@field iconID number The spell icon texture FileID
---@field isPassive boolean Whether the spell is passive
---@field isOffSpec boolean Whether the spell belongs to a non-active specialization
---@field skillLineIndex? number Index of the SkillLine this spell belongs to (nil if not part of a skill line)
---@field actionID? number For pet actions, stores the original action ID before any overrides (only set for pet spells)

--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.SpellBookItemHasRange
local SpellBookItemHasRange = C_SpellBook.SpellBookItemHasRange -- Checks if spellbook item has range

--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.IsSpellBookItemInRange
local IsSpellBookItemInRange = C_SpellBook.IsSpellBookItemInRange -- Checks if spellbook item is in range

--- @see https://warcraft.wiki.gg/wiki/API_GetPetActionInfo
local GetPetActionInfo = GetPetActionInfo -- Gets information about a pet action slot (combat pet abilities)

--- @see https://warcraft.wiki.gg/wiki/API_UnitIsEnemy
local UnitIsEnemy = UnitIsEnemy -- Checks if a unit is hostile

-- Constants
--- Duration in seconds before cached range checks expire
--- Optimized for Hekili's rotation calculations:
--- - 0.15s for better performance while maintaining accuracy
--- - Slightly longer than default to reduce checks during rapid ability usage
--- - Still short enough to catch important range changes
local RANGE_CACHE_DURATION = 0.15 -- Increased from 0.1 for better Hekili performance

--- Maximum number of spells to keep in the info cache
--- Optimized for Hekili's typical rotation needs:
--- - Most specs use 20-40 core abilities
--- - Extra room for procs and modified abilities
--- - Reduced from 1000 to save memory while covering all needed spells
local SPELL_CACHE_SIZE = 250 -- Reduced from 1000 to optimize for Hekili's needs

-- Use high-precision timer for critical timing operations
local GetPreciseTime = GetTimePreciseSec or GetTime

-- Helper function for defensive unit method checking
local function SafeUnitMethod(unit, methodName, defaultValue)
	return type(unit[methodName]) == "function" and unit[methodName](unit) or defaultValue
end

-- Range tables for different types of checks
--- @class RangeTable
--- @field Hostile table Range information for hostile targets
--- @field Friendly table Range information for friendly targets
local RangeTable = {
	Hostile = {
		-- Common ranges in yards that spells use
		-- Ordered from shortest to longest for efficient checking
		-- Optimized for DPS calculations with most common combat ranges first
		Ranges = {5, 8, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60},
		-- Cache of range results with weak values for garbage collection
		Results = setmetatable({}, {__mode = "v"})
	},
	Friendly = {
		Ranges = {5, 8, 10, 15, 20, 25, 30, 35, 40},
		Results = setmetatable({}, {__mode = "v"})
	}
}

-- Helper function to find the best range to check
--- Finds the most appropriate range bracket for a given distance
--- @param distance number The target distance to check
--- @param isHostile boolean Whether checking against hostile or friendly ranges
--- @return number The closest available range that's less than or equal to the target distance
local function GetBestRangeToCheck(distance, isHostile)
	local ranges = isHostile and RangeTable.Hostile.Ranges or RangeTable.Friendly.Ranges
	-- Find the closest range that's less than or equal to the requested distance
	for i = #ranges, 1, -1 do
		if ranges[i] <= distance then
			return ranges[i]
		end
	end
	return ranges[1] -- Return minimum range if nothing else found
end

-- Helper function to validate spell existence
--- Checks if a spell exists in the game database and is properly loaded
--- @param spellID number The spell ID to check
--- @return boolean exists True if the spell exists and is loaded
--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.DoesSpellExist
local function ValidateSpell(spellID)
	if not spellID or type(spellID) ~= "number" then 
		return false 
	end
	
	-- Check if spell exists in game database
	if not DoesSpellExist(spellID) then
		return false
	end
	
	-- Create spell object for async loading
	local spell = Spell:CreateFromSpellID(spellID)
	if not spell:IsSpellDataCached() then
		spell:ContinueOnSpellLoad(function()
			-- Force cache update when spell data is loaded
			-- Clear all related caches to ensure consistency
			spellInfoCache[spellID] = nil
			petSpellCache[spellID] = nil
			overrideCache[spellID] = nil
			-- Clear range cache entries for this spell
			for k in pairs(RangeTable.Hostile.Results) do
				if k:match("^" .. spellID .. "_") then
					RangeTable.Hostile.Results[k] = nil
				end
			end
			for k in pairs(RangeTable.Friendly.Results) do
				if k:match("^" .. spellID .. "_") then
					RangeTable.Friendly.Results[k] = nil
				end
			end
		end)
		return false
	end
	
	return true
end

-- Helper function to get range check key
--- Generates a unique cache key for range checks
--- Optimized for Hekili's state tracking
--- @param spellID number The spell ID being checked
--- @param unit string The unit being targeted
--- @return string A unique key for caching range check results
local function GetRangeKey(spellID, unit)
	-- For Hekili integration, include combat state, spec, and haste (for range modifications)
	local spec = select(2, GetSpecializationInfo(GetSpecialization() or 0)) or ""
	local inCombat = InCombatLockdown() and "c" or "n"
	local haste = ("%.2f"):format(UnitSpellHaste("player") or 0)
	return format("%d_%s_%s_%s_%s", spellID, unit, spec, inCombat, haste)
end

-- Update range check caching
--- Retrieves cached range check results if still valid
--- Optimized for Hekili's rotation calculations
--- @param spellID number The spell ID being checked
--- @param unit string The unit being targeted
--- @param isHostile boolean Whether checking against hostile or friendly ranges
--- @return boolean|nil result The cached range check result
--- @return number|nil distance The cached distance
local function GetCachedRangeCheck(spellID, unit, isHostile)
	if not spellID or not unit then return nil, nil end
	if not UnitExists(unit) then return nil, nil end
	
	local results = isHostile and RangeTable.Hostile.Results or RangeTable.Friendly.Results
	local key = GetRangeKey(spellID, unit)
	local entry = results[key]
	
	if entry then
		local now = GetPreciseTime()
		-- Optimize cache duration based on combat state and target type
		local cacheDuration = RANGE_CACHE_DURATION
		if InCombatLockdown() then
			-- Extend cache in combat for better performance
			cacheDuration = cacheDuration * 1.5
			-- Further extend for pet abilities and non-movement intensive spells
			if entry.isPetSpell or entry.isStationary then
				cacheDuration = cacheDuration * 1.2
			end
		end
		
		if now - entry.timestamp <= cacheDuration then
			return entry.result, entry.distance
		end
	end
	return nil, nil
end

--- Stores range check results in the cache
--- @param spellID number The spell ID being checked
--- @param unit string The unit being targeted
--- @param result boolean The range check result
--- @param distance number The distance used for the check
--- @param isHostile boolean Whether this was a hostile or friendly check
--- @param isPetSpell boolean? Whether this is a pet ability
--- @param isStationary boolean? Whether this is a non-movement intensive spell
local function SetCachedRangeCheck(spellID, unit, result, distance, isHostile, isPetSpell, isStationary)
	local results = isHostile and RangeTable.Hostile.Results or RangeTable.Friendly.Results
	local key = GetRangeKey(spellID, unit)
	
	results[key] = {
		timestamp = GetPreciseTime(),
		result = result,
		distance = distance,
		isPetSpell = isPetSpell,
		isStationary = isStationary
	}
end

-- Cache maintenance
--- Performs periodic cleanup of cached data
--- Optimized for Hekili's performance needs
local function CleanupCache()
	local now = GetPreciseTime()
	local inCombat = InCombatLockdown()
	
	-- Cleanup expired range results with optimized iteration
	if RangeTable and RangeTable.Hostile and RangeTable.Hostile.Results then
		for k, v in pairs(RangeTable.Hostile.Results) do
			local cacheDuration = RANGE_CACHE_DURATION
			if inCombat then
				cacheDuration = cacheDuration * 1.5
				if v.isPetSpell or v.isStationary then
					cacheDuration = cacheDuration * 1.2
				end
			end
			if now - v.timestamp > cacheDuration then
				RangeTable.Hostile.Results[k] = nil
			end
		end
	end
	
	if RangeTable and RangeTable.Friendly and RangeTable.Friendly.Results then
		for k, v in pairs(RangeTable.Friendly.Results) do
			local cacheDuration = RANGE_CACHE_DURATION
			if inCombat then
				cacheDuration = cacheDuration * 1.5
				if v.isPetSpell or v.isStationary then
					cacheDuration = cacheDuration * 1.2
				end
			end
			if now - v.timestamp > cacheDuration then
				RangeTable.Friendly.Results[k] = nil
			end
		end
	end
	
	-- Optimize spell info cache with combat awareness
	if not spellInfoCache then return end
	
	-- Sort spells by priority for cache retention
	local spells = {}
	for k, v in pairs(spellInfoCache) do
		if type(v) == "table" then
			table.insert(spells, {id = k, info = v})
		end
	end
	
	if #spells > 0 then
		table.sort(spells, function(a, b)
			-- Prioritize combat-used spells
			if inCombat then
				local aLastUse = a.info.lastCombatUse or 0
				local bLastUse = b.info.lastCombatUse or 0
				if aLastUse ~= bLastUse then
					return aLastUse > bLastUse
				end
			end
			return (a.info.timestamp or 0) > (b.info.timestamp or 0)
		end)
		
		-- Remove oldest entries if cache is full
		if #spells > SPELL_CACHE_SIZE then
			for i = SPELL_CACHE_SIZE + 1, #spells do
				spellInfoCache[spells[i].id] = nil
			end
		end
	end
end

-- Helper function to safely get spellbook info with error handling
--- Gets spell book information with proper error handling and additional pet action handling
--- This function provides a safe wrapper around C_SpellBook.GetSpellBookItemInfo with:
--- - Input validation
--- - Error handling
--- - Special handling for pet actions
--- - Additional fields for pet spells
--- @param index number The index in the spell book (1-based)
--- @param spellBookType Enum.SpellBookSpellBank The spell book type to check (Player = 0, Pet = 1)
--- @return SpellBookItemInfo|nil info The spell information if successful, nil if invalid or error occurs
local function GetSpellBookInfoSafe(index, spellBookType)
	if type(index) ~= "number" or index < 1 then return nil end
	if not spellBookType then return nil end
	
	-- Get spell info using C_SpellBook API
	local spellInfo = C_SpellBook.GetSpellBookItemInfo(index, spellBookType)
	if not spellInfo then return nil end
	
	-- For pet actions, we need to handle the action ID
	if spellInfo.itemType == SpellBookItemType.PetAction then
		-- Modern API already provides correct spellID
		spellInfo.actionID = spellInfo.spellID
	end
	
	return spellInfo
end

-- Initialize update frame if needed
if not Lib.updaterFrame then
	Lib.updaterFrame = CreateFrame("Frame")
end

-- Spell info cache with weak values
local spellInfoCache = setmetatable({}, {
	__mode = "v",
	__index = function(t, spellID)
		if not ValidateSpell(spellID) then 
			t[spellID] = false
			return false 
		end
		
		-- Get spell info
		local info = GetSpellInfo(spellID)
		if not info then
			t[spellID] = false
			return false
		end
		
		-- Store additional metadata
		info.timestamp = GetTime()
		
		-- Get range information
		if SpellHasRange(spellID) then
			-- Try to get range from spell info
			local spellData = GetSpellInfo(spellID)
			if spellData then
				info.hasRange = true
				-- Default to melee range if no specific range found
				info.minRange = 0
				info.maxRange = 5

				-- Check common ranges to find actual max range
				for _, range in ipairs(RangeTable.Hostile.Ranges) do
					if IsSpellInRange(spellID, "target") ~= nil then
						info.maxRange = range
						break
					end
				end
			end
		end
		
		t[spellID] = info
		return info
	end
})

-- Cache key generator for override cache (internal use)
local function GetOverrideCacheKey(spellID)
	return tostring(spellID or 0)
end

-- Cache for spell override checks
local overrideCache = setmetatable({}, {
	__mode = "kv",
	__index = function(t, key)
		local spellID = tonumber(key)
		
		if not spellID or type(spellID) ~= "number" then 
			t[key] = false
			return false 
		end
		
		-- Check if spell exists first
		if not DoesSpellExist(spellID) then
			t[key] = false
			return false
		end
		
		-- Create spell object for async loading
		local spell = Spell:CreateFromSpellID(spellID)
		if not spell:IsSpellDataCached() then
			spell:ContinueOnSpellLoad(function()
				-- Force cache update when spell data is loaded
				t[key] = nil
			end)
			return false
		end
		
		-- Get override information
		local overrideID = GetOverrideSpell(spellID)
		if not overrideID then
			t[key] = false
			return false
		end
		
		-- Don't cache if the override is the same as input
		if overrideID == spellID then
			t[key] = false
			return false
		end
		
		-- Verify override spell exists and has range
		if DoesSpellExist(overrideID) then
			local overrideSpell = Spell:CreateFromSpellID(overrideID)
			if overrideSpell:IsSpellDataCached() and SpellHasRange(overrideID) then
				t[key] = overrideID
				return overrideID
			end
		end
		
		t[key] = false
		return false
	end
})

-- Helper function to get spell override (internal use)
local function GetSpellOverride(spellID)
	local key = GetOverrideCacheKey(spellID)
	return overrideCache[key]
end

-- Helper function to check spellbook range
--- Checks if a spell in the spellbook is within range of the target
--- @param spellID number The spell ID to check
--- @param spellBank Enum.SpellBookSpellBank The spellbook type (0 for Player, 1 for Pet)
--- @param unit string? Optional specific target; If not supplied, player's current target will be used
--- @return boolean|nil True if in range, false if out of range, nil if check was invalid
--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.IsSpellBookItemInRange
local function CheckSpellBookRange(spellID, spellBank, unit)
	if not spellID or not spellBank then return nil end
	if not unit then unit = "target" end
	if not UnitExists(unit) then return nil end
	
	-- First check if the spell has range requirements
	if not C_SpellBook.SpellBookItemHasRange(spellID, spellBank) then
		return false
	end
	
	return C_SpellBook.IsSpellBookItemInRange(spellID, spellBank, unit)
end

-- Pet spell cache
local petSpellCache = setmetatable({}, {
	__mode = "v",
	__index = function(t, spellID)
		if not spellID or type(spellID) ~= "number" then return nil end
		
		-- Check if spell exists first
		if not C_Spell.DoesSpellExist(spellID) then
			t[spellID] = false
			return false
		end
		
		-- Create spell object for async loading
		local spell = Spell:CreateFromSpellID(spellID)
		if not spell:IsSpellDataCached() then
			spell:ContinueOnSpellLoad(function()
				-- Force cache update when spell data is loaded
				t[spellID] = nil
			end)
			return false
		end
		
		-- Get spell info
		local spellInfo = C_Spell.GetSpellInfo(spellID)
		if not spellInfo then
			t[spellID] = false
			return false
		end
		
		-- Check if it's a pet spell
		local bookInfo = GetSpellBookInfoSafe(spellID, Enum.SpellBookSpellBank.Pet)
		if bookInfo and bookInfo.itemType == SpellBookItemType.PetAction then
			spellInfo.timestamp = GetTime()
			spellInfo.isPetSpell = true
			spellInfo.spellID = spellID
			spellInfo.checksRange = C_SpellBook.SpellBookItemHasRange(spellID, Enum.SpellBookSpellBank.Pet)
			spellInfo.maxRange = 5 -- Default pet ability range
			
			t[spellID] = spellInfo
			return spellInfo
		end
		
		t[spellID] = false
		return false
	end
})

-- Update pet spell info when pet bar changes
--- Refreshes the pet spell cache when pet-related events occur
--- - Clears existing cache
--- - Scans pet spellbook for new spells
--- - Updates cache with current pet abilities
local function UpdatePetSpells()
	-- Clear existing pet spell cache
	wipe(petSpellCache)
	
	-- Get pet spells info
	local numSpells, petToken = C_SpellBook.HasPetSpells()
	if not numSpells then return end
	
	-- Cache pet spells
	for i = 1, numSpells do
		local spellInfo = C_SpellBook.GetSpellBookItemInfo(i, Enum.SpellBookSpellBank.Pet)
		if spellInfo and spellInfo.itemType == Enum.SpellBookItemType.PetAction then
			-- Ensure we have a valid spellID
			if spellInfo.spellID and spellInfo.spellID > 0 then
				-- Initialize new cache entry
				petSpellCache[spellInfo.spellID] = {
					timestamp = GetTime(),
					isPetSpell = true,
					spellID = spellInfo.spellID,
					name = spellInfo.name,
					hasRange = nil, -- Will be determined on first range check
					checksRange = C_SpellBook.SpellBookItemHasRange(i, Enum.SpellBookSpellBank.Pet),
					maxRange = 5 -- Default pet ability range
				}
			end
		end
	end
end

-- Event handling
--- Handles events that require pet spell cache updates
--- @param self Frame The event handler frame
--- @param event string The event name
--- @param ... any Additional event parameters
local function OnEvent(self, event, ...)
	if event == "SPELLS_CHANGED" or event == "PET_BAR_UPDATE" or (event == "UNIT_PET" and ... == "player") then
		UpdatePetSpells()
	elseif event == "UNIT_IN_RANGE_UPDATE" then
		local unit = ...
		-- Clear cached range checks for this unit
		for k in pairs(RangeTable.Hostile.Results) do
			if k:match("_" .. unit .. "$") then
				RangeTable.Hostile.Results[k] = nil
			end
		end
		for k in pairs(RangeTable.Friendly.Results) do
			if k:match("_" .. unit .. "$") then
				RangeTable.Friendly.Results[k] = nil
			end
		end
	end
end

-- Register all events
Lib.updaterFrame:UnregisterAllEvents()
Lib.updaterFrame:RegisterEvent("SPELLS_CHANGED")
Lib.updaterFrame:RegisterEvent("PET_BAR_UPDATE")
Lib.updaterFrame:RegisterEvent("UNIT_PET")
Lib.updaterFrame:RegisterEvent("UNIT_IN_RANGE_UPDATE")
Lib.updaterFrame:SetScript("OnEvent", OnEvent)
Lib.updaterFrame:SetScript("OnUpdate", function(self, elapsed)
	self.lastCleanup = (self.lastCleanup or 0) + elapsed
	if self.lastCleanup >= 1 then -- Cleanup every second
		CleanupCache()
		self.lastCleanup = 0
	end
end)

-- Update IsSpellInRange to use optimized range checking
--- Returns whether a target is within range of the spell
--- Optimized for Hekili's DPS calculations
--- @param spellInput number|string SpellID, name, or hyperlink of the spell to check
--- @param unit string? UnitToken - Optional specific target; If not supplied, player's current target will be used
--- @return number|nil 1 if in range, 0 if out of range, nil if the range check was invalid (ie due to invalid spell, missing target)
--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.IsSpellInRange
function Lib.IsSpellInRange(spellInput, unit)
	-- Quick return for nil input
	if not spellInput then return nil end
	if not unit then unit = "target" end
	if not UnitExists(unit) then return nil end
	
	local spellID
	
	-- Handle numeric spell IDs with override checking
	if type(spellInput) == "number" then
		spellID = spellInput
	else
		spellID = C_Spell.GetSpellIDForSpellIdentifier(spellInput)
	end
	
	if not spellID then return nil end
	
	-- Check spell exists and get info
	local spellInfo = spellInfoCache[spellID]
	if not spellInfo then
		spellInfo = petSpellCache[spellID]
		if not spellInfo then return nil end
	end
	
	-- Track combat usage for cache prioritization
	if InCombatLockdown() then
		spellInfo.lastCombatUse = GetTime()
	end
	
	-- Check for override spell
	local overrideID = C_Spell.GetOverrideSpell(spellID)
	if overrideID then
		spellID = overrideID
		-- Update spell info for override
		spellInfo = spellInfoCache[overrideID] or petSpellCache[overrideID]
		if not spellInfo then return nil end
	end
	
	-- Determine if target is hostile
	local isHostile = UnitIsEnemy("player", unit)
	
	-- Get cached range check if available
	local cachedResult, cachedDistance = GetCachedRangeCheck(spellID, unit, isHostile)
	if cachedResult ~= nil then
		return cachedResult and 1 or 0
	end
	
	-- Handle pet spells specially
	if spellInfo.isPetSpell then
		-- Check range using modern API
		local result = C_SpellBook.IsSpellBookItemInRange(spellID, Enum.SpellBookSpellBank.Pet, unit)
		if result ~= nil then
			SetCachedRangeCheck(spellID, unit, result, spellInfo.maxRange or 5, isHostile, true, false)
			return result and 1 or 0
		end
	end
	
	-- Get spell range
	local maxRange = spellInfo.maxRange
	if maxRange then
		-- Use best range for checking
		local checkRange = GetBestRangeToCheck(maxRange, isHostile)
		local result = C_Spell.IsSpellInRange(spellID, unit)
		if result ~= nil then
			SetCachedRangeCheck(spellID, unit, result, checkRange, isHostile, false, false)
		end
		return result and 1 or result == false and 0 or result
	end
	
	-- Fallback to direct range check
	local result = C_Spell.IsSpellInRange(spellID, unit)
	if result ~= nil then
		SetCachedRangeCheck(spellID, unit, result, 5, isHostile, false, false) -- Default to melee range if unknown
	end
	return result and 1 or result == false and 0 or result
end

-- Update SpellHasRange to use improved range info
--- Returns whether a spell has a min and/or max range greater than 0
--- This is an enhanced version of the base C_Spell.SpellHasRange API that adds:
--- - Caching for performance optimization
--- - Support for both spell IDs and spell names/hyperlinks
--- - Proper handling of spell overrides from talents
--- - Pet spell support
--- @param spellInput number|string SpellID, name, or hyperlink of the spell to check
--- @return boolean|nil True if the spell has a range, false if it does not, nil if:
---   - The spell does not exist
---   - The spell data is not yet cached
---   - The input is invalid or nil
--- @see https://warcraft.wiki.gg/wiki/API_C_Spell.SpellHasRange
function Lib.SpellHasRange(spellInput)
	-- Quick return for nil input
	if not spellInput then return nil end
	
	local spellID
	
	-- Handle numeric spell IDs with override checking
	if type(spellInput) == "number" then
		spellID = spellInput
		-- Quick validation for obviously invalid spell IDs
		if spellID <= 0 then return nil end
	else
		-- For string inputs, verify spell exists by getting its ID
		if type(spellInput) ~= "string" then return nil end
		spellID = C_Spell.GetSpellIDForSpellIdentifier(spellInput)
	end
	
	if not spellID then return nil end
	
	-- Fast path: Check if we have cached info
	local spellInfo = spellInfoCache[spellID]
	if spellInfo and spellInfo.hasRange ~= nil then
		return spellInfo.hasRange
	end
	
	-- Check if it's a pet spell if no regular spell info found
	if not spellInfo then
		spellInfo = petSpellCache[spellID]
		if not spellInfo then return nil end
	end
	
	-- Check for override spell (e.g. from talents)
	local overrideID = C_Spell.GetOverrideSpell(spellID)
	if overrideID then
		spellID = overrideID
		-- Update spell info for override
		spellInfo = spellInfoCache[overrideID] or petSpellCache[overrideID]
		if not spellInfo then return nil end
		
		-- Fast path: Check override cached info
		if spellInfo.hasRange ~= nil then
			return spellInfo.hasRange
		end
	end
	
	-- Handle pet spells specially
	if spellInfo.isPetSpell then
		-- If we have a pet action slot and it checks range, it has range
		if spellInfo.petActionSlot and spellInfo.checksRange then
			spellInfo.hasRange = true
			return true
		end
		
		-- Otherwise check spellbook
		local result = CheckSpellBookRange(spellID, Enum.SpellBookSpellBank.Pet, "player") ~= nil
		spellInfo.hasRange = result
		return result
	end
	
	-- Check if spell has range using base API
	local result = SpellHasRange(spellID)
	
	-- Cache the result
	if spellInfo then
		spellInfo.hasRange = result
		spellInfo.timestamp = GetTime()
	end
	
	return result
end

--- Returns whether a spellbook item has range requirements
--- Will always return false if it is not a spell
--- @param spellBookItemSlotIndex number The slot index in the spellbook (1-based index)
--- @param spellBookItemSpellBank Enum.SpellBookSpellBank The spellbook type:
---   - Enum.SpellBookSpellBank.Player (0) for player spells
---   - Enum.SpellBookSpellBank.Pet (1) for pet spells
--- @return boolean True if the spell has a range, false if:
---   - The spell does not exist
---   - The input is invalid
---   - The spellbook item is not a spell
--- @see https://warcraft.wiki.gg/wiki/API_C_SpellBook.SpellBookItemHasRange
function Lib.SpellBookItemHasRange(spellBookItemSlotIndex, spellBookItemSpellBank)
	-- Validate input parameters
	if type(spellBookItemSlotIndex) ~= "number" or spellBookItemSlotIndex < 1 then 
		return false 
	end
	
	-- Validate spellbank enum
	if spellBookItemSpellBank ~= Enum.SpellBookSpellBank.Player and 
	   spellBookItemSpellBank ~= Enum.SpellBookSpellBank.Pet then
		return false
	end
	
	-- Get spell info to verify it's a valid spell
	local spellInfo = GetSpellBookInfoSafe(spellBookItemSlotIndex, spellBookItemSpellBank)
	if not spellInfo then return false end
	
	-- Verify it's actually a spell type
	if spellInfo.itemType ~= Enum.SpellBookItemType.Spell and 
	   spellInfo.itemType ~= Enum.SpellBookItemType.PetAction then
		return false
	end
	
	-- Check if we have this spell ID cached
	if spellInfo.spellID then
		local cachedInfo = spellInfoCache[spellInfo.spellID]
		if cachedInfo and cachedInfo.hasRange ~= nil then
			return cachedInfo.hasRange
		end
	end
	
	-- Get range info from base API
	local result = SpellBookItemHasRange(spellBookItemSlotIndex, spellBookItemSpellBank)
	
	-- Cache the result if we have a spell ID
	if spellInfo.spellID then
		spellInfoCache[spellInfo.spellID] = {
			hasRange = result,
			timestamp = GetTime(),
			isPetSpell = spellBookItemSpellBank == Enum.SpellBookSpellBank.Pet,
			spellID = spellInfo.spellID
		}
	end
	
	return result
end

-- Initialize pet spells
UpdatePetSpells()