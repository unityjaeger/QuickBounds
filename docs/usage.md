---
sidebar_position: 2
---

# Usage

## Zones

### Understanding Zones

Think of a zone as an invisible boundary that defines a spatial area of interest. A zone has mathematical boundaries that define where it begins and ends, as well as a shape. Zones can overlap, intersect and exist in the same space without conflicting with each other.

A zone is just simple geometry, it knows it's own shape, size and cframe. You can create a zone in one of two ways: Either by manually passing the cframe, size and shape or by creating the zone based on an instance. Every Roblox BasePart shape but Half Wedge is supported.

### Creation

```lua
--example of manual zone creation
QuickBounds.createZone(
    CFrame.new(0, 5, 0),
    Vector3.new(10, 10, 10),
    "Box"
)
```

```lua
--example of zone creation from an instance
QuickBounds.createZoneFromInstance(workspace.ZonePart)
```

What's important to remember is that zones are purely geometric and that they can be used by multiple groups simultaneously if wanted.

If at any point you want to destroy a zone, you can simply call

```lua
zone:destroy()
```

### Watching Groups

To start tracking groups you have to tell the zone to watch the groups.

```lua
local zone = QuickBounds.createZoneFromInstance(workspace.ZonePart)
zone:watchGroups(ExampleGroup1, ExampleGroup2)
```

You can also tell a zone to stop watching groups.

```lua
zone:unwatchGroups(ExampleGroup1)
```

This will be elaborated on further in the next section

## Groups

### Understanding Groups

You can think of a group as an observer that watches zones and reacts when objects enter or leave said zones. Each group should ideally embody a particular aspect of your game logic - for example a safezone, quest triggers, traps and so on.

The relationship between zones and groups is many to many, meaning any number of zones can watch any number of groups. When a zone starts watching a group, the group will be notified if any of its associated BaseParts enter this zone.

### Creation and Priority

To get a group working, you first need to create a group like so:

```lua
QuickBounds.createGroup(10)
```

When creating a group you can pass a number parameter that is the priority of the group, the lower the priority of a group the higher the actual priority, it sounds confusing but this is due to an optimization (not needing to pass a function to table.sort during priority resolution, for those who care). So groups with a lower priority value get prioritized over groups with a higher priority value, groups at the same priority can coexist without interferring with one another.

The above snippet is equivalent to this:

```lua
local group = QuickBounds.createGroup()
group:setPriority(10)
```

When no priority is passed during group creation, it defaults to 100'000.

![Priority](priorities.png)

### Adding and Removing Parts

If you want a group to start tracking a specific BasePart then you can do the following:

```lua
local group = QuickBounds.createGroup()
group:add(workspace.ExamplePart, "Custom Data")
task.wait(5)
group:remove(workspace.ExamplePart)
```

This will register the BasePart with the group, if you want it to be a part of more groups then you have to register it with each group.

There is also an optional second parameter for add that attaches custom data to a BasePart.

In this example it will also remove the BasePart from the group after 5 seconds.

### Tracking Entry/Exit

To track entry/exit to a group you can do the following:

```lua
local group = QuickBounds.createGroup()

group:onEntered(function(part: BasePart, zone: QuickBounds.Zone, customData: any?)
    print(part, "entered this group")
end)

group:onExited(function(part: BasePart, zone: QuickBounds.Zone, customData: any?)
    print(part, "exited this group")
end)
```

There is no limit to the callbacks that can be registered for a group.

The first parameter for the callback is the BasePart that interacted with the group, while the second is the specific zone object that the BasePart has entered. If the zone was created via createZoneFromInstance then it will also have a "part" field that can be accessed. The third parameter is the custom data that may or may not have been specified while adding a BasePart to the group, if you want a practical example of custom data in use then check out the Player Addon under the Addons tab.

Both onEntered and onExited return a cleanup function to remove the callback.

## Considerations

- only the positions of BaseParts are tracked and their size not included for calculations, this means only the center of the BasePart can trigger Entry/Exit, make sure to keep this in mind when working with small zones or big BaseParts