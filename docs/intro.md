---
sidebar_position: 1
---

# Intro

## Overview
QuickBounds is a spatial detection module to track BaseParts moving in and out of predefined areas in the world.
It uses a Bounding Volume Hierarchy under the hood to minimize the costs of tracking these BaseParts.

## Installation
If you use wally, then put this in your wally.toml
```
QuickBounds = "unityjaeger/quickbounds@0.3.0"
```

Alternatively, if you use pesde, then you can install it like this:
```
pesde add unityjaeger/quickbounds
```

Or if you want the source, then just grab it from the latest release from the [Releases](https://github.com/unityjaeger/QuickBounds/releases) tab.

## Quick Start
```lua
--create a group (optionally with a priority)
local group = QuickBounds.createGroup(10) --lower priority groups get prioritized

--create a zone
local zone = QuickBounds.createZoneFromInstance(workspace.MyZonePart)
--make the zone start watching specific groups
zone:watchGroups(group)

--
group:onEntered(function(_, zone, player)
    print(player.Name .. " entered the zone!")
end)

group:onExited(function(_, zone, player)
    print(player.Name .. " exited the zone!")
end)
```