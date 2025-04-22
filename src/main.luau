--!native
--!optimize 2
--i would turn on strict but the vector and Vector3 incompability warnings are annoying

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

--[=[
	@interface BoundingVolume 
	@field Shape "Box" | "Ball" | "Cylinder",
	@field Position Vector3,
	@field CFrame CFrame,
	@field HalfSize Vector3,
	@field Index number,
	@field MortonCode number,
	@field radius number?,
	@field start Vector3?,
	@field axis Vector3?,
	@field axisLength number?,
	@field radiusSquared number?
	
	Internal object that the BVH interacts with, only ever exposed through getAllZonesForGroup.
	Radius is only used for balls and axis, axisLength and radiusSquared are all used for cylinders.

	@within QuickBounds
]=]
type BoundingVolume = {
	Shape: "Box" | "Ball" | "Cylinder",
	Position: Vector3,
	CFrame: CFrame,
	HalfSize: Vector3,

	Index: number,
	MortonCode: number,

	--for the sphere
	radius: number?,

	--these are all for optimized cylinder calculations...
	start: Vector3?,
	axis: Vector3?,
	axisLength: number?,
	radiusSquared: number?
}

local objects: {BoundingVolume} = {}
local holes = {}

local function unionBounds(nodeA: Node, nodeB: Node): (Vector3, Vector3)
	if not nodeA then return nodeB.min, nodeB.max end
	if not nodeB then return nodeA.min, nodeA.max end
	return vector.min(nodeA.min, nodeB.min), vector.max(nodeA.max, nodeB.max)
end

local function getObjectBounds(object: BoundingVolume): (Vector3, Vector3)
	local halfSize = object.HalfSize
	local cframe = object.CFrame
	local center = object.Position

	local e = vector.abs(cframe.RightVector) * halfSize.X +
		vector.abs(cframe.UpVector) * halfSize.Y +
		vector.abs(cframe.LookVector) * halfSize.Z

	return center - e, center + e
end

--surprisingly not a bottleneck at all
local function expandBits(value)
	value = bit32.band(value, 0x3FF)
	value = bit32.bor(bit32.lshift(value, 16), value)
	value = bit32.band(value, 0xFF0000FF)
	value = bit32.bor(bit32.lshift(value, 8), value)
	value = bit32.band(value, 0xF00F00F)
	value = bit32.bor(bit32.lshift(value, 4), value)
	value = bit32.band(value, 0x30C30C3)
	value = bit32.bor(bit32.lshift(value, 2), value)
	value = bit32.band(value, 0x9249249)
	return value
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

local function getSplitPos(list: {ListItem}, beginIndex: number, endIndex: number): number
	if endIndex == beginIndex + 1 then
		return beginIndex + 1
	end

	local firstCode = list[beginIndex].mortonCode
	local lastCode = list[endIndex].mortonCode

	if firstCode == lastCode then
		return (beginIndex + endIndex) // 2
	end

	local commonPrefix = bit32.countrz(bit32.bxor(firstCode, lastCode))

	local mid = beginIndex
	local step = endIndex - beginIndex

	while step > 1 do
		step = math.ceil(step / 2)
		local newMid = mid + step

		if newMid < endIndex then
			local splitPrefix = bit32.countrz(bit32.bxor(firstCode, list[newMid].mortonCode))
			if splitPrefix > commonPrefix then
				mid = newMid
			end
		end
	end

	return mid + 1
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

	table.sort(list, function(a, b)
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
		return nil
	end

	if node.id > 0 then
		local object = objects[node.id]

		if object.Shape == "Box" then
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
		end

		return nil
	end

	pointIntersection(node.left, point, callback)
	pointIntersection(node.right, point, callback)
end

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

--[=[
    @type Groups "Players" | string
    @within QuickBounds
]=]
type Groups = "Players" | string

--[=[
    @class Zone
]=]
type Zone = {
	_index: number,
	remove: (zone: Zone) -> (),
	watchGroups: (zone: Zone, ...Groups) -> (),
	unwatchGroups: (zone: Zone, ...Groups) -> ()
}

--[=[
    @class QuickBounds
]=]
local QuickBounds = {}

local watching = {}
local partData = {}
local callbacks = {}

local tree: Node = nil
local pendingRebuild = false

local frameBudget = .0002
do
	local lastProcessedPart = nil
	RunService.PostSimulation:Connect(function()
		if pendingRebuild then
			tree = createBVH()
			pendingRebuild = false
		end

		local runTime = 0

		while runTime < frameBudget do
			local part, data = next(partData, lastProcessedPart)

			lastProcessedPart = part
			if not lastProcessedPart then
				break
			end

			local groups = data.groups
			local customData = data.customData

			local insideOf = {}

			local startTime = os.clock()
			local firstOccurence = false
			pointIntersection(tree, part.Position, function(nodeId)
				if not firstOccurence then
					runTime += (os.clock() - startTime)
					firstOccurence = true
				end

				local zoneWatching = watching[nodeId]

				for _, group in zoneWatching do
					local currentState = groups[group]
					local overwrite = customData[group]

					if currentState ~= nil then
						insideOf[group] = true

						if not currentState then
							groups[group] = true

							local groupCallbacks = callbacks[group]
							if groupCallbacks then
								for _, callback in groupCallbacks.entered do
									task.spawn(callback, part, overwrite)
								end
							end
						end
					end
				end
			end)

			for group, state in groups do
				if not insideOf[group] and state then
					groups[group] = false

					local groupCallbacks = callbacks[group]
					local overwrite = customData[group]
					if groupCallbacks then
						for _, callback in groupCallbacks.exited do
							task.spawn(callback, part, overwrite)
						end
					end
				end
			end
		end
	end)
end

local function insert(object)
	if #holes > 0 then
		local hole = table.remove(holes, 1)
		objects[hole] = object
		return hole
	else
		table.insert(objects, object)
		return #objects
	end
end

--[=[
    @method remove
    @within Zone

    Removes the Zone from the BVH, requires a rebuild for the effect to show.
]=]
local function removeZone(zone: Zone): ()
	local index = zone._index
	watching[index] = nil

	if index < #objects then
		table.insert(holes, index)
		objects[index] = nil
	else
		table.remove(objects)
	end
	
	table.clear(zone)
	pendingRebuild = true
end

--[=[
    @method watchGroups
    @within Zone
    @param ... Groups
    
    ```lua
    zone:watchGroups("Players", "NPCs", "Vehicles")
    ```
]=]
local function watchGroup(zone: Zone, ...: Groups): ()
	for _, group in {...} do
		table.insert(watching[zone._index], group)
	end
end

--[=[
    @method unwatchGroups
    @within Zone
    @param ... Groups
    
    ```lua
    zone:unwatchGroups("Vehicles")
    ```
]=]
local function unwatchGroup(zone: Zone, ...: Groups): ()
	local currentlyWatching = watching[zone._index]
	for _, group in {...} do
		local index = table.find(currentlyWatching, group)
		if index then
			table.remove(currentlyWatching, index)
		end
	end
end

--[=[
    @function add
    @within QuickBounds
    @param cframe CFrame
    @param size Vector3
    @param shape "Box" | "Cylinder" | "Sphere"
    @return Zone

    Requires a rebuild for the zone to start working as intended.
]=]
function QuickBounds.add(cframe: CFrame, size: Vector3, shape: "Box" | "Cylinder" | "Sphere"): Zone
	local halfSize = size / 2
	local object: BoundingVolume = {
		Position = cframe.Position,
		CFrame = cframe,
		HalfSize = halfSize,
		Shape = shape
	}

	if shape == "Sphere" then
		assert(size.X == size.Y and size.Y == size.Z and size.X == size.Z, "sphere does not have a consistent radius")
		object.radius = halfSize.X
	elseif shape == "Cylinder" then
		assert(size.Y == size.Z, "cylinder does not have a consistent radius")
		--i hate cylinders why is the height X and why is the "real" upvector just RightVector
		local halfHeight = object.HalfSize.X
		local radius = object.HalfSize.Y

		local upVector = object.CFrame.RightVector
		local cylinderStart = object.Position - upVector * halfHeight

		object.start = cylinderStart
		object.axis = upVector
		object.axisLength = halfHeight * 2
		object.radiusSquared = radius * radius
	end

	local index = insert(object)
	watching[index] = {}
	pendingRebuild = true

	return {
		_index = index,
		remove = removeZone,
		watchGroups = watchGroup,
		unwatchGroups = unwatchGroup
	}
end

--[=[
    @function addFromInstance
    @within QuickBounds
    @param part BasePart
    @return Zone

    Requires a rebuild for the zone to start working as intended.
]=]
function QuickBounds.addFromInstance(part: BasePart): Zone
	local objectShape = "Box"

	if part:IsA("Part") then
		local shape = part.Shape
		if shape == Enum.PartType.Block then
			--do nothing i just dont wanna error cuh!
		elseif shape == Enum.PartType.Ball then
			objectShape = "Sphere"
		elseif shape == Enum.PartType.Cylinder then
			objectShape = "Cylinder"
		else
			error("part type", shape.Name, "is not supported")
		end
	end

	return QuickBounds.add(part.CFrame, part.Size, objectShape)
end

--[=[
    @function assignToGroup
    @within QuickBounds
    @param group string
    @param part BasePart 
    @param callbackData any? --optional data to pass to callbacks

    Associates a BasePart with a group, if callbackData is specified, then it is specific to that group.
]=]
function QuickBounds.assignToGroup(group: Groups, part: BasePart, callbackData: any?)
	if partData[part] then
		partData[part].groups[group] = false
		partData[part].customData[group] = callbackData
	else
		partData[part] = {
			groups = {[group] = false},
			connection = part.AncestryChanged:Connect(function(_, newParent)
				if newParent == nil then
					partData[part].connection:Disconnect()
					partData[part] = nil
				end
			end),
			customData = {[group] = callbackData}
		}
	end
end

--[=[
    @function removeFromGroup
    @within QuickBounds
    @param group string
    @param part BasePart

    Removes a BasePart from a group, if the BasePart is not a member of any group after this operation, it gets cleaned up.
]=]
function QuickBounds.removeFromGroup(group: Groups, part: BasePart)
	if not partData[part] then
		return
	end

	partData[part].groups[group] = nil
	if not next(partData[part].groups) then
		partData[part].connection:Disconnect()
		partData[part] = nil
	end
end

--[=[
    @function onEntered
    @within QuickBounds
    @param group Groups
    @param callback function
    @return () -> () --a function that if called will disconnect the callback
    
    ```lua
    --parts internally registered to the "Players" group pass the Player object as the second argument in the callback
    QuickBounds.onEntered("Players", function(_, player)
        print(player.Name .. " entered a zone!")
    end)
    ```
]=]
function QuickBounds.onEntered(group: Groups, callback: (Part | any) -> ()): () -> ()
	if not callbacks[group] then
		callbacks[group] = {entered = {}, exited = {}}
	end

	table.insert(callbacks[group].entered, callback)
	local index = #callbacks[group].entered

	return function()
		callbacks[group].entered[index] = nil
		if #callbacks[group].entered + #callbacks[group].exited == 0 then
			callbacks[group] = nil
		end
		index = nil
	end
end

--[=[
    @function onExited
    @within QuickBounds
    @param group Groups
    @param callback function
    @return () -> () --a function that if called will disconnect the callback
    
    ```lua
    --parts internally registered to the "Players" group pass the Player object as the second argument in the callback
    QuickBounds.onExited("Players", function(_, player)
        print(player.Name .. " exited a zone!")
    end)
    ```
]=]
function QuickBounds.onExited(group: Groups, callback: (Part | any) -> ()): () -> ()
	if not callbacks[group] then
		callbacks[group] = {entered = {}, exited = {}}
	end

	table.insert(callbacks[group].exited, callback)
	local index = #callbacks[group].exited

	return function()
		callbacks[group].exited[index] = nil
		if #callbacks[group].entered + #callbacks[group].exited == 0 then
			callbacks[group] = nil
		end
		index = nil
	end
end

--[=[
    @function setFrameBudgetMs
    @within QuickBounds
    @param budget number
    
    Set the target frame budget in milliseconds.
]=]
function QuickBounds.setFrameBudgetMs(budget: number)
	frameBudget = budget / 1000
end

--[=[
    @function getGroupsForPart
    @within QuickBounds
    @param part BasePart
    @return {Groups}
    
    Get all groups that the part is inside of.
]=]
function QuickBounds.getGroupsForPart(part: BasePart): {Groups}
	local data = partData[part]

	local groups = {}
	if data then
		for group, state in data.groups do
			if state then
				table.insert(groups, group)
			end
		end
	end

	return groups
end

--[=[
    @function isPartInGroup
    @within QuickBounds
    @param part BasePart
    @param group Groups
    @return boolean
    
    Checks whether a part is inside of a certain group.
]=]
function QuickBounds.isPartInGroup(part: BasePart, group: Groups): boolean
	local data = partData[part]

	if not data then
		return false
	end

	return data.groups[group] == true
end

--[=[
    @function getPartsForGroup
    @within QuickBounds
    @param group Groups
    @return {BasePart}
    
    Get all parts that the group contains.
]=]
function QuickBounds.getPartsForGroup(group: Groups): {BasePart}
	local parts = {}

	for part, data in partData do
		if data.groups[group] then
			table.insert(parts, part)
		end
	end

	return parts
end

--[=[
    @function getAllZonesForGroup
    @within QuickBounds
    @param group Groups
    @return {BoundingVolume}
    
    Get all zone objects that are part of a group.
]=]
function QuickBounds.getAllZonesForGroup(group: Groups): {BoundingVolume}
	local gatheredObjects = {}
	for index, groups in watching do
		if table.find(groups, group) then
			table.insert(gatheredObjects, objects[index])
		end
	end
	return gatheredObjects
end

--[=[
    @function getCustomPartData
    @within QuickBounds
    @param part BasePart
    @param group Groups
    @return any?
    
    Get the custom part data associated with a group.
]=]
function QuickBounds.getCustomPartData(part: BasePart, group: Groups): any?
	local data = partData[part]
	if not data then
		return nil
	end

	return data.customData[group]
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		local humanoidRootPart = character.HumanoidRootPart
		QuickBounds.assignToGroup("Players", humanoidRootPart, player)
	end)
end)

return QuickBounds