--!native
--!optimize 2
--!strict

local RunService = game:GetService("RunService")

type ListItem = {
	id: number,
	mortonCode: number
}

type Node = {
	left: Node?,
	right: Node?,
	min: Vector3,
	max: Vector3,
	id: number
}

type BoundingVolume = {
	Shape: "Block" | "Ball" | "Cylinder" | "Wedge",
	Position: Vector3,
	CFrame: CFrame,
	HalfSize: Vector3,

	--for the ball
	radius: number?,

	--these are all for optimized cylinder calculations...
	start: Vector3?,
	axis: Vector3?,
	axisLength: number?,
	radiusSquared: number?
}

local objects: {BoundingVolume} = {}
local nextZoneId = 1

local function unionBounds(nodeA: Node, nodeB: Node): (Vector3, Vector3)
	if not nodeA then return nodeB.min, nodeB.max end
	if not nodeB then return nodeA.min, nodeA.max end
	return vector.min(nodeA.min, nodeB.min), vector.max(nodeA.max, nodeB.max)
end

local function getObjectBounds(object: BoundingVolume): (Vector3, Vector3)
	local halfSize = object.HalfSize
	local cframe = object.CFrame
	local center = object.Position

	local halfExtent = vector.abs(cframe.RightVector) * halfSize.X +
		vector.abs(cframe.UpVector) * halfSize.Y +
		vector.abs(cframe.LookVector) * halfSize.Z

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
		vector.clamp(
			(position - sceneBoundsMin) / (sceneBoundsMax - sceneBoundsMin),
			vector.zero,
			vector.one
		) * 1023
	)

	return bit32.bor(
		expandBits(scaled.x),
		bit32.lshift(expandBits(scaled.y), 1),
		bit32.lshift(expandBits(scaled.z), 2)
	)
end

local function getSplitPos(list: {ListItem}, beginIndex: number, endIndex: number): number?
	if (endIndex - beginIndex + 1) < 2 then
		return nil
	end

	if endIndex == beginIndex + 1 then
		return beginIndex + 1
	end

	local first = list[beginIndex].mortonCode
	local last  = list[endIndex].mortonCode

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

	local padding = vector.max(vector.one, (max - min) * .01)
	return min - padding, max + padding
end

local function createSubTree(list: {ListItem}, boundsMin: {Vector3}, boundsMax: {Vector3}, beginIndex: number, endIndex: number): Node
	if beginIndex == endIndex then
		local id = list[beginIndex].id
		return {
			min = boundsMin[id],
			max = boundsMax[id],
			id = id
		}
	else
		local mid = getSplitPos(list, beginIndex, endIndex)
		if mid == nil then
			--treat as leaf
			local id = list[beginIndex].id
			return {
				min = boundsMin[id],
				max = boundsMax[id],
				id = id
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
			right = right
		}
	end
end

local function createBVH(): Node?
	local sceneBoundsMin, sceneBoundsMax = calculateSceneBounds()

	local list: {ListItem} = {}
	local objectBoundsMin = {}
	local objectBoundsMax = {}

	for id, object in objects do
		local boundsMin, boundsMax = getObjectBounds(object)
		objectBoundsMin[id] = boundsMin
		objectBoundsMax[id] = boundsMax

		local mortonCode = positionToMortonCode(object.Position, sceneBoundsMin, sceneBoundsMax)
		table.insert(list, {id = id, mortonCode = mortonCode})
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

local function pointIntersection(node: Node, point: Vector3, callback: (nodeId: number) -> ()): ()
	if not node or vector.clamp(point, node.min, node.max) ~= point then
		return
	end

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
			--all these type casts cuz the fields are technically optional
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
				if localPoint.Y/size.Y - localPoint.Z/size.Z <= 0 then
					callback(node.id)
				end
			end
		end

		return
	end

	pointIntersection(node.left :: Node, point, callback)
	pointIntersection(node.right :: Node, point, callback)
end

--for my own sanity
type GroupUID = number
type ZoneIndex = number

export type Shapes = "Block" | "Ball" | "Cylinder" | "Wedge"
export type Callback = (part: BasePart, zone: Zone, customData: any?) -> ()

export type Zone = {
	watchGroups: (zone: Zone, ...Group) -> (),
	unwatchGroups: (zone: Zone, ...Group) -> (),
	destroy: (zone: Zone) -> (),
	index: number,
	part: BasePart?
}

export type Group = {
	add: (group: Group, part: BasePart, customData: any?) -> (),
	remove: (group: Group, part: BasePart) -> (),
	setPriority: (group: Group, priority: number) -> (),
	onEntered: (group: Group, callback: Callback) -> () -> (),
	onExited: (group: Group, callback: Callback) -> () -> (),
	UID: number
}

local frameBudget = 1/1000 --1ms by default
local nextGroupId = 1
local pendingRebuild = false
local root: Node? = nil

type PartData = {
	activeGroupMemberships: {[GroupUID]: ZoneIndex},
	memberOfGroups: {[GroupUID]: boolean}
}

local partCount = 0
local partInformation: {[BasePart]: PartData} = {}
local partCustomData: {[BasePart]: {[GroupUID]: any}} = {}

local groupPriorityMap: {[GroupUID]: number} = {}
local groupUIDToGroupObject: {[GroupUID]: Group} = {}
local groupEnteredCallbackMap: {[GroupUID]: {Callback}} = {}
local groupExitedCallbackMap: {[GroupUID]: {Callback}} = {}

local zoneWatchingGroups: {[ZoneIndex]: {GroupUID}} = {}
local zoneIndexToZoneObject: {[ZoneIndex]: Zone} = {}

local function zoneWatchGroups(zone: Zone, ...: Group)
	if not zoneWatchingGroups[zone.index] then
		zoneWatchingGroups[zone.index] = {}
	end

	for _, group in {...} do
		table.insert(zoneWatchingGroups[zone.index], group.UID)
	end
end

local function zoneUnwatchGroups(zone: Zone, ...: Group)
	if not zoneWatchingGroups[zone.index] then
		return
	end

	for _, group in {...} do
		local index = table.find(zoneWatchingGroups[zone.index], group.UID)
		if index then
			table.remove(zoneWatchingGroups[zone.index], index)
		end
	end

	if #zoneWatchingGroups[zone.index] == 0 then
		zoneWatchingGroups[zone.index] = nil
	end
end

local function zoneDestroy(zone: Zone): ()
	zoneWatchingGroups[zone.index] = nil
	zoneIndexToZoneObject[zone.index] = nil
	objects[zone.index] = nil
	pendingRebuild = true
end

local function createZone(cframe: CFrame, size: Vector3, shape: Shapes, associatedPart: BasePart?): Zone
	local halfSize = size / 2
	local object: BoundingVolume = {
		Position = cframe.Position,
		CFrame = cframe,
		HalfSize = halfSize,
		Shape = shape
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

	local zone = {
		watchGroups = zoneWatchGroups,
		unwatchGroups = zoneUnwatchGroups,
		destroy = zoneDestroy,
		part = associatedPart,
		index = index
	}

	zoneIndexToZoneObject[index] = zone

	return zone
end

local function createZoneFromInstance(part: BasePart): Zone
	local objectShape: Shapes = "Block"

	if part:IsA("Part") then
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

	return createZone(part.CFrame, part.Size, objectShape, part)
end

local function setFrameBudget(budget: number): ()
	frameBudget = budget
end

local function groupAdd(group: Group, part: BasePart, customData: any?): ()
	if not partInformation[part] then
		partCount += 1

		partInformation[part] = {
			activeGroupMemberships = {},
			memberOfGroups = {}
		}
	end

	if not partCustomData[part] then
		partCustomData[part] = {}
	end

	if customData ~= nil then
		partCustomData[part][group.UID] = customData
	end

	partInformation[part].memberOfGroups[group.UID] = true
end

local function groupRemove(group: Group, part: BasePart): ()
	local partData = partInformation[part]
	if not partData then
		return
	end

	partCount -= 1

	local previousZoneIndex = partData.activeGroupMemberships[group.UID]

	partData.activeGroupMemberships[group.UID] = nil
	partData.memberOfGroups[group.UID] = nil

	local previousCustomData
	if partCustomData[part] then
		previousCustomData = partCustomData[part][group.UID]
		partCustomData[part][group.UID] = nil

		if next(partCustomData[part]) == nil then
			partCustomData[part] = nil
		end
	end

	if next(partData.memberOfGroups) == nil then
		partInformation[part] = nil
	end

	if previousZoneIndex then
		local callbacks = groupExitedCallbackMap[group.UID]
		if callbacks then
			local zone = zoneIndexToZoneObject[previousZoneIndex]
			for _, callback in callbacks do
				task.spawn(callback, part, zone, previousCustomData)
			end
		end
	end
end

local function groupSetPriority(group: Group, priority: number): ()
	groupPriorityMap[group.UID] = priority
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

local function createGroup(priority: number?): Group
	local groupUID = nextGroupId
	nextGroupId += 1

	groupPriorityMap[groupUID] = priority or 1e6
	groupEnteredCallbackMap[groupUID] = {}
	groupExitedCallbackMap[groupUID] = {}

	local group = {
		add = groupAdd,
		remove = groupRemove,
		setPriority = groupSetPriority,
		onEntered = groupOnEntered,
		onExited = groupOnExited,
		UID = groupUID
	}

	groupUIDToGroupObject[groupUID] = group

	return group
end

do
	local lastProcessedPart
	RunService.Heartbeat:Connect(function(deltaTime)
		if pendingRebuild then
			debug.profilebegin("QuickBounds_build")

			root = createBVH() :: Node
			pendingRebuild = false

			debug.profileend()
		end

		if #objects == 0 then
			return
		end

		local processed = 0

		debug.profilebegin("QuickBounds_step")

		local runTime = 0
		while runTime <= frameBudget and processed < partCount do
			local part, partData = next(partInformation, lastProcessedPart)

			lastProcessedPart = part
			if not lastProcessedPart then
				continue
			end

			local startTime = os.clock()

			local previousState = table.clone(partData.activeGroupMemberships)

			local currentPosition = (part :: BasePart).Position

			local candidatePriorityByGroup = {}
			local candidateIndexByGroup = {}

			debug.profilebegin("gather_candidates")

			pointIntersection(root :: Node, currentPosition, function(zoneIndex)
				local watchingGroups = zoneWatchingGroups[zoneIndex]
				if not watchingGroups then
					return
				end

				for _, groupUID in watchingGroups do
					if partData.memberOfGroups[groupUID] then
						local priority = groupPriorityMap[groupUID]

						local existingCandidatePriority = candidatePriorityByGroup[groupUID]
						if not existingCandidatePriority or priority < existingCandidatePriority then
							candidateIndexByGroup[groupUID] = zoneIndex
							candidatePriorityByGroup[groupUID] = priority
						end
					end
				end
			end)

			debug.profileend()

			debug.profilebegin("resolve_candidates")

			local candidateGroupByPriority: {{number}} = {}
			local priorityLevels = {}

			for groupUID, priority in candidatePriorityByGroup do
				if not candidateGroupByPriority[priority] then
					candidateGroupByPriority[priority] = {}
				end
				table.insert(candidateGroupByPriority[priority], groupUID)
				table.insert(priorityLevels, priority)
			end

			table.sort(priorityLevels)

			local newState = {}
			local hasWinnersAtPriority = {}

			for _, priority in priorityLevels do
				local candidatesAtThisPriority = candidateGroupByPriority[priority]

				for _, candidateGroupUID in candidatesAtThisPriority do
					local newZoneIndex = candidateIndexByGroup[candidateGroupUID]
					local previousZoneIndex = previousState[candidateGroupUID]

					newState[candidateGroupUID] = if previousZoneIndex then previousZoneIndex else newZoneIndex
					hasWinnersAtPriority[priority] = true
				end
			end

			local lowestWinningPriority = nil
			for _, priority in priorityLevels do
				if hasWinnersAtPriority[priority] then
					lowestWinningPriority = priority
					break
				end
			end

			if lowestWinningPriority then
				local finalState = {}
				for groupUID, zoneIndex in newState do
					local groupPriority = groupPriorityMap[groupUID]
					if groupPriority <= lowestWinningPriority then
						finalState[groupUID] = zoneIndex
					end
				end
				newState = finalState
			end

			debug.profileend()

			partData.activeGroupMemberships = newState

			debug.profilebegin("fire_callbacks")

			for groupUID, newZoneIndex in newState do
				if not previousState[groupUID] then
					local callbacks = groupEnteredCallbackMap[groupUID]
					if callbacks then
						local zone = zoneIndexToZoneObject[newZoneIndex]
						local data = partCustomData[part :: BasePart][groupUID]
						for _, callback in callbacks do
							task.spawn(callback, part :: BasePart, zone, data)
						end
					end
				end
			end

			for groupUID, previousZoneIndex in previousState do
				if not newState[groupUID] then
					local callbacks = groupExitedCallbackMap[groupUID]
					if callbacks then
						local zone = zoneIndexToZoneObject[previousZoneIndex]
						local data = partCustomData[part :: BasePart][groupUID]
						for _, callback in callbacks do
							task.spawn(callback, part :: BasePart, zone, data)
						end
					end
				end
			end

			debug.profileend()

			local endTime = os.clock()
			runTime += (endTime - startTime)

			processed += 1
		end

		debug.profileend()
	end)
end

local function isPartInGroup(part: BasePart, group: Group): boolean
	return partInformation[part] and partInformation[part].memberOfGroups[group.UID]
end

local function getGroupsForPart(part: BasePart): {Group}
	if not partInformation[part] then
		return {}
	end

	local groups = {}

	for groupUID in partInformation[part].memberOfGroups do
		table.insert(groups, groupUIDToGroupObject[groupUID])
	end

	return groups
end

local function getPartsForGroup(group: Group): {BasePart}
	local parts = {}
	local groupUID = group.UID

	for part, data in partInformation do
		if data.memberOfGroups[groupUID] then
			table.insert(parts, part)
		end
	end

	return parts
end

return {
	createZone = createZone,
	createZoneFromInstance = createZoneFromInstance,
	setFrameBudget = setFrameBudget,
	createGroup = createGroup,

	isPartInGroup = isPartInGroup,
	getGroupsForPart = getGroupsForPart,
	getPartsForGroup = getPartsForGroup
}