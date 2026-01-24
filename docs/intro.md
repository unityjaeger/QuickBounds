---
sidebar_position: 1
---

# Intro

## Overview
QuickBounds is a spatial detection module to track BaseParts moving in and out of predefined areas in the world.
It uses a Bounding Volume Hierarchy under the hood to minimize the costs of tracking these BaseParts.

## Installation

For both pesde and wally, the package name + version is

```
unityjaeger/quickbounds@0.3.4
```

Or if you want the source, then just grab it from the latest release from the [Releases](https://github.com/unityjaeger/QuickBounds/releases) tab.

## Quick Start
```lua
--create a group (optionally with a priority)
local group = QuickBounds.createGroup(10) --lower priority groups get prioritized

--add a basepart to the group to be tracked (optionally with custom data)
group:add(workspace.ExamplePart, "custom data")

--create a zone
local zone = QuickBounds.createZoneFromInstance(workspace.ExampleZonePart)

--make the zone start watching the example group
zone:watchGroups(group)

--register callbacks for zone entering/exiting
group:onEntered(function(part, zone, customData)
    --if the zone was registered with createZoneFromInstance then zone.part will be the Instance passed to that function,  otherwise it will be nil
    print(part, "entered", zone.part, "with custom data", customData)
end)

group:onExited(function(part, zone, customData)
    --if the zone was registered with createZoneFromInstance then zone.part will be the Instance passed to that function, otherwise it will be nil
    print(part, "exited", zone.part, "with custom data", customData)
end)
```