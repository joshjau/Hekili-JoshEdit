# Hekili

## [v11.0.7-1.0.4](https://github.com/Hekili/hekili/tree/v11.0.7-1.0.4) (2025-02-17)
[Full Changelog](https://github.com/Hekili/hekili/compare/v11.0.7-1.0.3a...v11.0.7-1.0.4) [Previous Releases](https://github.com/Hekili/hekili/releases)

- Revise Walkwinders  
- Merge pull request #4372 from joshjau/utils  
    Fix undefined 'icon' field in GetSpellBookItemInfo  
- Fix undefined 'icon' field in GetSpellBookItemInfo  
    It looks like the WoW API now uses iconID instead of icon when retrieving spell book information.  
- Fixes to AOE display  
    Update aura helpers  
- Merge pull request #4357 from joshjau/utils  
    Replace table.getn() with #table for Lua 5.1 compatibility  
- Merge pull request #4356 from baaron666/baaron666-patch-1  
    Update protection warrior abilities  
- Merge pull request #4359 from joshjau/mage-arcane  
    Replaced deprecated GetItemCooldown  
- Merge pull request #4364 from joshjau/demonology-fix2  
    fix: Remove unused parameter in imps\_spawned\_during metamethod  
- Merge pull request #4363 from joshjau/enhance-shaman  
    fix: Enhancement Shaman variable and debuff reference errors  
- Merge pull request #4353 from syrifgit/thewarwithin  
    Unholy DK, Prot Pal, Demo Lock  
- Incorrect Felstorm ID  
    Did not catch it on previous PR https://github.com/Hekili/hekili/pull/4279/files  
- Update ShamanEnhancement.lua  
- fix: Remove unused parameter in imps\_spawned\_during metamethod  
    Remove unused 'v' parameter from \_\_index metamethod in imps\_spawned\_during table to fix Lua metamethod argument count error.  
- fix: Enhancement Shaman variable and debuff reference errors  
    - Initialize tiTarget with nil to prevent value assignment warning  
    - Set vesper totem charges to 0 instead of nil for integer type compliance  
    - Change dot.flame\_shock to debuff.flame\_shock for correct debuff reference  
- C\_Item.GetItemCooldown  
    Removed as not used in the file.  
- Replaced deprecated GetItemCooldown  
    GetItemCooldown was deprecated in patch 10.2.6  
    Replaced with C\_Item.GetItemCooldown  
- Account for GoAK glyph  
    Using descriptive function. Tested in-game, resolves the issue.  
    Fixes #4358  
- Put a addon-specific edit back in place  
    I should've documented this edit via comment in the first place, oops. It just prevents creating and accessing a variable, which is just active\_enemies > 1, used by SIMC.  
- Reset thunder clap/blast cd with avatar  
- Replace table.getn() with #table for Lua 5.1 compatibility  
    Replaced obsolete table.getn() with #table to ensure compatibility with Lua 5.1 in WoW.  
- Remove violent\_outburst buff application from avatar which does not happen in-game  
- Correct thunder blast rage generation  
- Make avatar apply thunder\_blast buff when avatar\_of\_the\_storm talent is enabled  
- Infliction of Sorrow fix  
    Fixes #4352  
