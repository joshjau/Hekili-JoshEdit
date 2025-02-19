--[[
Copyright (C) 2019-2022 Vardex

This file is part of LibTranslit.

LibTranslit is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

LibTranslit is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU Lesser General Public License along with LibTranslit. If not, see <https://www.gnu.org/licenses/>. 
--]]

--[[
LibTranslit-1.0
===============
A World of Warcraft library for transliterating Cyrillic text to Latin characters.
Useful for displaying Cyrillic names in Latin script or creating searchable indexes.

Features:
- Converts Cyrillic characters to their Latin equivalents
- Preserves case sensitivity
- Optional word marking for transliterated text
- Handles mixed Cyrillic/Latin text
- Maintains spacing and hyphenation

Example Usage:
-------------
local LibTranslit = LibStub("LibTranslit-1.0")
local latinText = LibTranslit:Transliterate("Привет") -- Returns "Privet"
local markedText = LibTranslit:Transliterate("Привет", "[ru]") -- Returns "[ru]Privet"

API Documentation:
----------------
LibTranslit:Transliterate(str, mark)
  str   - The Cyrillic string to transliterate
  mark  - Optional prefix to add to transliterated words
  
  Returns: The transliterated string in Latin characters

Version History:
--------------
4.0 - Current version
    - Performance optimizations
    - Improved error handling
    - Enhanced documentation
--]]

-- Library registration
local MAJOR_VERSION = "LibTranslit-1.0"
local MINOR_VERSION = 4

if not LibStub then
    error(MAJOR_VERSION .. " requires LibStub.")
    return
end

-- Early exit for older versions
local lib, oldMinor = LibStub:NewLibrary(MAJOR_VERSION, MINOR_VERSION)
if not lib then
    return -- Already loaded and newer version exists
end

-- Initialize or upgrade from previous version
lib = lib or {}

-- Cyrilllic to Latin character mapping
-- This table maps Cyrillic characters to their Latin equivalents
-- Format: [Cyrillic char] = "Latin equivalent"
local cyrToLat = {
    -- Uppercase Cyrillic
    ["А"] = "A",  -- CYRILLIC CAPITAL LETTER A
    ["Б"] = "B",  -- CYRILLIC CAPITAL LETTER BE
    ["В"] = "V",  -- CYRILLIC CAPITAL LETTER VE
    ["Г"] = "G",  -- CYRILLIC CAPITAL LETTER GHE
    ["Д"] = "D",  -- CYRILLIC CAPITAL LETTER DE
    ["Е"] = "E",  -- CYRILLIC CAPITAL LETTER IE
    ["Ё"] = "e",  -- CYRILLIC CAPITAL LETTER IO
    ["Ж"] = "Zh", -- CYRILLIC CAPITAL LETTER ZHE
    ["З"] = "Z",  -- CYRILLIC CAPITAL LETTER ZE
    ["И"] = "I",  -- CYRILLIC CAPITAL LETTER I
    ["Й"] = "Y",  -- CYRILLIC CAPITAL LETTER SHORT I
    ["К"] = "K",  -- CYRILLIC CAPITAL LETTER KA
    ["Л"] = "L",  -- CYRILLIC CAPITAL LETTER EL
    ["М"] = "M",  -- CYRILLIC CAPITAL LETTER EM
    ["Н"] = "N",  -- CYRILLIC CAPITAL LETTER EN
    ["О"] = "O",  -- CYRILLIC CAPITAL LETTER O
    ["П"] = "P",  -- CYRILLIC CAPITAL LETTER PE
    ["Р"] = "R",  -- CYRILLIC CAPITAL LETTER ER
    ["С"] = "S",  -- CYRILLIC CAPITAL LETTER ES
    ["Т"] = "T",  -- CYRILLIC CAPITAL LETTER TE
    ["У"] = "U",  -- CYRILLIC CAPITAL LETTER U
    ["Ф"] = "F",  -- CYRILLIC CAPITAL LETTER EF
    ["Х"] = "Kh", -- CYRILLIC CAPITAL LETTER HA
    ["Ц"] = "Ts", -- CYRILLIC CAPITAL LETTER TSE
    ["Ч"] = "Ch", -- CYRILLIC CAPITAL LETTER CHE
    ["Ш"] = "Sh", -- CYRILLIC CAPITAL LETTER SHA
    ["Щ"] = "Shch", -- CYRILLIC CAPITAL LETTER SHCHA
    ["Ъ"] = "",   -- CYRILLIC CAPITAL LETTER HARD SIGN
    ["Ы"] = "Y",  -- CYRILLIC CAPITAL LETTER YERU
    ["Ь"] = "",   -- CYRILLIC CAPITAL LETTER SOFT SIGN
    ["Э"] = "E",  -- CYRILLIC CAPITAL LETTER E
    ["Ю"] = "Yu", -- CYRILLIC CAPITAL LETTER YU
    ["Я"] = "Ya", -- CYRILLIC CAPITAL LETTER YA

    -- Lowercase Cyrillic
    ["а"] = "a",  -- CYRILLIC SMALL LETTER A
    ["б"] = "b",  -- CYRILLIC SMALL LETTER BE
    ["в"] = "v",  -- CYRILLIC SMALL LETTER VE
    ["г"] = "g",  -- CYRILLIC SMALL LETTER GHE
    ["д"] = "d",  -- CYRILLIC SMALL LETTER DE
    ["е"] = "e",  -- CYRILLIC SMALL LETTER IE
    ["ё"] = "e",  -- CYRILLIC SMALL LETTER IO
    ["ж"] = "zh", -- CYRILLIC SMALL LETTER ZHE
    ["з"] = "z",  -- CYRILLIC SMALL LETTER ZE
    ["и"] = "i",  -- CYRILLIC SMALL LETTER I
    ["й"] = "y",  -- CYRILLIC SMALL LETTER SHORT I
    ["к"] = "k",  -- CYRILLIC SMALL LETTER KA
    ["л"] = "l",  -- CYRILLIC SMALL LETTER EL
    ["м"] = "m",  -- CYRILLIC SMALL LETTER EM
    ["н"] = "n",  -- CYRILLIC SMALL LETTER EN
    ["о"] = "o",  -- CYRILLIC SMALL LETTER O
    ["п"] = "p",  -- CYRILLIC SMALL LETTER PE
    ["р"] = "r",  -- CYRILLIC SMALL LETTER ER
    ["с"] = "s",  -- CYRILLIC SMALL LETTER ES
    ["т"] = "t",  -- CYRILLIC SMALL LETTER TE
    ["у"] = "u",  -- CYRILLIC SMALL LETTER U
    ["ф"] = "f",  -- CYRILLIC SMALL LETTER EF
    ["х"] = "kh", -- CYRILLIC SMALL LETTER HA
    ["ц"] = "ts", -- CYRILLIC SMALL LETTER TSE
    ["ч"] = "ch", -- CYRILLIC SMALL LETTER CHE
    ["ш"] = "sh", -- CYRILLIC SMALL LETTER SHA
    ["щ"] = "shch", -- CYRILLIC SMALL LETTER SHCHA
    ["ъ"] = "",   -- CYRILLIC SMALL LETTER HARD SIGN
    ["ы"] = "y",  -- CYRILLIC SMALL LETTER YERU
    ["ь"] = "",   -- CYRILLIC SMALL LETTER SOFT SIGN
    ["э"] = "e",  -- CYRILLIC SMALL LETTER E
    ["ю"] = "yu", -- CYRILLIC SMALL LETTER YU
    ["я"] = "ya"  -- CYRILLIC SMALL LETTER YA
}

-- Cache frequently used functions for performance
local string_len = string.len
local string_sub = string.sub
local string_byte = string.byte
local string_char = string.char

---Transliterates a Cyrillic string to Latin characters
---@param str string The string to transliterate
---@param mark string? Optional marker to prefix transliterated words
---@return string transliterated The transliterated string
---@usage local latinText = LibTranslit:Transliterate("Привет") -- Returns "Privet"
---@usage local markedText = LibTranslit:Transliterate("Привет", "[ru]") -- Returns "[ru]Privet"
function lib:Transliterate(str, mark)
    -- Handle nil input
    if not str then
        return ""
    end

    -- Initialize variables
    mark = mark or ""
    local tstr = ""    -- Final transliterated string
    local tword = ""   -- Current word being processed
    local mark_word = false -- Flag for words containing Cyrillic characters
    local i = 1        -- String position counter

    -- Process string character by character
    while i <= string_len(str) do
        local c = string_sub(str, i, i)
        local b = string_byte(c)

        -- Check for Cyrillic character bytes (208 and 209 are Cyrillic UTF-8 markers)
        if b == 208 or b == 209 then
            mark_word = true
            c = string_sub(str, i + 1, i + 1)
            local cyrChar = string_char(b, string_byte(c))
            tword = tword .. (cyrToLat[cyrChar] or cyrChar)

            i = i + 2  -- Skip the next byte as it's part of the current Cyrillic character
        else
            -- Handle non-Cyrillic characters
            tword = tword .. c

            -- Check for word boundaries
            if c == " " or c == "-" then
                tstr = tstr .. (mark_word and mark .. tword or tword)
                tword = ""
                mark_word = false
            end

            i = i + 1
        end
    end

    -- Append the last word
    return tstr .. (mark_word and mark .. tword or tword)
end
