--!native
--!optimize 2
--!strict

local RunService = game:GetService("RunService")

export type Trackable = BasePart | Camera | Model | WorldModel

type ListItem = {
	id: number,
	mortonCode: number,
}

type Node = {
	left: Node?,
	right: Node?,
	min: Vector3,
	max: Vector3,
	id: number,
}

type BoundingVolume = {
	Shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	Position: Vector3,
	CFrame: CFrame,
	HalfSize: Vector3,

	-- sphere specific
	radius: number?,

	-- cylinder specific
	start: Vector3?,
	axis: Vector3?,
	axisLength: number?,
	radiusSquared: number?,
}

local objects: { BoundingVolume } = {}
local nextZoneId = 1

local function unionBounds(nodeA: Node, nodeB: Node): (Vector3, Vector3)
	if not nodeA then
		return nodeB.min, nodeB.max
	end
	if not nodeB then
		return nodeA.min, nodeA.max
	end
	return vector.min(nodeA.min, nodeB.min), vector.max(nodeA.max, nodeB.max)
end

local function getObjectBounds(object: BoundingVolume): (Vector3, Vector3)
	local halfSize = object.HalfSize
	local cframe = object.CFrame
	local center = object.Position

	local halfExtent = vector.abs(cframe.RightVector) * halfSize.X
		+ vector.abs(cframe.UpVector) * halfSize.Y
		+ vector.abs(cframe.LookVector) * halfSize.Z

	return center - halfExtent, center + halfExtent
end

local MORTON_SHIFT16_MASK = 0xFF0000FF
local MORTON_SHIFT8_MASK = 0xF00F00F
local MORTON_SHIFT4_MASK = 0x30C30C3
local MORTON_SHIFT2_MASK = 0x9249249

local expandLUT = {}
for i = 0, 1023 do
	local value = i
	value = bit32.bor(bit32.lshift(value, 16), value)
	value = bit32.band(value, MORTON_SHIFT16_MASK)
	value = bit32.bor(bit32.lshift(value, 8), value)
	value = bit32.band(value, MORTON_SHIFT8_MASK)
	value = bit32.bor(bit32.lshift(value, 4), value)
	value = bit32.band(value, MORTON_SHIFT4_MASK)
	value = bit32.bor(bit32.lshift(value, 2), value)
	value = bit32.band(value, MORTON_SHIFT2_MASK)
	expandLUT[i] = value
end

local function expandBits(value: number): number
	return expandLUT[bit32.band(value, 0x3FF)]
end

local function positionToMortonCode(position: Vector3, sceneBoundsMin: Vector3, sceneBoundsMax: Vector3): number
	local scaled = vector.floor(
		vector.clamp((position - sceneBoundsMin) / (sceneBoundsMax - sceneBoundsMin), vector.zero, vector.one) * 1023
	)

	return bit32.bor(expandBits(scaled.x), bit32.lshift(expandBits(scaled.y), 1), bit32.lshift(expandBits(scaled.z), 2))
end

local function getSplitPos(list: { ListItem }, beginIndex: number, endIndex: number): number?
	if (endIndex - beginIndex + 1) < 2 then
		return nil
	end

	if endIndex == beginIndex + 1 then
		return beginIndex + 1
	end

	local first = list[beginIndex].mortonCode
	local last = list[endIndex].mortonCode

	if first == last then
		return (beginIndex + endIndex) // 2
	end

	local xor_val = bit32.bxor(first, last)
	local highest_bit = 31 - bit32.countlz(xor_val)

	local mask = bit32.lshift(1, highest_bit)
	local first_mask = bit32.band(first, mask)

	local left = beginIndex
	local right = endIndex

	while right - left > 1 do
		local m = (left + right) // 2

		if bit32.band(list[m].mortonCode, mask) == first_mask then
			left = m
		else
			right = m
		end
	end

	return left + 1
end

local HUGE_VECTOR = Vector3.one * math.huge
local NEGATIVE_HUGE_VECTOR = -HUGE_VECTOR
local function calculateSceneBounds(): (Vector3, Vector3)
	local min = HUGE_VECTOR
	local max = NEGATIVE_HUGE_VECTOR

	for _, object in objects do
		local boundsMin, boundsMax = getObjectBounds(object)
		min = vector.min(min, boundsMin)
		max = vector.max(max, boundsMax)
	end

	local padding = vector.max(vector.one, (max - min) * 0.01)
	return min - padding, max + padding
end

local function createSubTree(
	list: { ListItem },
	boundsMin: { Vector3 },
	boundsMax: { Vector3 },
	beginIndex: number,
	endIndex: number
): Node
	if beginIndex == endIndex then
		local id = list[beginIndex].id
		return {
			min = boundsMin[id],
			max = boundsMax[id],
			id = id,
		}
	else
		local mid = getSplitPos(list, beginIndex, endIndex)
		if mid == nil then
			-- treat as leaf
			local id = list[beginIndex].id
			return {
				min = boundsMin[id],
				max = boundsMax[id],
				id = id,
			}
		end

		local left = createSubTree(list, boundsMin, boundsMax, beginIndex, mid - 1)
		local right = createSubTree(list, boundsMin, boundsMax, mid, endIndex)
		local min, max = unionBounds(left, right)
		return {
			min = min,
			max = max,
			id = -1,
			left = left,
			right = right,
		}
	end
end

local function createBVH(): Node?
	local sceneBoundsMin, sceneBoundsMax = calculateSceneBounds()

	local list: { ListItem } = {}
	local objectBoundsMin = {}
	local objectBoundsMax = {}

	for id, object in objects do
		local boundsMin, boundsMax = getObjectBounds(object)
		objectBoundsMin[id] = boundsMin
		objectBoundsMax[id] = boundsMax

		local mortonCode = positionToMortonCode(object.Position, sceneBoundsMin, sceneBoundsMax)
		table.insert(list, { id = id, mortonCode = mortonCode })
	end

	table.sort(list, function(a: ListItem, b)
		return a.mortonCode < b.mortonCode
	end)

	if #list > 0 then
		return createSubTree(list, objectBoundsMin, objectBoundsMax, 1, #list)
	else
		return nil
	end
end

local traversalStack = table.create(64)
local function pointIntersection(rootNode: Node, point: Vector3, callback: (nodeId: number) -> ()): ()
	if not rootNode then
		return
	end

	local stackPtr = 1
	traversalStack[1] = rootNode

	while stackPtr > 0 do
		local node = traversalStack[stackPtr]
		stackPtr -= 1

		local min, max = node.min, node.max
		if
			point.X >= min.X
			and point.X <= max.X
			and point.Y >= min.Y
			and point.Y <= max.Y
			and point.Z >= min.Z
			and point.Z <= max.Z
		then
			if node.id > 0 then
				local object = objects[node.id]

				if object.Shape == "Block" then
					local localPoint = vector.abs(object.CFrame:PointToObjectSpace(point))
					if vector.min(localPoint, object.HalfSize) == localPoint then
						callback(node.id)
					end
				elseif object.Shape == "Ball" then
					if vector.magnitude(object.Position - point) <= object.radius then
						callback(node.id)
					end
				elseif object.Shape == "Cylinder" then
					local toPoint = point - object.start :: Vector3
					local projection = vector.dot(toPoint, object.axis :: Vector3)

					if projection >= 0 and projection <= object.axisLength :: number then
						local closestPointOnAxis = object.start :: Vector3 + object.axis :: Vector3 * projection
						local distance = point - closestPointOnAxis
						if vector.dot(distance, distance) <= object.radiusSquared :: number then
							callback(node.id)
						end
					end
				elseif object.Shape == "Wedge" then
					local localPoint = object.CFrame:PointToObjectSpace(point)
					local absolutePoint = vector.abs(localPoint)
					if vector.min(absolutePoint, object.HalfSize) == absolutePoint then
						local size = object.HalfSize * 2
						if localPoint.Y / size.Y - localPoint.Z / size.Z <= 0 then
							callback(node.id)
						end
					end
				end
			else
				stackPtr += 1
				traversalStack[stackPtr] = node.left
				stackPtr += 1
				traversalStack[stackPtr] = node.right
			end
		end
	end
end

type GroupUID = number
type ZoneIndex = number

export type Shapes = "Block" | "Ball" | "Cylinder" | "Wedge"
export type Callback = (trackable: Trackable, zone: Zone, customData: any?) -> ()

export type Zone = {
	-- methods
	bindToGroups: (zone: Zone, ...Group) -> (),
	unbindToGroups: (zone: Zone, ...Group) -> (),
	getGroups: (zone: Zone) -> { Group },
	destroy: (zone: Zone) -> (),

	-- props
	index: number,
	part: BasePart?,
}

export type Group = {
	-- methods
	trackItem: (self: Group, trackable: Trackable, customData: any?) -> (),
	untrackItem: (self: Group, trackable: Trackable) -> (),
	setPriority: (self: Group, priority: number) -> (),
	isItemInside: (self: Group, trackable: Trackable) -> boolean,
	isPointInside: (self: Group, position: Vector3) -> boolean,
	isItemTracked: (self: Group, trackable: Trackable) -> boolean,
	getTrackedItems: (self: Group) -> { Trackable },
	getItemsInside: (self: Group) -> { Trackable },
	getZones: (self: Group) -> { Zone },

	-- events
	onEntered: (self: Group, callback: Callback) -> () -> (),
	onExited: (self: Group, callback: Callback) -> () -> (),

	-- props
	UID: number,
}

local frameBudget = 1 / 1000 --1ms by default
local nextGroupId = 1
local pendingRebuild = false
local isDirty = false
local root: Node? = nil

type TrackableData = {
	activeGroupMemberships: { [GroupUID]: ZoneIndex },
	memberOfGroups: { [GroupUID]: boolean },
	lastPosition: Vector3?,
	isPart: boolean?,
	isDirty: boolean?,
}

local trackables: { [Trackable]: TrackableData } = {}
local trackableCustomData: { [Trackable]: { [GroupUID]: any } } = {}

local groupActiveMembers = {}
local groupPriorityMap: { [GroupUID]: number } = {}
local groupUIDToGroupObject: { [GroupUID]: Group } = {}
local groupEnteredCallbackMap: { [GroupUID]: { Callback } } = {}
local groupExitedCallbackMap: { [GroupUID]: { Callback } } = {}

local zoneWatchingGroups: { [ZoneIndex]: { GroupUID } } = {}
local zoneIndexToZoneObject: { [ZoneIndex]: Zone } = {}

local function bindZoneToGroups(zone: Zone, ...: Group)
	local watching = zoneWatchingGroups[zone.index]

	if not watching then
		watching = {}
		zoneWatchingGroups[zone.index] = watching
	end

	local groups = { ... }
	for i = 1, #groups do
		local gUID = groups[i].UID
		if not table.find(watching, gUID) then
			table.insert(watching, gUID)
		end
	end

	isDirty = true
end

local function unbindZoneFromGroups(zone: Zone, ...: Group)
	local watching = zoneWatchingGroups[zone.index]
	if not watching then
		return
	end

	local groups = { ... }
	for i = 1, #groups do
		local gUID = groups[i].UID
		local foundIndex = table.find(watching, gUID)
		while foundIndex do
			table.remove(watching, foundIndex)
			foundIndex = table.find(watching, gUID)
		end
	end

	if #watching == 0 then
		zoneWatchingGroups[zone.index] = nil
	end

	isDirty = true
end

local function getGroupsForZone(zone: Zone): { Group }
	local gUIDs = zoneWatchingGroups[zone.index]
	if not gUIDs then
		return {}
	end

	local results = {}
	for _, gUID in gUIDs do
		local groupObj = groupUIDToGroupObject[gUID]
		if groupObj then
			table.insert(results, groupObj)
		end
	end
	return results
end

local function destroyZone(zone: Zone): ()
	zoneWatchingGroups[zone.index] = nil
	zoneIndexToZoneObject[zone.index] = nil
	objects[zone.index] = nil
	pendingRebuild = true
end

local Zone = {}
Zone.__index = Zone

function Zone:bindToGroups(...: Group)
	bindZoneToGroups(self, ...)
end

function Zone:unbindToGroups(...: Group)
	unbindZoneFromGroups(self, ...)
end

function Zone:getGroups()
	return getGroupsForZone(self)
end

function Zone:destroy()
	destroyZone(self)
end

local function newZone(cframe: CFrame, size: Vector3, shape: Shapes, associatedPart: BasePart?): Zone
	local halfSize = size / 2
	local object: BoundingVolume = {
		Position = cframe.Position,
		CFrame = cframe,
		HalfSize = halfSize,
		Shape = shape,
	}

	if shape == "Ball" then
		assert(size.X == size.Y and size.Y == size.Z and size.X == size.Z, "ball does not have a consistent radius")
		object.radius = halfSize.X
	elseif shape == "Cylinder" then
		assert(size.Y == size.Z, "cylinder does not have a consistent radius")
		local halfHeight = object.HalfSize.X
		local radius = object.HalfSize.Y

		local upVector = object.CFrame.RightVector
		local cylinderStart = object.Position - upVector * halfHeight

		object.start = cylinderStart
		object.axis = upVector
		object.axisLength = halfHeight * 2
		object.radiusSquared = radius * radius
	end

	local index = nextZoneId
	nextZoneId += 1
	objects[index] = object
	pendingRebuild = true

	local self = setmetatable({
		index = index,
		part = associatedPart,
	}, Zone)

	zoneIndexToZoneObject[index] = (self :: any) :: Zone

	return (self :: any) :: Zone
end

local function newZoneFromPart(part: BasePart): Zone
	local objectShape: Shapes = "Block"

	if part:IsA("BasePart") then
		local shape = part.Shape
		if shape == Enum.PartType.Block then
			--do nothing
		elseif shape == Enum.PartType.Ball then
			objectShape = "Ball"
		elseif shape == Enum.PartType.Cylinder then
			objectShape = "Cylinder"
		elseif shape == Enum.PartType.Wedge then
			objectShape = "Wedge"
		else
			error("part type " .. shape.Name .. " is not supported")
		end
	end

	return newZone(part.CFrame, part.Size, objectShape, part)
end

local function setFrameBudget(budget: number): ()
	frameBudget = budget
end

local function isItemTracked(trackable: Trackable): boolean
	return trackables[trackable] ~= nil
end

local function trackItemInGroup(group: Group, trackable: Trackable, customData: any?): ()
	if not trackables[trackable] then
		trackables[trackable] = {
			activeGroupMemberships = {},
			memberOfGroups = {},
			isPart = trackable:IsA("BasePart"),
			lastPosition = Vector3.zero,
		}
	end

	if not trackableCustomData[trackable] then
		trackableCustomData[trackable] = {}
	end

	if customData ~= nil then
		trackableCustomData[trackable][group.UID] = customData
	end

	trackables[trackable].memberOfGroups[group.UID] = true
	trackables[trackable].isDirty = true
end

local function untrackItemFromGroup(group: Group, trackable: Trackable): ()
	local trackableData = trackables[trackable]
	if not trackableData then
		return
	end

	local previousZoneIndex = trackableData.activeGroupMemberships[group.UID]

	trackableData.activeGroupMemberships[group.UID] = nil
	trackableData.memberOfGroups[group.UID] = nil

	local previousCustomData
	if trackableCustomData[trackable] then
		previousCustomData = trackableCustomData[trackable][group.UID]
		trackableCustomData[trackable][group.UID] = nil

		if next(trackableCustomData[trackable]) == nil then
			trackableCustomData[trackable] = nil
		end
	end

	if next(trackableData.memberOfGroups) == nil then
		trackables[trackable] = nil
	end

	if previousZoneIndex then
		local callbacks = groupExitedCallbackMap[group.UID]
		if callbacks then
			local zone = zoneIndexToZoneObject[previousZoneIndex]
			for _, callback in callbacks do
				task.spawn(callback, trackable, zone, previousCustomData)
			end
		end
	end
end

local function groupOnEntered(group: Group, callback: Callback): () -> ()
	local target_map = groupEnteredCallbackMap[group.UID]
	table.insert(target_map, callback)

	return function()
		local index = table.find(target_map, callback)
		if index then
			table.remove(target_map, index)
		end
	end
end

local function groupOnExited(group: Group, callback: Callback): () -> ()
	local target_map = groupExitedCallbackMap[group.UID]
	table.insert(target_map, callback)

	return function()
		local index = table.find(target_map, callback)
		if index then
			table.remove(groupExitedCallbackMap[group.UID], index)
		end
	end
end

local function groupSetPriority(group: Group, priority: number): ()
	groupPriorityMap[group.UID] = priority
	isDirty = true
end

local function isItemInsideGroup(trackable: Trackable, group: Group): boolean
	local active = groupActiveMembers[group.UID]
	return active ~= nil and active[trackable] == true
end

local function isItemTrackedByGroup(trackable: Trackable, group: Group): boolean
	local data = trackables[trackable]
	return data ~= nil and data.memberOfGroups[group.UID] == true
end

local function getGroupsForItem(trackable: Trackable): { Group }
	local data = trackables[trackable]
	if not data then
		return {}
	end
	local results = {}
	for gUID in data.memberOfGroups do
		table.insert(results, groupUIDToGroupObject[gUID])
	end
	return results
end

local function getGroupsAtItem(trackable: Trackable): { Group }
	local data = trackables[trackable]
	if not data or not data.lastPosition then
		return {}
	end
	local results = {}
	local added = {}
	pointIntersection(root :: Node, data.lastPosition, function(zIdx)
		local watching = zoneWatchingGroups[zIdx]
		if not watching then
			return
		end
		for _, gUID in watching do
			if not added[gUID] then
				added[gUID] = true
				table.insert(results, groupUIDToGroupObject[gUID])
			end
		end
	end)
	return results
end

local function getItemsForGroup(group: Group): { Trackable }
	local results = {}
	for trackable, data in trackables do
		if data.memberOfGroups[group.UID] then
			table.insert(results, trackable)
		end
	end
	return results
end

local function getItemsInsideGroup(group: Group): { Trackable }
	local active = groupActiveMembers[group.UID]
	if not active then
		return {}
	end
	local results = {}
	for trackable in active do
		table.insert(results, trackable)
	end
	return results
end

local function isPointInsideGroup(position: Vector3, group: Group): boolean
	local found = false
	pointIntersection(root :: Node, position, function(zIdx)
		if found then
			return
		end
		local watching = zoneWatchingGroups[zIdx]
		if watching and table.find(watching, group.UID) then
			found = true
		end
	end)
	return found
end

local function getGroupsAtPoint(position: Vector3): { Group }
	local results, added = {}, {}
	pointIntersection(root :: Node, position, function(zIdx)
		local watching = zoneWatchingGroups[zIdx]
		if not watching then
			return
		end
		for _, gUID in watching do
			if not added[gUID] then
				added[gUID] = true
				table.insert(results, groupUIDToGroupObject[gUID])
			end
		end
	end)
	return results
end

local function getZonesForGroup(group: Group): { Zone }
	local results = {}
	local gUID = group.UID

	for zIdx, watchingUIDs in zoneWatchingGroups do
		if table.find(watchingUIDs, gUID) then
			local zoneObj = zoneIndexToZoneObject[zIdx]
			if zoneObj then
				table.insert(results, zoneObj)
			end
		end
	end

	return results
end

local function destroyGroup(group: Group)
	local gUID = group.UID

	local active = groupActiveMembers[gUID]
	if active then
		local members = {}
		for obj in active do
			table.insert(members, obj)
		end
		for _, obj in members do
			untrackItemFromGroup(group, obj)
		end
	end

	groupActiveMembers[gUID] = nil
	groupPriorityMap[gUID] = nil
	groupUIDToGroupObject[gUID] = nil
	groupEnteredCallbackMap[gUID] = nil
	groupExitedCallbackMap[gUID] = nil

	isDirty = true
end

local Group = {}
Group.__index = Group

function Group:trackItem(trackable: Trackable, customData: any?)
	trackItemInGroup(self, trackable, customData)
end

function Group:untrackItem(trackable: Trackable)
	untrackItemFromGroup(self, trackable)
end

function Group:setPriority(priority: number)
	groupSetPriority(self, priority)
end

function Group:onEntered(callback: Callback)
	return groupOnEntered(self, callback)
end

function Group:onExited(callback: Callback)
	return groupOnExited(self, callback)
end

function Group:isItemInside(trackable: Trackable)
	return isItemInsideGroup(trackable, self)
end

function Group:isPointInside(position: Vector3)
	return isPointInsideGroup(position, self)
end

function Group:isItemTracked(trackable: Trackable)
	return isItemTrackedByGroup(trackable, self)
end

function Group:getTrackedItems()
	return getItemsForGroup(self)
end

function Group:getItemsInside()
	return getItemsInsideGroup(self)
end

function Group:getZones()
	return getZonesForGroup(self)
end

function Group:destroy()
	destroyGroup(self)
end

local function newGroup(priority: number?): Group
	local groupUID = nextGroupId
	nextGroupId += 1

	groupActiveMembers[groupUID] = {}
	groupPriorityMap[groupUID] = priority or 1e6
	groupEnteredCallbackMap[groupUID] = {}
	groupExitedCallbackMap[groupUID] = {}

	local group = setmetatable({
		UID = groupUID,
	}, Group)

	groupUIDToGroupObject[groupUID] = (group :: any) :: Group
	return (group :: any) :: Group
end

do
	local candidatePriorityByGroup = {}
	local candidateIndexByGroup = {}
	local candidateList = {}

	RunService.Heartbeat:Connect(function()
		local forceRefresh = isDirty

		if pendingRebuild then
			debug.profilebegin("QuickBounds_build")

			root = createBVH() :: Node
			pendingRebuild = false
			forceRefresh = true

			debug.profileend()
		end

		isDirty = false

		if #objects == 0 then
			return
		end

		debug.profilebegin("QuickBounds_step")

		local startFrameTime = os.clock()
		local count = 0
		local lastProcessedTrackable

		while true do
			local trackable, trackableData = next(trackables, lastProcessedTrackable)
			lastProcessedTrackable = trackable
			if not trackable then
				break
			end

			local currentPosition = trackableData.isPart and (trackable :: BasePart).Position
				or (trackable :: Camera | Model | WorldModel):GetPivot().Position

			if not forceRefresh and not trackableData.isDirty and trackableData.lastPosition == currentPosition then
				continue
			end

			trackableData.lastPosition = currentPosition
			trackableData.isDirty = false

			table.clear(candidatePriorityByGroup)
			table.clear(candidateIndexByGroup)
			table.clear(candidateList)
			local candidateCount = 0
			local lowestWinningPriority = math.huge

			debug.profilebegin("gather_candidates")

			pointIntersection(root :: Node, currentPosition, function(zoneIndex)
				local watchingGroups = zoneWatchingGroups[zoneIndex]
				if not watchingGroups then
					return
				end

				for _, groupUID in watchingGroups do
					if trackableData.memberOfGroups[groupUID] then
						local priority = groupPriorityMap[groupUID]

						local existingCandidatePriority = candidatePriorityByGroup[groupUID]
						if not existingCandidatePriority or priority < existingCandidatePriority then
							if not existingCandidatePriority then
								candidateCount += 1
								candidateList[candidateCount] = groupUID
							end

							candidateIndexByGroup[groupUID] = zoneIndex
							candidatePriorityByGroup[groupUID] = priority

							if priority < lowestWinningPriority then
								lowestWinningPriority = priority
							end
						end
					end
				end
			end)

			debug.profileend()

			debug.profilebegin("resolve_and_fire")

			local currentMemberships = trackableData.activeGroupMemberships

			for groupUID, oldZoneIndex in currentMemberships do
				local newPriority = candidatePriorityByGroup[groupUID]
				if not newPriority or newPriority > lowestWinningPriority then
					currentMemberships[groupUID] = nil
					groupActiveMembers[groupUID][trackable] = nil

					local callbacks = groupExitedCallbackMap[groupUID]
					if callbacks then
						task.spawn(function()
							local zone = zoneIndexToZoneObject[oldZoneIndex]
							local data = trackableCustomData[trackable][groupUID]
							for _, cb in callbacks do
								cb(trackable, zone, data)
							end
						end)
					end
				end
			end

			for i = 1, candidateCount do
				local groupUID = candidateList[i]
				local priority = candidatePriorityByGroup[groupUID]

				if priority <= lowestWinningPriority then
					if not currentMemberships[groupUID] then
						local newZoneIndex = candidateIndexByGroup[groupUID]
						currentMemberships[groupUID] = newZoneIndex
						groupActiveMembers[groupUID][trackable] = true

						local callbacks = groupEnteredCallbackMap[groupUID]
						if callbacks then
							task.spawn(function()
								local zone = zoneIndexToZoneObject[newZoneIndex]
								local data = trackableCustomData[trackable][groupUID]
								for _, cb in callbacks do
									cb(trackable, zone, data)
								end
							end)
						end
					end
				end
			end

			debug.profileend()

			count += 1
			if count % 32 == 0 and os.clock() - startFrameTime > frameBudget then
				break
			end
		end

		debug.profileend()
	end)
end

return {
	-- constructors
	newZone = newZone,
	newZoneFromPart = newZoneFromPart,
	newGroup = newGroup,

	-- queries
	isItemTracked = isItemTracked,
	getGroupsForItem = getGroupsForItem,
	getGroupsAtItem = getGroupsAtItem,
	getGroupsAtPoint = getGroupsAtPoint,

	-- config
	setFrameBudget = setFrameBudget,
}
