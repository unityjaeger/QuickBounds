

--[=[
	@class QuickBounds
]=]

--[=[
    @function createZone
    @within QuickBounds
    @param cframe CFrame
    @param size Size
    @param shape "Block" | "Ball" | "Cylinder" | "Wedge"
    @return Zone
]=]

--[=[
    @function createZoneFromInstance
    @within QuickBounds
    @param part BasePart
    @return Zone
    Creates and returns a Zone built from an instance, does not support Corner Wedges.
]=]

--[=[
    @function setFrameBudget
    @within QuickBounds
    @param budget number
    Sets the frame budget available for each processing frame, in seconds.
]=]

--[=[
    @function createGroup
    @within QuickBounds
    @param priority number?
    @return Group
    Creates and returns a group, with an optionally specified priority. Default priority is 1e6 (100'000).
]=]

--[=[
    @function isPartInGroup
    @within QuickBounds
    @param part BasePart
    @param group Group
    @return boolean
    Checks if the BasePart is member of the group, not if it's currently physically inside of the group.
]=]

--[=[
    @function getPartsForGroup
    @within QuickBounds
    @param group Group
    @return {BasePart}
    Returns all parts that are a member of the group.
]=]

--[=[
    @function getGroupsForPart
    @within QuickBounds
    @param part BasePart
    @return {Group}
    Returns all groups that the BasePart is a member of.
]=]

--[=[
    @class Group
]=]

--[=[
   @method add
   @within Group
   @param part BasePart
   @param customData any?
   Start tracking the specified BasePart.
]=]

--[=[
   @method remove
   @within Group
   @param part BasePart
   Makes the group stop tracking the specified BasePart.
]=]

--[=[
   @method setPriority
   @within Group
   @param priority number
   Groups with the same priority can be entered by a BasePart that is a member of both groups simultaneously.
   If the groups have a different priority then the one with a lower priority will win.
]=]

--[=[
   @method onEntered
   @within Group
   @param callback (part: BasePart, zone: Zone, customData: any?) -> ()
   @return () -> ()
   Tracks whenever a BasePart that is a member of this group enters this group through a Zone with the use of a callback function, returns a cleanup function. 
]=]

--[=[
   @method onExited
   @within Group
   @param callback (part: BasePart, zone: Zone, customData: any?) -> ()
   @return () -> ()
   Tracks whenever a BasePart that is a member of this group exits this group through a Zone with the use of a callback function, returns a cleanup function. 
]=]

--[=[
   @prop UID number
   @within Group
   Unique identifier for this group.
]=]

--[=[
    @class Zone
]=]

--[=[
    @prop part BaseClass?
    @within Zone
    If available, the BasePart associated with the zone object.
]=]

--[=[
    @prop index number
    @within Zone
    Used for internal data structures.
]=]

--[=[
    @method watchGroups
    @within Zone
    @param ... ...Group
    Start watching the specified groups.
]=]

--[=[
    @method unwatchGroups
    @within Zone
    @param ... ...Group
    Stop watching the specified groups.
]=]

--[=[
    @method destroy
    @within Zone
]=]