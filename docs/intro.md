---
sidebar_position: 1
---

# Intro

## Overview
QuickBounds is a spatial partitioning system for Roblox that efficiently detects when objects enter or exit defined zones. It uses a Bounding Volume Hierarchy with Morton Codes for optimized spatial queries, making it suitable for large-scale applications.

## Installation
If you use wally, then put this in your wally.toml
```
QuickBounds = "unityjaeger/quickbounds@0.2.3"
```

Alternatively, if you use pesde, then you can install it like this:
```
pesde add unityjaeger/quickbounds
```

Or if you want the source, then just grab it from the latest release from the [Releases](https://github.com/unityjaeger/QuickBounds/releases) tab.

## Quick Start
```lua
--create a zone
local zone = QuickBounds.addFromInstance(workspace.MyZonePart)
zone:watchGroups("Players")  --make this zone watch any object with the "Players" group

QuickBounds.onEntered("Players", function(_, player)
    print(player.Name .. " entered the zone!")
end)

QuickBounds.onExited("Players", function(_, player)
    print(player.Name .. " exited the zone!")
end)
```