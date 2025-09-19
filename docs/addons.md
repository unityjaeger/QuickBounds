---
sidebar_position: 3
---

# Addons

These are official addons you can find in the [addons](https://github.com/unityjaeger/QuickBounds/tree/main/addons) folder.

## [Player Addon](https://github.com/unityjaeger/QuickBounds/tree/main/addons/players.luau)

This addon abstracts management of the player character away so that it's more comfortable to work with players.

It exposes a function to add players to groups and a function to remove players from groups.

Basic usage looks like this:

```lua
local exampleGroup = QuickBounds.createGroup()

local zone = QuickBounds.createZoneFromInstance(workspace.ExampleZone)
zone:watchGroups(exampleGroup)

game.Players.PlayerAdded:Connect(function(player)
	PlayerAddon.addPlayerToGroups(player, exampleGroup)
end)

exampleGroup:onEntered(function(rootPart, zone, player)
	print(player.Name, "entered zone", zone.part)
end)

exampleGroup:onExited(function(rootPart, zone, player)
	print(player.Name, "exited zone", zone.part)
end)
```

Cleanup when players leave is done automatically, so you don't need to manually remove the player from all groups when the player leaves.

If you want to use this addon with StreamingEnabled on the Client then you have to set the player characters to Persistent on the server.