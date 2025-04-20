---
sidebar_position: 1
---

# Intro

## Overview
Zoner is a spatial partitioning system for Roblox that efficiently detects when objects enter or exit defined zones. It uses a Bounding Volume Hierarchy with Morton Codes for optimized spatial queries, making it suitable for large-scale applications.

## Quick Start
```lua
local Zoner = require(path.to.Zoner)

--create a zone
local zone = Zoner.addFromInstance(workspace.MyZonePart)
zone.watchGroups("Players")  --make this zone watch any object with the "Players" group

Zoner.onEntered("Players", function(player)
    print(player.Name .. " entered the zone!")
end)

Zoner.onExited("Players", function(player)
    print(player.Name .. " exited the zone!")
end)

--rebuild the BVH tree, needed after structural changes
Zoner.rebuild()
```