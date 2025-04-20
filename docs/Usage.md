---
sidebar_position: 2
---

# Usage

## Creating a Zone
Zones can be created in two ways, either using addFromInstance or just add, addFromInstance gets the shape of the Instance passed to the function and calls add behind the scenes.

```lua
local cubeZone = zoner.add(CFrame.new(0, 10, 0), Vector3.new(10, 10, 10), "Cube")

local sphereZone = zoner.addFromInstance(workspace.SphereZone)
```

## Managing Objects
Objects can be added with assignToGroup.

```lua
zoner.assignToGroup("Example", workspace.Part)
```

The objects added this way automatically get cleaned up when the object is destroyed, however you can still manually remove an object from a group.

```lua
zoner.removeFromGroup("Example", workspace.Part)
```

Objects can also be part of multiple groups, which just requires additional calls to the assignToGroup function. assignToGroup also has an optional third parameter that lets you define a custom value to return in the callback function for onEntered and onExited. This is mainly so that associating data with parts is easier without having to maintain custom data structures.

```lua
zoner.assignToGroup("Example", workspace.Part, "Value") --the second parameter in the callback function will now be "Value" for this part
```

## Detecting Zone Entry/Exit
onEntered and onExited allow you to define any number of callbacks to listen to objects moving in or out of a zone.

```lua
zoner.onEntered("Example", function(part, customData)
    print(part, "entered zone, with data", customData) --if we take the object defined above, this will print "Part entered zone, with data Value"
end)

zoner.onExited("Example", function(part)
    print(part, "exited zone")
end)
```

## Additional Information
- Only having one Zone per tag is completely fine.
- This module can handle querying a lot of zones, but it is always a trade off if you want optimal performance, either a lot of objects or a lot of zones.
- There is a predefined "Players" group that gets handled by the module.