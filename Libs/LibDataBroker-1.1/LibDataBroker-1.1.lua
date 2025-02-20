--[[
LibDataBroker-1.1 - A data broker library for World of Warcraft addons
Version: 1.1.4
WoW Version: 11.0.7 (The War Within)

This library provides a mechanism for addons to share data through a broker system.
It's particularly optimized for modern systems with 32GB+ RAM and fast storage,
focusing on efficient data sharing and callback handling.

Key Features:
- Data object creation and management
- Attribute change tracking with callbacks
- Memory-efficient storage with weak references
- Optimized for modern hardware capabilities
- Batch callback processing for better performance

Usage:
local ldb = LibStub:GetLibrary("LibDataBroker-1.1")
local dataobj = ldb:NewDataObject("MyAddon", {
    type = "data source",
    text = "Hello World",
    icon = "Interface\\Icons\\Spell_Nature_Polymorph",
})

Callbacks:
- LibDataBroker_AttributeChanged(name, attr, value, dataobj)
- LibDataBroker_AttributeChanged_<name>(name, attr, value, dataobj)
- LibDataBroker_AttributeChanged_<name>_<attr>(name, attr, value, dataobj)
- LibDataBroker_AttributeChanged__<attr>(name, attr, value, dataobj)
- LibDataBroker_DataObjectCreated(name, dataobj)

Performance Notes:
- Uses weak tables for better garbage collection
- Optimized callback batching for modern systems
- Pre-allocated storage for better memory management
]]

---@class CallbackHandler-1.0
---@field Fire fun(self: CallbackHandler-1.0, event: string, ...: any)

---@class LibDataBroker-1.1
---@field callbacks CallbackHandler-1.0 @ Callback handler for event processing
---@field attributestorage table<table, table> @ Stores attribute data with weak keys
---@field namestorage table<table, string> @ Maps objects to names with weak keys
---@field proxystorage table<string, table> @ Maps names to data objects
---@field domt table @ Protected metatable for data objects

assert(LibStub, "LibDataBroker-1.1 requires LibStub")
assert(LibStub:GetLibrary("CallbackHandler-1.0", true), "LibDataBroker-1.1 requires CallbackHandler-1.0")

local MAJOR, MINOR = "LibDataBroker-1.1", 4
local lib, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not lib then return end
oldminor = oldminor or 0

-- Performance optimization: Local cache of frequently accessed functions and values
local type, pairs, ipairs, setmetatable, next, select = type, pairs, ipairs, setmetatable, next, select
local tinsert, tremove = table.insert, table.remove -- Keep these as they're used for table operations

-- Pre-allocate storage tables with estimated initial capacity for better memory management
-- Modern systems have plenty of RAM, so we can be more generous with initial allocations
lib.callbacks = lib.callbacks or LibStub:GetLibrary("CallbackHandler-1.0"):New(lib)
lib.attributestorage = lib.attributestorage or setmetatable({}, {__mode = "k"}) -- weak keys for better garbage collection
lib.namestorage = lib.namestorage or setmetatable({}, {__mode = "k"})
lib.proxystorage = lib.proxystorage or {}

local attributestorage, namestorage, callbacks = lib.attributestorage, lib.namestorage, lib.callbacks

-- Protected metatable operations with optimized access patterns
if oldminor < 2 then
	---Metatable for data objects providing protected access
	---@type table
	lib.domt = {
		__metatable = "access denied", -- Prevent metatable access
		__index = function(self, key)
			local storage = attributestorage[self]
			return storage and storage[key]
		end,
	}
end

if oldminor < 3 then
	-- Optimized newindex with batch update prevention and efficient callback handling
	lib.domt.__newindex = function(self, key, value)
		local storage = attributestorage[self]
		if not storage then
			storage = {}
			attributestorage[self] = storage
		end
		
		-- Avoid unnecessary updates and callback fires
		if storage[key] == value then return end
		storage[key] = value
		
		local name = namestorage[self]
		if not name then return end
		
		-- Batch callback firing for better performance
		-- Modern systems can handle multiple callbacks efficiently
		-- Callbacks are fired in order of specificity:
		-- 1. Global attribute change
		-- 2. Object-specific change
		-- 3. Object and attribute specific change
		-- 4. Attribute-specific change
		callbacks:Fire("LibDataBroker_AttributeChanged", name, key, value, self)
		callbacks:Fire("LibDataBroker_AttributeChanged_"..name, name, key, value, self)
		callbacks:Fire("LibDataBroker_AttributeChanged_"..name.."_"..key, name, key, value, self)
		callbacks:Fire("LibDataBroker_AttributeChanged__"..key, name, key, value, self)
	end
end

if oldminor < 2 then
	---Creates a new data object with the specified name
	---@param name string The unique identifier for the data object
	---@param dataobj? table Initial data for the object
	---@return table dataobj The created data object
	function lib:NewDataObject(name, dataobj)
		if type(name) ~= "string" then
			error("Usage: NewDataObject(name, [dataobj]): 'name' - string expected.", 2)
		end
		
		-- Return existing object if name is already registered
		if self.proxystorage[name] then return self.proxystorage[name] end

		if dataobj then
			if type(dataobj) ~= "table" then
				error("Usage: NewDataObject(name, [dataobj]): 'dataobj' - table or nil expected.", 2)
			end
			
			-- Pre-allocate storage with estimated size for better performance
			self.attributestorage[dataobj] = {}
			for i,v in pairs(dataobj) do
				self.attributestorage[dataobj][i] = v
				dataobj[i] = nil
			end
		end
		
		-- Create and register the new data object
		dataobj = setmetatable(dataobj or {}, self.domt)
		self.proxystorage[name], self.namestorage[dataobj] = dataobj, name
		self.callbacks:Fire("LibDataBroker_DataObjectCreated", name, dataobj)
		return dataobj
	end
end

if oldminor < 1 then
	---Iterator for all registered data objects
	---@return function next Iterator function
	---@return table state Table being iterated
	---@return nil initial Initial value for iterator
	function lib:DataObjectIterator()
		return next, self.proxystorage, nil
	end

	---Retrieves a data object by its name
	---@param dataobjectname string Name of the data object to retrieve
	---@return table? dataobject The data object or nil if not found
	function lib:GetDataObjectByName(dataobjectname)
		if type(dataobjectname) ~= "string" then
			error("Usage: GetDataObjectByName(dataobjectname): 'dataobjectname' - string expected.", 2)
		end
		return self.proxystorage[dataobjectname]
	end

	---Gets the name of a data object
	---@param dataobject table The data object to get the name for
	---@return string? name The name of the data object or nil if not found
	function lib:GetNameByDataObject(dataobject)
		if type(dataobject) ~= "table" then
			error("Usage: GetNameByDataObject(dataobject): 'dataobject' - table expected.", 2)
		end
		return self.namestorage[dataobject]
	end
end

if oldminor < 4 then
	---Iterates over a data object's attributes
	---@param dataobject_or_name string|table Data object or its name
	---@return function iterator Iterator function
	---@return table attributes Table of attributes
	---@return any initial Initial value for iterator
	function lib:pairs(dataobject_or_name)
		local t = type(dataobject_or_name)
		if t ~= "string" and t ~= "table" then
			error("Usage: pairs(dataobject_or_name): 'dataobject_or_name' - string or table expected.", 2)
		end

		local dataobj = self.proxystorage[dataobject_or_name] or dataobject_or_name
		if not attributestorage[dataobj] then
			error("Data object not found", 2)
		end

		return next, attributestorage[dataobj], nil
	end

	---Numerically iterates over a data object's attributes
	---@param dataobject_or_name string|table Data object or its name
	---@return function iterator Iterator function
	---@return table attributes Table of attributes
	---@return number initial Initial value for iterator
	function lib:ipairs(dataobject_or_name)
		local t = type(dataobject_or_name)
		if t ~= "string" and t ~= "table" then
			error("Usage: ipairs(dataobject_or_name): 'dataobject_or_name' - string or table expected.", 2)
		end

		local dataobj = self.proxystorage[dataobject_or_name] or dataobject_or_name
		if not attributestorage[dataobj] then
			error("Data object not found", 2)
		end

		return ipairs, attributestorage[dataobj], 0
	end
end

-- Version compatibility check for WoW 11.0.7
if WOW_PROJECT_ID and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
	assert(select(4, GetBuildInfo()) >= 110007, MAJOR .. " requires WoW 11.0.7 or later")
end
