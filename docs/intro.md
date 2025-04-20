---
sidebar_position: 1
---

# Intro

## Overview
QuickBounds is a spatial partitioning system for Roblox that efficiently detects when objects enter or exit defined zones. It uses a Bounding Volume Hierarchy with Morton Codes for optimized spatial queries, making it suitable for large-scale applications.

## Installation
Just grab the latest release from the [Releases](https://github.com/unityjaeger/QuickBounds/releases) tab.

## Quick Start
```lua
--create a zone
local zone = QuickBounds.addFromInstance(workspace.MyZonePart)
zone.watchGroups("Players")  --make this zone watch any object with the "Players" group

QuickBounds.onEntered("Players", function(_, player)
    print(player.Name .. " entered the zone!")
end)

QuickBounds.onExited("Players", function(_, player)
    print(player.Name .. " exited the zone!")
end)

--rebuild the BVH tree, needed after structural changes
QuickBounds.rebuild()
```