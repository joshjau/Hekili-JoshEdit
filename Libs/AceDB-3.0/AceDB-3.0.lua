--- **AceDB-3.0** manages the SavedVariables of your addon.
-- It offers profile management, smart defaults and namespaces for modules.\\
-- Data can be saved in different data-types, depending on its intended usage.
-- The most common data-type is the `profile` type, which allows the user to choose
-- the active profile, and manage the profiles of all of his characters.\\
-- The following data types are available:
-- * **char** Character-specific data. Every character has its own database.
-- * **realm** Realm-specific data. All of the players characters on the same realm share this database.
-- * **class** Class-specific data. All of the players characters of the same class share this database.
-- * **race** Race-specific data. All of the players characters of the same race share this database.
-- * **faction** Faction-specific data. All of the players characters of the same faction share this database.
-- * **factionrealm** Faction and realm specific data. All of the players characters on the same realm and of the same faction share this database.
-- * **locale** Locale specific data, based on the locale of the players game client.
-- * **global** Global Data. All characters on the same account share this database.
-- * **profile** Profile-specific data. All characters using the same profile share this database. The user can control which profile should be used.
--
-- Creating a new Database using the `:New` function will return a new DBObject. A database will inherit all functions
-- of the DBObjectLib listed here. \\
-- If you create a new namespaced child-database (`:RegisterNamespace`), you'll get a DBObject as well, but note
-- that the child-databases cannot individually change their profile, and are linked to their parents profile - and because of that,
-- the profile related APIs are not available. Only `:RegisterDefaults` and `:ResetProfile` are available on child-databases.
--
-- For more details on how to use AceDB-3.0, see the [[AceDB-3.0 Tutorial]].
--
-- You may also be interested in [[libdualspec-1-0|LibDualSpec-1.0]] to do profile switching automatically when switching specs.
--
-- @usage
-- MyAddon = LibStub("AceAddon-3.0"):NewAddon("DBExample")
--
-- -- declare defaults to be used in the DB
-- local defaults = {
--   profile = {
--     setting = true,
--   }
-- }
--
-- function MyAddon:OnInitialize()
--   -- Assuming the .toc says ## SavedVariables: MyAddonDB
--   self.db = LibStub("AceDB-3.0"):New("MyAddonDB", defaults, true)
-- end
-- @class file
-- @name AceDB-3.0.lua
-- @release $Id: AceDB-3.0.lua 1353 2024-08-27 13:37:35Z nevcairiel $

--[[---------------------------------------------------------------------------
	Library Initialization and Dependencies
	
	This section handles the core library setup including:
	- Version management through LibStub
	- Error message definitions
	- API localization
	- Core dependencies
	
	The library requires:
	- LibStub for versioning
	- CallbackHandler-1.0 for event management (optional)
---------------------------------------------------------------------------]]

--- Error Messages used throughout the library
-- @local
local ERR_NO_PROFILE = "Cannot delete the active profile (%q)."
local ERR_NO_PROFILE_EXISTS = "Cannot delete profile %q as it does not exist."
local ERR_SAME_PROFILE = "Cannot copy profile %q into itself."
local ERR_INVALID_PROFILE = "Invalid profile name. Profile names must be strings."
local ERR_INVALID_DEFAULTS = "'defaults' - table expected got %q."
local ERR_INVALID_PARENT = "Parent database is invalid or corrupt."
local ERR_INVALID_CLASS = "Invalid class identifier returned from API."
local ERR_CLASS_NOT_FOUND = "Unable to determine player class."

--- Library version information
-- @local
local ACEDB_MAJOR, ACEDB_MINOR = "AceDB-3.0", 30
local AceDB = LibStub:NewLibrary(ACEDB_MAJOR, ACEDB_MINOR)

if not AceDB then return end -- No upgrade needed

--- Cache frequently used Lua APIs for better performance
-- @local
local type, pairs, next, error = type, pairs, next, error
local setmetatable, rawset, rawget = setmetatable, rawset, rawget
local format = string.format

--- Cache WoW APIs
-- @local
local _G = _G

--- Database registry to track all AceDB instances
-- @table db_registry
AceDB.db_registry = AceDB.db_registry or {}

--- Main frame for event handling
-- @table frame
AceDB.frame = AceDB.frame or CreateFrame("Frame")

--- Callback handler for database events
-- @local
local CallbackHandler

--- Dummy callback object for when CallbackHandler-1.0 isn't available
-- @table CallbackDummy
local CallbackDummy = {
	Fire = function() end,
	HasCallback = function() return false end,
	RegisterCallback = function() error("Cannot register callbacks on a dummy object.", 2) end,
	UnregisterCallback = function() error("Cannot unregister callbacks on a dummy object.", 2) end,
	UnregisterAllCallbacks = function() error("Cannot unregister callbacks on a dummy object.", 2) end,
}

--- Database object prototype
-- Contains all methods that will be inherited by database instances
-- @table DBObjectLib
local DBObjectLib = {}

-- Lua APIs
local type, pairs, next, error = type, pairs, next, error
local setmetatable, rawset, rawget = setmetatable, rawset, rawget
local format = string.format

-- WoW APIs
local _G = _G

AceDB.db_registry = AceDB.db_registry or {}
AceDB.frame = AceDB.frame or CreateFrame("Frame")

local CallbackHandler
local CallbackDummy = {
	Fire = function() end,
	HasCallback = function() return false end,
	RegisterCallback = function() error("Cannot register callbacks on a dummy object.", 2) end,
	UnregisterCallback = function() error("Cannot unregister callbacks on a dummy object.", 2) end,
	UnregisterAllCallbacks = function() error("Cannot unregister callbacks on a dummy object.", 2) end,
}

local DBObjectLib = {}

--[[-------------------------------------------------------------------------
	AceDB Utility Functions
---------------------------------------------------------------------------]]

-- Simple shallow copy for copying defaults
local function copyTable(src, dest)
	-- Input validation
	if src == nil then return dest end
	if type(src) ~= "table" then
		error("copyTable: source argument must be a table or nil", 2)
	end
	
	-- Initialize destination if needed
	if type(dest) ~= "table" then 
		dest = {} 
	end
	
	-- Cache frequently used functions
	local rawget = rawget
	local rawset = rawset
	local type = type
	local pairs = pairs
	
	-- Perform copy
	for k, v in pairs(src) do
			if type(v) == "table" then
				-- try to index the key first so that the metatable creates the defaults, if set, and use that table
			local existing = rawget(dest, k)
			if existing and type(existing) == "table" then
				v = copyTable(v, existing)
			else
				v = copyTable(v, nil)
			end
		end
		rawset(dest, k, v)
	end
	
	return dest
end

-- Called to add defaults to a section of the database
local function copyDefaults(dest, src)
	-- Validate input parameters
	if type(src) ~= "table" then
		return
	end
	
	-- Ensure dest is a table
	if type(dest) ~= "table" then
		dest = {}
	end
	
	-- Optimization: Cache frequently used functions
	local rawget, rawset = rawget, rawset
	local type = type
	local pairs = pairs
	
	for k, v in pairs(src) do
		if k == "*" or k == "**" then
			if type(v) == "table" then
				-- This is a metatable used for table defaults
				local mt = {
					-- This handles the lookup and creation of new subtables
					__index = function(t, k2)
							if k2 == nil then return nil end
							local tbl = {}
							copyDefaults(tbl, v)
							rawset(t, k2, tbl)
							return tbl
						end,
				}
				setmetatable(dest, mt)
				-- handle already existing tables in the SV
				for dk, dv in pairs(dest) do
					if not rawget(src, dk) and type(dv) == "table" then
						copyDefaults(dv, v)
					end
				end
			else
				-- Values are not tables, so this is just a simple return
				local mt = {
					__index = function(t, k2)
						if k2 == nil then return nil end
						return v
					end
				}
				setmetatable(dest, mt)
			end
		elseif type(v) == "table" then
			if not rawget(dest, k) then
				rawset(dest, k, {})
			end
			if type(dest[k]) == "table" then
				copyDefaults(dest[k], v)
				if src['**'] then
					copyDefaults(dest[k], src['**'])
				end
			end
		else
			if rawget(dest, k) == nil then
				rawset(dest, k, v)
			end
		end
	end
	return dest
end

-- Called to remove all defaults in the default table from the database
local function removeDefaults(db, defaults, blocker)
	-- Validate input parameters
	if type(db) ~= "table" then return end
	if not defaults then return end
	
	-- Optimization: Cache frequently used functions
	local rawget = rawget
	local rawset = rawset
	local type = type
	local pairs = pairs
	local next = next
	
	-- remove all metatables from the db, so we don't accidentally create new sub-tables through them
	setmetatable(db, nil)
	
	-- loop through the defaults and remove their content
	for k, v in pairs(defaults) do
		if k == "*" or k == "**" then
			if type(v) == "table" then
				-- Loop through all the actual k,v pairs and remove
				for key, value in pairs(db) do
					if type(value) == "table" then
						-- if the key was not explicitly specified in the defaults table, just strip everything from * and ** tables
						if defaults[key] == nil and (not blocker or blocker[key] == nil) then
							removeDefaults(value, v)
							-- if the table is empty afterwards, remove it
							if not next(value) then
								db[key] = nil
							end
						-- if it was specified, only strip ** content, but block values which were set in the key table
						elseif k == "**" then
							removeDefaults(value, v, defaults[key])
						end
					end
				end
			elseif k == "*" then
				-- check for non-table default
				for key, value in pairs(db) do
					if defaults[key] == nil and v == value then
						db[key] = nil
					end
				end
			end
		elseif type(v) == "table" and type(db[k]) == "table" then
			-- if a blocker was set, dive into it, to allow multi-level defaults
			removeDefaults(db[k], v, blocker and blocker[k])
			if not next(db[k]) then
				db[k] = nil
			end
		else
			-- check if the current value matches the default, and that its not blocked by another defaults table
			if db[k] == defaults[k] and (not blocker or blocker[k] == nil) then
				db[k] = nil
			end
		end
	end
end

-- This is called when a table section is first accessed, to set up the defaults
local function initSection(db, section, svstore, key, defaults)
	local sv = rawget(db, "sv")

	local tableCreated
	if not sv[svstore] then sv[svstore] = {} end
	if not sv[svstore][key] then
		sv[svstore][key] = {}
		tableCreated = true
	end

	local tbl = sv[svstore][key]

	if defaults then
		copyDefaults(tbl, defaults)
	end
	rawset(db, section, tbl)

	return tableCreated, tbl
end

-- Metatable to handle the dynamic creation of sections and copying of sections.
local dbmt = {
	__index = function(t, section)
			local keys = rawget(t, "keys")
			local key = keys[section]
			if key then
				local defaultTbl = rawget(t, "defaults")
				local defaults = defaultTbl and defaultTbl[section]

				if section == "profile" then
					local new = initSection(t, section, "profiles", key, defaults)
					if new then
						-- Callback: OnNewProfile, database, newProfileKey
						t.callbacks:Fire("OnNewProfile", t, key)
					end
				elseif section == "profiles" then
					local sv = rawget(t, "sv")
					if not sv.profiles then sv.profiles = {} end
					rawset(t, "profiles", sv.profiles)
				elseif section == "global" then
					local sv = rawget(t, "sv")
					if not sv.global then sv.global = {} end
					if defaults then
						copyDefaults(sv.global, defaults)
					end
					rawset(t, section, sv.global)
				else
					initSection(t, section, section, key, defaults)
				end
			end

			return rawget(t, section)
		end
}

local function validateDefaults(defaults, keyTbl, offset)
	if not defaults then return end
	offset = offset or 0
	for k in pairs(defaults) do
		if not keyTbl[k] or k == "profiles" then
			error(("Usage: AceDBObject:RegisterDefaults(defaults): '%s' is not a valid datatype."):format(k), 3 + offset)
		end
	end
end

local preserve_keys = {
	["callbacks"] = true,
	["RegisterCallback"] = true,
	["UnregisterCallback"] = true,
	["UnregisterAllCallbacks"] = true,
	["children"] = true,
}

-- Cached realm information for performance
local cachedRealmInfo = {
    name = nil,
    normalized = nil,
    lastUpdate = 0
}

-- Player name handling with proper realm support
local function GetFullPlayerName()
    local name, realm = UnitName("player")
    if not name then return "Unknown" end
    
    -- If no realm was returned, use current realm
    if not realm then
        -- Try C_RealmList first (modern API)
        if C_RealmList and C_RealmList.GetRealmName then
            realm = C_RealmList.GetRealmName()
        else
            realm = GetRealmName() or "Unknown Realm"
        end
    end
    
    -- Return the full name-realm format
    -- Use proper format for cross-realm names
    return name .. " - " .. realm
end

-- Get realm key with connected realm support
local realmKey = (function()
    -- Get player's realm first
    local _, playerRealm = UnitName("player")
    
    -- If no realm returned, try other methods
    if not playerRealm then
        if C_RealmList and C_RealmList.GetRealmName then
            playerRealm = C_RealmList.GetRealmName()
        else
            playerRealm = GetRealmName()
        end
    end
    
    -- Check for connected realms
    local connectedRealms = GetAutoCompleteRealms()
    if connectedRealms and #connectedRealms > 0 then
        -- Sort realm names for consistent keys across connected realms
        table.sort(connectedRealms)
        return table.concat(connectedRealms, "+")
    end
    
    return playerRealm or "Unknown Realm"
end)()

local charKey = GetFullPlayerName()

-- Class ID mapping for validation and conversion
local CLASS_IDS = {
    WARRIOR = 1,     -- Added in 1.0.0
    PALADIN = 2,     -- Added in 1.0.0
    HUNTER = 3,      -- Added in 1.0.0
    ROGUE = 4,       -- Added in 1.0.0
    PRIEST = 5,      -- Added in 1.0.0
    DEATHKNIGHT = 6, -- Added in 3.0.2
    SHAMAN = 7,      -- Added in 1.0.0
    MAGE = 8,        -- Added in 1.0.0
    WARLOCK = 9,     -- Added in 1.0.0
    MONK = 10,       -- Added in 5.0.4
    DRUID = 11,      -- Added in 1.0.0
    DEMONHUNTER = 12,-- Added in 7.0.3
    EVOKER = 13,     -- Added in 10.0.0
}

-- Reverse lookup table for validation
local CLASS_TOKENS = {}
for token, id in pairs(CLASS_IDS) do
    CLASS_TOKENS[id] = token
end

--- Get player class information with proper validation and error handling
-- @return classToken The class token (e.g., "WARRIOR", "MAGE")
-- @return className The localized class name
-- @return classId The numeric class identifier (1-13)
local function GetPlayerClass()
    -- Use UnitClassBase for internal class token
    local classToken = UnitClassBase("player")
    if not classToken then
        return "UNKNOWN", "Unknown", nil
    end
    
    -- Validate class token against known classes
    if not CLASS_IDS[classToken] then
        error(ERR_INVALID_CLASS)
    end
    
    -- Get localized class name, token, and ID
    local className, classToken, classId = UnitClass("player")
    if not className then
        -- Fallback to base token if localized name unavailable
        -- Use mapped class ID as fallback
        return classToken, classToken, CLASS_IDS[classToken]
    end
    
    -- Validate class ID
    if not classId or classId < 1 or classId > 13 then
        classId = CLASS_IDS[classToken] -- Fallback to mapped ID
        if not classId then
            error(ERR_CLASS_NOT_FOUND)
        end
    end
    
    -- Validate that token matches ID
    if CLASS_IDS[classToken] ~= classId then
        -- If there's a mismatch, trust the token over the ID
        -- This handles cases where the API might return inconsistent data
        classId = CLASS_IDS[classToken]
    end
    
    -- Final validation that everything matches
    if classId and CLASS_TOKENS[classId] ~= classToken then
        error(format("Class token/ID mismatch: %s != %d", classToken, classId))
    end
    
    return classToken, className, classId
end

local classKey, className, classId = GetPlayerClass()

-- Get player race information with proper localization
local function GetPlayerRace()
    local localizedRaceName, englishRaceName, raceID = UnitRace("player")
    if not localizedRaceName then
        error("Unable to determine player race")
    end
    
    -- Use the English race name as the key for consistency
    -- This ensures the same key is used regardless of client locale
    return englishRaceName
end

-- Update race key with proper race detection
local raceKey = GetPlayerRace()

local factionKey = UnitFactionGroup("player")
local factionrealmKey = factionKey .. " - " .. realmKey
local localeKey = (GetLocale() or "enUS"):lower()

-- Region detection with proper API usage
local regionTable = { "US", "KR", "EU", "TW", "CN" }
local regionKey = (C_RealmList and C_RealmList.GetCurrentRegionName()) or 
                 regionTable[GetCurrentRegion()] or 
                 GetCurrentRegionName() or 
                 "TR"
local factionrealmregionKey = factionrealmKey .. " - " .. regionKey

-- Enhanced error handling with proper error handler usage
local function SafeError(msg, level)
    level = level or 2 -- Default to 2 levels up (caller's caller)
    local handler = geterrorhandler()
    if type(handler) == "function" then
        -- Strip debug info for cleaner messages
        if type(msg) == "string" then
            msg = msg:gsub("^%[string .-%]:%d+: ", "")
        end
        handler(msg)
    else
        error(msg, level)
    end
end

-- Safe callback firing helper with improved error handling
local function SafeFireCallback(callbacks, event, ...)
    if type(callbacks) ~= "table" then return end
    if type(callbacks.Fire) ~= "function" then return end
    
    -- Protected call to avoid callback errors breaking the addon
    local success, err = pcall(callbacks.Fire, callbacks, event, ...)
    if not success then
        SafeError(format("AceDB-3.0: Error in callback for %s: %s", event, err))
    end
end

-- Profile version tracking and migration support
local function migrateProfile(db, profile, version)
	if not profile or not version then return end
	
	-- Store current version in profile
	if not profile.__version then
		profile.__version = version
		return
	end
	
	-- Check if migration is needed
	if profile.__version >= version then return end
	
	-- Fire migration callback to allow addons to update data
	SafeFireCallback(db.callbacks, "OnProfileMigration", db, profile, profile.__version, version)
	
	-- Update version
	profile.__version = version
end

-- Add version support to initdb
local function initdb(sv, defaults, defaultProfile, olddb, parent, version)
	-- Validate input parameters
	if type(sv) ~= "table" then
		error(("Usage: initdb(sv, defaults, defaultProfile, olddb, parent): 'sv' - table expected, got %q."):format(type(sv)), 2)
	end
	
	-- Generate the database keys for each section
	-- map "true" to our "Default" profile
	if defaultProfile == true then defaultProfile = "Default" end

	local profileKey
	if not parent then
		-- Make a container for profile keys
		sv.profileKeys = sv.profileKeys or {}

		-- Try to get the profile selected from the char db
		profileKey = sv.profileKeys[charKey] or defaultProfile or charKey

		-- save the selected profile for later
		sv.profileKeys[charKey] = profileKey
	else
		-- Use the profile of the parents DB
		profileKey = parent.keys and parent.keys.profile or defaultProfile or charKey

		-- clear the profileKeys in the DB, namespaces don't need to store them
		sv.profileKeys = nil
	end

	-- This table contains keys that enable the dynamic creation
	-- of each section of the table.
	local keyTbl = {
		["char"] = charKey,
		["realm"] = realmKey,
		["class"] = classKey,
		["race"] = raceKey,
		["faction"] = factionKey,
		["factionrealm"] = factionrealmKey,
		["factionrealmregion"] = factionrealmregionKey,
		["profile"] = profileKey,
		["locale"] = localeKey,
		["global"] = true,
		["profiles"] = true,
	}

	validateDefaults(defaults, keyTbl, 1)

	-- This allows us to use this function to reset an entire database
	-- Clear out the old database
	if olddb then
		for k,v in pairs(olddb) do 
			if not preserve_keys[k] then 
				olddb[k] = nil 
			end 
		end
	end

	-- Give this database the metatable so it initializes dynamically
	local db = setmetatable(olddb or {}, dbmt)

	if not rawget(db, "callbacks") then
		-- try to load CallbackHandler-1.0 if it loaded after our library
		if not CallbackHandler then 
			CallbackHandler = LibStub:GetLibrary("CallbackHandler-1.0", true) 
		end
		db.callbacks = CallbackHandler and CallbackHandler:New(db) or CallbackDummy
	end

	-- Copy methods locally into the database object, to avoid hitting
	-- the metatable when calling methods
	if not parent then
		for name, func in pairs(DBObjectLib) do
			if type(func) == "function" then
			db[name] = func
			end
		end
	else
		-- hack this one in
		db.RegisterDefaults = DBObjectLib.RegisterDefaults
		db.ResetProfile = DBObjectLib.ResetProfile
	end

	-- Set some properties in the database object
	db.profiles = sv.profiles
	db.keys = keyTbl
	db.sv = sv
	db.defaults = defaults
	db.parent = parent
	db.classId = classId -- Store class ID for reference

	-- store the DB in the registry
	AceDB.db_registry[db] = true
	
	-- Handle profile migration if version specified
	if version and type(version) == "number" then
		db.version = version
		if db.profile then
			migrateProfile(db, db.profile, version)
		end
	end

	return db
end

-- handle PLAYER_LOGOUT
-- strip all defaults from all databases
-- and cleans up empty sections
local function logoutHandler(frame, event)
	if event == "PLAYER_LOGOUT" then
		for db in pairs(AceDB.db_registry) do
			SafeFireCallback(db.callbacks, "OnDatabaseShutdown", db)
			db:RegisterDefaults(nil)

			-- cleanup sections that are empty without defaults
			local sv = rawget(db, "sv")
			for section in pairs(db.keys) do
				if rawget(sv, section) then
					-- global is special, all other sections have sub-entrys
					-- also don't delete empty profiles on main dbs, only on namespaces
					if section ~= "global" and (section ~= "profiles" or rawget(db, "parent")) then
						for key in pairs(sv[section]) do
							if not next(sv[section][key]) then
								sv[section][key] = nil
							end
						end
					end
					if not next(sv[section]) then
						sv[section] = nil
					end
				end
			end
		end
	end
end

-- Frame creation and cleanup
if not AceDB.frame then
    -- Create frame with modern template support
    AceDB.frame = CreateFrame("Frame", "AceDB30Frame", UIParent, BackdropTemplateMixin and "BackdropTemplate")
    
    -- Enhanced event handling with proper initialization order
    local function InitializeDatabase(db)
        if not db.initialized then
            -- Initialize database before firing callback
            if db.defaults then
                db:RegisterDefaults(db.defaults)
            end
            
            -- Fire initialization callback
            SafeFireCallback(db.callbacks, "OnDatabaseInitialized", db)
            db.initialized = true
            
            -- Handle any pending profile migrations
            if db.version and db.profile then
                migrateProfile(db, db.profile, db.version)
            end
        end
    end
    
    -- Event handler with proper error context
    local function OnEvent(self, event, ...)
        if event == "PLAYER_LOGOUT" then
            logoutHandler(self, event)
            cleanupHandler()
        elseif event == "ADDON_LOADED" then
            -- Handle addon loading
            local addon = ...
            if AceDB.db_registry[addon] then
                SafeFireCallback(AceDB.db_registry[addon].callbacks, "OnDatabaseLoaded", addon)
            end
        elseif event == "PLAYER_LOGIN" then
            -- Initialize all pending databases at login
            -- This ensures proper timing before PLAYER_ENTERING_WORLD
            for db in pairs(AceDB.db_registry) do
                InitializeDatabase(db)
            end
        end
    end
    
    --[[---------------------------------------------------------------------------
    Event Registration and Handling System
    
    This section manages event registration and handling for the AceDB frame.
    It supports both regular events and unit-specific events with proper validation
    and error handling.
    ---------------------------------------------------------------------------]]

    --- Table of valid events that can be registered
    -- These are the core events required for AceDB functionality
    local validEvents = {
        ADDON_LOADED = true,  -- Fired when an addon is loaded, used for initialization
        PLAYER_LOGIN = true,  -- Fired at login, used for database setup
        PLAYER_LOGOUT = true  -- Fired at logout, used for cleanup
    }

    --- Table of events that require unit-specific registration
    -- These events need special handling with RegisterUnitEvent
    local unitEvents = {
        --[[---------------------------------------------------------------------------
        Unit Health Events
        ---------------------------------------------------------------------------]]
        
        --- Fired when a unit's current health changes
        -- @event UNIT_HEALTH
        -- @unitsubevent true
        -- @see UnitHealth
        UNIT_HEALTH = true,
        
        --- Fired when a unit's maximum health changes
        -- @event UNIT_MAXHEALTH
        -- @unitsubevent true
        -- @see UnitHealthMax
        UNIT_MAXHEALTH = true,
        
        --[[---------------------------------------------------------------------------
        Unit Power Events
        ---------------------------------------------------------------------------]]
        
        --- Fired when a unit's power (mana, rage, energy, etc.) changes
        -- @event UNIT_POWER_UPDATE
        -- @unitsubevent true
        -- @see UnitPower
        UNIT_POWER_UPDATE = true,
        
        --- Fired when a unit's maximum power changes
        -- @event UNIT_MAXPOWER
        -- @unitsubevent true
        -- @see UnitPowerMax
        UNIT_MAXPOWER = true,
        
        --- Fired when a unit's power type changes (e.g., druid form changes)
        -- @event UNIT_DISPLAYPOWER
        -- @unitsubevent true
        -- @see UnitPowerType
        UNIT_DISPLAYPOWER = true,
        
        --[[---------------------------------------------------------------------------
        Unit Spellcast Events
        ---------------------------------------------------------------------------]]
        
        --- Fired when a unit begins casting a spell
        -- @event UNIT_SPELLCAST_START
        -- @unitsubevent true
        -- @see C_Spell.GetSpellCooldown
        UNIT_SPELLCAST_START = true,
        
        --- Fired when a unit's spellcast is interrupted or stopped
        -- @event UNIT_SPELLCAST_STOP
        -- @unitsubevent true
        -- @see C_Spell.IsSpellUsable
        UNIT_SPELLCAST_STOP = true,
        
        --- Fired when a unit successfully completes casting a spell
        -- @event UNIT_SPELLCAST_SUCCEEDED
        -- @unitsubevent true
        -- @see C_Spell.GetSpellInfo
        UNIT_SPELLCAST_SUCCEEDED = true,
        
        --- Fired when a unit's spellcast fails
        -- @event UNIT_SPELLCAST_FAILED
        -- @unitsubevent true
        -- @see C_Spell.IsSpellInRange
        UNIT_SPELLCAST_FAILED = true
    }

    --[[---------------------------------------------------------------------------
    Event Registration System
    
    Handles the registration of events for the AceDB frame with proper validation,
    error handling, and support for both regular and unit events.
    
    The registration process:
    1. Validates event names and types
    2. Handles unit-specific events appropriately
    3. Verifies registration success
    4. Provides detailed error reporting
    
    Unit Event Handling:
    - Unit events require special registration via RegisterUnitEvent
    - Only specific units can be registered (e.g., "player", "target")
    - Events are validated against the unitEvents table
    - Proper error handling for invalid unit targets
    ---------------------------------------------------------------------------]]

    --- Registers events for the AceDB frame with comprehensive validation and error handling.
    -- This function manages both regular events and unit-specific events, ensuring proper
    -- registration and providing detailed error feedback.
    -- @param frame The frame to register events on
    -- @param ... List of event names to register
    -- @return table Table of successfully registered events, or nil if registration failed
    -- @usage
    -- local events = RegisterEvents(frame, "ADDON_LOADED", "PLAYER_LOGIN")
    -- if not events then
    --     -- Handle registration failure
    -- end
    local function RegisterEvents(frame, ...)
        -- Track registration status for all events
        local registeredEvents = {}
        
        -- First pass: Unregister any existing events to ensure clean state
        for event in pairs(validEvents) do
            local isRegistered = frame:IsEventRegistered(event)
            if isRegistered then
                -- Unregister existing events to prevent duplicate registrations
                frame:UnregisterEvent(event)
            end
        end
        
        -- Second pass: Register events in proper order
        for i = 1, select("#", ...) do
            local event = select(i, ...)
            
            -- Validate event name type
            if type(event) ~= "string" then
                SafeError(format("AceDB-3.0: Invalid event name type: %s", type(event)))
                return
            end
            
            -- Validate event exists in our valid events list
            if not validEvents[event] then
                SafeError(format("AceDB-3.0: Attempt to register invalid event: %s", event))
                return
            end
            
            -- Additional validation for unit events
            if unitEvents[event] then
                -- Ensure player unit exists before registering unit events
                if not UnitExists("player") then
                    SafeError(format("AceDB-3.0: Cannot register unit event %s - player unit does not exist", event))
                    return
                end
            end
            
            -- Handle registration based on event type
            local success
            if unitEvents[event] then
                -- RegisterUnitEvent returns true if newly registered, false if already registered
                success = frame:RegisterUnitEvent(event, "player")
            else
                -- RegisterEvent returns true if newly registered, false if already registered
                success = frame:RegisterEvent(event)
            end
            
            -- Verify registration success with detailed error handling
            if not success then
                -- Check if event is already registered (which is okay)
                if frame:IsEventRegistered(event) then
                    -- Event was already registered, this is expected in some cases
                    registeredEvents[event] = true
                else
                    -- Registration failed for an unexpected reason
                    SafeError(format("AceDB-3.0: Failed to register event %s (event may be invalid or frame may be restricted)", event))
                    return
                end
            else
                -- Registration was successful
                registeredEvents[event] = true
            end
        end
        
        return registeredEvents
    end

    --[[---------------------------------------------------------------------------
    Event Handler Setup
    
    Sets up the event handler for the AceDB frame with proper error handling
    and nil event protection.
    ---------------------------------------------------------------------------]]

    -- Set up the event handler with comprehensive error handling
    if type(OnEvent) == "function" then
        AceDB.frame:SetScript("OnEvent", function(self, event, ...)
            -- Guard against nil events for safety
            if not event then return end
            
            -- Execute event handler with error protection
            local success, err = pcall(OnEvent, self, event, ...)
            if not success then
                SafeError(format("AceDB-3.0: Error in event handler for %s: %s", event, err))
            end
        end)
    end
    
    --[[---------------------------------------------------------------------------
    Core Event Registration
    
    Registers the core events required for AceDB functionality in the correct order.
    The order is critical for proper database initialization and cleanup.
    ---------------------------------------------------------------------------]]

    -- Register core events in proper order with error handling
    -- Order is important:
    -- 1. ADDON_LOADED - Must be first to handle initialization
    -- 2. PLAYER_LOGIN - Must be before PLAYER_ENTERING_WORLD for proper DB init
    -- 3. PLAYER_LOGOUT - Must be last for proper cleanup
    local registeredEvents = RegisterEvents(AceDB.frame, 
        "ADDON_LOADED",  -- Handles addon initialization
        "PLAYER_LOGIN",  -- Handles database initialization
        "PLAYER_LOGOUT"  -- Handles database cleanup
    )
    
    -- Verify core event registration success
    if not registeredEvents or not next(registeredEvents) then
        SafeError("AceDB-3.0: Failed to register core events")
    end

    --[[---------------------------------------------------------------------------
    Cleanup System
    
    Handles the cleanup of frames, events, and database objects during addon shutdown.
    This system ensures proper cleanup of all resources to prevent memory leaks and
    maintain addon stability.
    
    The cleanup process occurs in three main stages:
    1. Frame cleanup - Unregisters events and clears scripts
    2. Event cleanup - Ensures all events are properly unregistered
    3. Database cleanup - Cleans up database objects and fires shutdown callbacks
    ---------------------------------------------------------------------------]]

    --- Enhanced cleanup handler with comprehensive error handling and resource cleanup
    -- This function manages the complete shutdown process for AceDB, ensuring all
    -- resources are properly released and cleaned up.
    -- @local
    local function cleanupHandler()
        if not AceDB.frame then return end
        
        --[[---------------------------------------------------------------------------
        Protected Cleanup Function
        
        Handles the safe cleanup of frame resources with proper error handling and
        validation at each step of the process.
        ---------------------------------------------------------------------------]]
        
        --- Performs protected cleanup operations on a frame
        -- @param frame The frame to clean up
        -- @local
        local function SafeCleanup(frame)
            -- Verify frame has events to clean up
            local hasEvents, units = frame:IsEventRegistered("PLAYER_LOGOUT")
            if hasEvents then
                -- Track failed unregistrations for error reporting
                local failedEvents = {}
                
                -- First pass: Unregister events individually for proper cleanup
                for event in pairs(validEvents) do
                    local isRegistered, eventUnits = frame:IsEventRegistered(event)
                    if isRegistered then
                        if unitEvents[event] then
                            -- Handle unit event cleanup
                            if eventUnits then
                                for _, unit in ipairs(eventUnits) do
                                    local success = frame:UnregisterEvent(event, unit)
                                    if not success then
                                        failedEvents[#failedEvents + 1] = format("%s (%s)", event, unit)
                                    end
                                end
                            end
                        else
                            -- Handle regular event cleanup
                            local success = frame:UnregisterEvent(event)
                            if not success then
                                failedEvents[#failedEvents + 1] = event
                            end
                        end
                    end
                end
                
                -- Report any events that failed to unregister
                if #failedEvents > 0 then
                    SafeError(format("AceDB-3.0: Failed to unregister events: %s", 
                        table.concat(failedEvents, ", ")))
                end
                
                -- Second pass: Complete cleanup with UnregisterAllEvents
                -- This ensures no events remain even if individual unregistration failed
                frame:UnregisterAllEvents()
                
                -- Verification pass: Check all events were properly unregistered
                for event in pairs(validEvents) do
                    if frame:IsEventRegistered(event) then
                        SafeError(format("AceDB-3.0: Event %s remains registered after cleanup", event))
                    end
                end
                
                -- Final pass: Clear all script handlers
                -- Only clear scripts that exist and are currently set
                local scriptTypes = {
                    "OnEvent",   -- Event handling script
                    "OnUpdate",  -- Frame update script
                    "OnShow",    -- Frame show script
                    "OnHide"     -- Frame hide script
                }
                
                for _, scriptType in ipairs(scriptTypes) do
                    if frame:HasScript(scriptType) then
                        -- Verify script is actually set before clearing
                        if frame:GetScript(scriptType) then
                            frame:SetScript(scriptType, nil)
                        end
                    end
                end
            end
        end
        
        -- Execute frame cleanup with error protection
        local success, err = pcall(SafeCleanup, AceDB.frame)
        if not success then
            SafeError(format("AceDB-3.0: Error during frame cleanup: %s", err))
        end
        
        --[[---------------------------------------------------------------------------
        Database Registry Cleanup
        
        Handles the cleanup of all registered database objects, ensuring proper
        shutdown callbacks are fired and resources are released.
        ---------------------------------------------------------------------------]]
        
        -- Clean up all registered databases
        for db in pairs(AceDB.db_registry) do
            local success, err = pcall(function()
                -- Fire shutdown callback to allow addons to clean up
                SafeFireCallback(db.callbacks, "OnDatabaseShutdown", db)
                
                -- Clear defaults to prevent memory leaks
                if db.defaults then
                    db:RegisterDefaults(nil)
                end
                
                -- Remove from registry
                AceDB.db_registry[db] = nil
            end)
            if not success then
                SafeError(format("AceDB-3.0: Error in database cleanup for %s: %s", 
                    db.name or "unnamed", err))
            end
        end
    end
end

--[[-------------------------------------------------------------------------
	AceDB Object Method Definitions
	
	This section contains all the methods that can be called on a database object.
	These methods handle profile management, defaults, and database operations.
	
	Key Features:
	- Profile Management (creation, deletion, copying)
	- Defaults Handling (registration, removal)
	- Namespace Support (registration, access)
	- Database Reset and Cleanup
---------------------------------------------------------------------------]]

--- Sets the defaults table for the given database object by clearing any
-- that are currently set, and then setting the new defaults.
-- @param defaults A table of defaults for this database
-- @usage
-- -- Register defaults for all data types
-- local defaults = {
--   profile = {
--     setting = true,
--     color = { r = 1, g = 0, b = 0, a = 1 },
--   },
--   char = {
--     questLog = {},
--   },
--   realm = {
--     auction = {},
--   }
-- }
-- db:RegisterDefaults(defaults)
function DBObjectLib:RegisterDefaults(defaults)
	if defaults and type(defaults) ~= "table" then
		error(("Usage: AceDBObject:RegisterDefaults(defaults): 'defaults' - table or nil expected, got %q."):format(type(defaults)), 2)
	end

	validateDefaults(defaults, self.keys)

	-- Remove any currently set defaults
	if self.defaults then
		for section,key in pairs(self.keys) do
			if self.defaults[section] and rawget(self, section) then
				removeDefaults(self[section], self.defaults[section])
			end
		end
	end

	-- Set the DBObject.defaults table
	self.defaults = defaults

	-- Copy in any defaults, only touching those sections already created
	if defaults then
		for section,key in pairs(self.keys) do
			if defaults[section] and rawget(self, section) then
				copyDefaults(self[section], defaults[section])
			end
		end
	end
end

--[[---------------------------------------------------------------------------
	Profile Management System
	
	Handles all aspects of profile management including:
	- Profile switching
	- Profile copying
	- Profile deletion
	- Profile resetting
	- Profile enumeration
	
	Each operation maintains proper state across child namespaces and
	fires appropriate callbacks to notify of changes.
---------------------------------------------------------------------------]]

--- Changes the profile of the database and all of its namespaces to the
-- supplied named profile. This operation maintains proper state across
-- all child namespaces and handles cleanup of the old profile.
-- @param name The name of the profile to set as the current profile
-- @usage
-- -- Switch to a shared "Default" profile
-- db:SetProfile("Default")
-- 
-- -- Switch to a character-specific profile
-- db:SetProfile(UnitName("player"))
function DBObjectLib:SetProfile(name)
	if type(name) ~= "string" then
		error(("Usage: AceDBObject:SetProfile(name): 'name' - string expected, got %q."):format(type(name)), 2)
	end

	-- changing to the same profile, dont do anything
	if name == self.keys.profile then return end

	local oldProfile = self.profile
	local defaults = self.defaults and self.defaults.profile

	-- Callback: OnProfileShutdown, database
	self.callbacks:Fire("OnProfileShutdown", self)

	if oldProfile and defaults then
		-- Remove the defaults from the old profile
		removeDefaults(oldProfile, defaults)
	end

	self.profile = nil
	self.keys["profile"] = name

	-- if the storage exists, save the new profile
	-- this won't exist on namespaces.
	if self.sv.profileKeys then
		self.sv.profileKeys[charKey] = name
	end

	-- populate to child namespaces
	if self.children then
		for _, db in pairs(self.children) do
			DBObjectLib.SetProfile(db, name)
		end
	end

	-- Handle migration for new profile
	if self.version then
		migrateProfile(self, self.profile, self.version)
	end

	-- Callback: OnProfileChanged, database, newProfileKey
	self.callbacks:Fire("OnProfileChanged", self, name)
end

--- Returns a table with the names of the existing profiles in the database.
-- You can optionally supply a table to re-use for this purpose.
-- @param tbl A table to store the profile names in (optional)
-- @return table A table containing profile names (either the supplied table or a new one)
-- @return number The number of profiles
-- @usage
-- -- Get all profiles
-- local profiles = db:GetProfiles()
-- for i, profileName in ipairs(profiles) do
--     print(profileName)
-- end
--
-- -- Reuse an existing table
-- local profileList = {}
-- db:GetProfiles(profileList)
function DBObjectLib:GetProfiles(tbl)
	if tbl and type(tbl) ~= "table" then
		error(("Usage: AceDBObject:GetProfiles(tbl): 'tbl' - table or nil expected, got %q."):format(type(tbl)), 2)
	end

	-- Clear the container table
	if tbl then
		for k,v in pairs(tbl) do tbl[k] = nil end
	else
		tbl = {}
	end

	local curProfile = self.keys.profile

	local i = 0
	for profileKey in pairs(self.profiles) do
		i = i + 1
		tbl[i] = profileKey
		if curProfile and profileKey == curProfile then curProfile = nil end
	end

	-- Add the current profile, if it hasn't been created yet
	if curProfile then
		i = i + 1
		tbl[i] = curProfile
	end

	return tbl, i
end

--- Returns the current profile name used by the database
-- @return string The current profile name
-- @usage
-- local currentProfile = db:GetCurrentProfile()
-- print("Current profile:", currentProfile)
function DBObjectLib:GetCurrentProfile()
	return self.keys.profile
end

--- Deletes a named profile. This profile must not be the active profile.
-- The deletion will be propagated to all child namespaces.
-- @param name The name of the profile to be deleted
-- @param silent If true, do not raise an error when the profile does not exist
-- @usage
-- -- Delete the "OldProfile" profile
-- db:DeleteProfile("OldProfile")
--
-- -- Silently delete a profile that might not exist
-- db:DeleteProfile("MaybeProfile", true)
function DBObjectLib:DeleteProfile(name, silent)
	if type(name) ~= "string" then
		error(ERR_INVALID_PROFILE, 2)
	end

	if self.keys.profile == name then
		error(format(ERR_NO_PROFILE, name), 2)
	end

	if not rawget(self.profiles, name) and not silent then
		error(format(ERR_NO_PROFILE_EXISTS, name), 2)
	end

	self.profiles[name] = nil

	-- populate to child namespaces
	if self.children then
		for _, db in pairs(self.children) do
			DBObjectLib.DeleteProfile(db, name, true)
		end
	end

	-- remove from unloaded namespaces
	if self.sv.namespaces then
		for nsname, data in pairs(self.sv.namespaces) do
			if self.children and self.children[nsname] then
				-- already a mapped namespace
			elseif data.profiles then
				data.profiles[name] = nil
			end
		end
	end

	-- Callback: OnProfileDeleted
	self.callbacks:Fire("OnProfileDeleted", self, name)
end

--- Copies a named profile into the current profile, overwriting any conflicting
-- settings. The copy will be propagated to all child namespaces.
-- @param name The name of the profile to be copied into the current profile
-- @param silent If true, do not raise an error when the profile does not exist
-- @usage
-- -- Copy "Default" profile into current profile
-- db:CopyProfile("Default")
function DBObjectLib:CopyProfile(name, silent)
	if type(name) ~= "string" then
		error(("Usage: AceDBObject:CopyProfile(name): 'name' - string expected, got %q."):format(type(name)), 2)
	end

	if name == self.keys.profile then
		error(("Cannot have the same source and destination profiles (%q)."):format(name), 2)
	end

	if not rawget(self.profiles, name) and not silent then
		error(("Cannot copy profile %q as it does not exist."):format(name), 2)
	end

	-- Reset the profile before copying
	DBObjectLib.ResetProfile(self, nil, true)

	local profile = self.profile
	local source = self.profiles[name]

	copyTable(source, profile)

	-- populate to child namespaces
	if self.children then
		for _, db in pairs(self.children) do
			DBObjectLib.CopyProfile(db, name, true)
		end
	end

	-- copy unloaded namespaces
	if self.sv.namespaces then
		for nsname, data in pairs(self.sv.namespaces) do
			if self.children and self.children[nsname] then
				-- already a mapped namespace
			elseif data.profiles then
				-- reset the current profile
				data.profiles[self.keys.profile] = {}
				-- copy data
				copyTable(data.profiles[name], data.profiles[self.keys.profile])
			end
		end
	end

	-- Callback: OnProfileCopied, database, sourceProfileKey
	self.callbacks:Fire("OnProfileCopied", self, name)
end

--- Resets the current profile to the default values (if specified).
-- The reset will be propagated to all child namespaces.
-- @param noChildren if set to true, the reset will not be populated to the child namespaces of this DB object
-- @param noCallbacks if set to true, won't fire the OnProfileReset callback
-- @usage
-- -- Reset the current profile
-- db:ResetProfile()
--
-- -- Reset current profile without affecting children
-- db:ResetProfile(true)
function DBObjectLib:ResetProfile(noChildren, noCallbacks)
	local profile = self.profile

	for k,v in pairs(profile) do
		profile[k] = nil
	end

	local defaults = self.defaults and self.defaults.profile
	if defaults then
		copyDefaults(profile, defaults)
	end

	-- populate to child namespaces
	if self.children and not noChildren then
		for _, db in pairs(self.children) do
			DBObjectLib.ResetProfile(db, nil, noCallbacks)
		end
	end

	-- reset unloaded namespaces
	if self.sv.namespaces and not noChildren then
		for nsname, data in pairs(self.sv.namespaces) do
			if self.children and self.children[nsname] then
				-- already a mapped namespace
			elseif data.profiles then
				-- reset the current profile
				data.profiles[self.keys.profile] = nil
			end
		end
	end

	-- Callback: OnProfileReset, database
	if not noCallbacks then
		self.callbacks:Fire("OnProfileReset", self)
	end
end

--[[---------------------------------------------------------------------------
	Database Reset and Namespace Management
	
	Provides functionality for:
	- Complete database reset
	- Namespace registration
	- Namespace access
	- Child database management
---------------------------------------------------------------------------]]

--- Resets the entire database, using the string defaultProfile as the new default
-- profile. This will remove ALL data from ALL profiles and namespaces.
-- @param defaultProfile The profile name to use as the default
-- @return The database object
-- @usage
-- -- Reset the entire DB and use "Default" as default profile
-- db:ResetDB("Default")
function DBObjectLib:ResetDB(defaultProfile)
	if defaultProfile and type(defaultProfile) ~= "string" and defaultProfile ~= true then
		error(("Usage: AceDBObject:ResetDB(defaultProfile): 'defaultProfile' - string or true expected, got %q."):format(type(defaultProfile)), 2)
	end

	local sv = self.sv
	for k,v in pairs(sv) do
		sv[k] = nil
	end

	initdb(sv, self.defaults, defaultProfile, self)

	-- fix the child namespaces
	if self.children then
		if not sv.namespaces then sv.namespaces = {} end
		for name, db in pairs(self.children) do
			if not sv.namespaces[name] then sv.namespaces[name] = {} end
			initdb(sv.namespaces[name], db.defaults, self.keys.profile, db, self)
		end
	end

	-- Callback: OnDatabaseReset, database
	self.callbacks:Fire("OnDatabaseReset", self)
	-- Callback: OnProfileChanged, database, profileKey
	self.callbacks:Fire("OnProfileChanged", self, self.keys["profile"])

	return self
end

--- Creates a new database namespace, directly tied to the database.
-- A namespace is a full database in its own right other than the fact that
-- it cannot control its profile individually.
-- @param name The name of the new namespace
-- @param defaults A table of values to use as defaults
-- @return The new namespace object
-- @usage
-- -- Create a namespace for handling UI settings
-- local UI = db:RegisterNamespace("UI", {
--     profile = {
--         framePoint = "CENTER",
--         frameSize = { width = 100, height = 100 }
--     }
-- })
function DBObjectLib:RegisterNamespace(name, defaults)
	if type(name) ~= "string" then
		error(("Usage: AceDBObject:RegisterNamespace(name, defaults): 'name' - string expected, got %q."):format(type(name)), 2)
	end
	if defaults and type(defaults) ~= "table" then
		error(("Usage: AceDBObject:RegisterNamespace(name, defaults): 'defaults' - table or nil expected, got %q."):format(type(defaults)), 2)
	end
	if self.children and self.children[name] then
		error(("Usage: AceDBObject:RegisterNamespace(name, defaults): 'name' - a namespace called %q already exists."):format(name), 2)
	end

	local sv = self.sv
	if not sv.namespaces then sv.namespaces = {} end
	if not sv.namespaces[name] then
		sv.namespaces[name] = {}
	end

	local newDB = initdb(sv.namespaces[name], defaults, self.keys.profile, nil, self)

	if not self.children then self.children = {} end
	self.children[name] = newDB
	return newDB
end

--- Returns an already existing namespace from the database object.
-- @param name The name of the namespace
-- @param silent If true, the namespace is optional, silently return nil if its not found
-- @return The namespace object if found
-- @usage
-- -- Get the UI namespace
-- local UI = db:GetNamespace('UI')
--
-- -- Silently check for an optional namespace
-- local optional = db:GetNamespace('Optional', true)
function DBObjectLib:GetNamespace(name, silent)
	if type(name) ~= "string" then
		error(("Usage: AceDBObject:GetNamespace(name): 'name' - string expected, got %q."):format(type(name)), 2)
	end
	if not silent and not (self.children and self.children[name]) then
		error(("Usage: AceDBObject:GetNamespace(name): 'name' - namespace %q does not exist."):format(name), 2)
	end
	if not self.children then self.children = {} end
	return self.children[name]
end

--[[-------------------------------------------------------------------------
	AceDB Exposed Methods
	
	These methods are exposed through the AceDB object and are used to create
	and initialize new databases.
---------------------------------------------------------------------------]]

--- Creates a new database object that can be used to handle database settings and profiles.
-- By default, an empty DB is created, using a character specific profile.
-- @param tbl The name of variable, or table to use for the database
-- @param defaults A table of database defaults
-- @param defaultProfile The name of the default profile. If not set, a character specific profile will be used as the default.
-- You can also pass //true// to use a shared global profile called "Default".
-- @return A new database object
-- @usage
-- -- Create an empty DB using a character-specific default profile
-- self.db = LibStub("AceDB-3.0"):New("MyAddonDB")
--
-- -- Create a DB using defaults and a shared default profile
-- self.db = LibStub("AceDB-3.0"):New("MyAddonDB", {
--     profile = {
--         setting = true,
--     }
-- }, true)
function AceDB:New(tbl, defaults, defaultProfile)
	if type(tbl) == "string" then
		local name = tbl
		tbl = _G[name]
		if not tbl then
			tbl = {}
			_G[name] = tbl
		end
	end

	if type(tbl) ~= "table" then
		error(("Usage: AceDB:New(tbl, defaults, defaultProfile): 'tbl' - table expected, got %q."):format(type(tbl)), 2)
	end

	if defaults and type(defaults) ~= "table" then
		error(("Usage: AceDB:New(tbl, defaults, defaultProfile): 'defaults' - table expected, got %q."):format(type(defaults)), 2)
	end

	if defaultProfile and type(defaultProfile) ~= "string" and defaultProfile ~= true then
		error(("Usage: AceDB:New(tbl, defaults, defaultProfile): 'defaultProfile' - string or true expected, got %q."):format(type(defaultProfile)), 2)
	end

	return initdb(tbl, defaults, defaultProfile)
end

--[[---------------------------------------------------------------------------
	Database Upgrade System
	
	Handles upgrading existing databases to include new functionality.
	This section ensures all existing databases receive the latest method
	definitions and maintain proper functionality.
---------------------------------------------------------------------------]]

-- upgrade existing databases
for db in pairs(AceDB.db_registry) do
	if not db.parent then
		for name,func in pairs(DBObjectLib) do
			db[name] = func
		end
	else
		db.RegisterDefaults = DBObjectLib.RegisterDefaults
		db.ResetProfile = DBObjectLib.ResetProfile
	end
end
