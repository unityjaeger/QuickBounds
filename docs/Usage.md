---
sidebar_position: 2
---

# Usage

## Creating a Zone
Zones can be created in two ways, either using addFromInstance or just add, addFromInstance gets the shape of the Instance passed to the function and calls add behind the scenes.

```lua
local cubeZone = QuickBounds.add(CFrame.new(0, 10, 0), Vector3.new(10, 10, 10), "Cube")

local sphereZone = QuickBounds.addFromInstance(workspace.SphereZone)
```

## Zone Methods
You can remove the zone with by calling remove on it:
```lua
local zone = QuickBounds.addFromInstance(workspace.Example)
zone:remove()
```

To make zones track a group, you can call watchGroups, and to make the zone stop watching a group you can call unwatchGroups, both take tuples as arguments.
```lua
local zone = QuickBounds.addFromInstance(workspace.Example)
zone:watchGroups("Players", "Example")
zone:unwatchGroups("Example2")
```

## Managing Objects
Objects can be added with assignToGroup.

```lua
QuickBounds.assignToGroup("Example", workspace.Part)
```

The objects added this way automatically get cleaned up when the object is destroyed, however you can still manually remove an object from a group.

```lua
QuickBounds.removeFromGroup("Example", workspace.Part)
```

Objects can also be part of multiple groups, which just requires additional calls to the assignToGroup function. assignToGroup also has an optional third parameter that lets you define a custom value to return alongside the part in the callback function for onEntered and onExited. This is mainly so that associating data with parts is easier without having to maintain custom data structures. The custom data is specific to the group that the part was added to, so if you want it to have the same data for every group you would need to call the function with your custom data each time.

```lua
QuickBounds.assignToGroup("Example", workspace.Part, "Value") --the second parameter in the callback function will now be "Value" for this part
```

## Detecting Zone Entry/Exit
onEntered and onExited allow you to define any number of callbacks to listen to objects moving in or out of a zone.

```lua
QuickBounds.onEntered("Example", function(part, customData)
    print(part, "entered zone, with data", customData) --if we take the object defined above, this will print "Part entered zone, with data Value"
end)

QuickBounds.onExited("Example", function(part)
    print(part, "exited zone")
end)
```

## Fetching Things Manually
You can get all parts that a group contains like so:

```lua
for _, rootPart in QuickBounds.getPartsForGroup("Players") do
    --access the custom data associated with the rootpart, which is the Player object
    local player = QuickBounds.getCustomPartData(player, "Players")
    print(player)
end
```

You can also get all groups that a part is inside of with getGroupsForPart

```lua
for _, group in QuickBounds.getGroupsForPart(workspace.Example) do
    --...
end
```

If you just want to check if a part is inside of a single zone, you can use isPartInGroup, as it is more performant
```lua
local character = player.Character
--we use the humanoidrootpart, since that is the part that actually gets associated with the Players group
local isInside = QuickBounds.isPartInGroup(character.HumanoidRootPart, "Players")
```

To get all zone objects that are part of a group, you can use getAllZonesForGroup, however, this returns the internal structure of the zone used by the BVH.
```lua
local zone = QuickBounds.addFromInstance(workspace.Example)
zone:watchGroups("Players") 
for _, boundingVolume in QuickBounds.getAllZonesForGroup("Players") do
    print(boundingVolume.CFrame) --will print the CFrame of workspace.Example, check the BoundingVolume type in the API reference for more info on what zoneData holds
end
```

## Frame Budget
You can define the maximum frame time that the module will use up per frame to process zones. The time is passed in milliseconds and the default time is 0.2 milliseconds. This frame budget **ONLY** cares about the checking of which zone a part is in, and does not include the time your callbacks take to run. As such, it is recommended to keep it at a low number, like the default 0.2 milliseconds.

```lua
QuickBounds.setFrameBudgetMs(1) --1 millisecond
```

## Additional Information
- Only having one Zone per tag is completely fine.
- This module can handle querying a lot of zones, but it is always a trade off if you want optimal performance, either a lot of objects or a lot of zones.
- There is a predefined "Players" group that gets handled by the module.
- Parts only get their center checked against the zones for optimization.