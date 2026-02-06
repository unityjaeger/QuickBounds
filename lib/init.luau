--!native
--!optimize 2
--!strict

local RunService = game:GetService("RunService")

local Geometry = require(script.Geometry)
local SpatialIndex = require(script.SpatialIndex)

type TrackableTable = {
	Position: Vector3?,
	WorldPosition: Vector3?,
	CFrame: CFrame?,
	GetPivot: ((self: any) -> CFrame)?,
	[any]: any,
}

export type Trackable = BasePart | Model | Camera | Attachment | Bone | TrackableTable

type UID = number

type TrackableData = {
	activeGroupMemberships: { [UID]: number },
	memberOfGroups: { [UID]: boolean },
	lastPosition: Vector3,
	strategy: number,
	isDirty: boolean,
}

export type Zone = {
	bindToGroups: (zone: Zone, ...Group) -> (),
	unbindToGroups: (zone: Zone, ...Group) -> (),
	getGroups: (zone: Zone) -> { Group },
	destroy: (zone: Zone) -> (),

	index: number,
	part: BasePart?,
}

type Callback = (Trackable, Zone, any?) -> ()

export type Group = {
	trackItem: (self: Group, trackable: Trackable, customData: any?) -> (),
	untrackItem: (self: Group, trackable: Trackable) -> (),
	setPriority: (self: Group, priority: number) -> (),
	isItemInside: (self: Group, trackable: Trackable) -> boolean,
	isPointInside: (self: Group, position: Vector3) -> boolean,
	isItemTracked: (self: Group, trackable: Trackable) -> boolean,
	getTrackedItems: (self: Group) -> { Trackable },
	getItemsInside: (self: Group) -> { Trackable },
	getZones: (self: Group) -> { Zone },
	destroy: (self: Group) -> (),
	onEntered: (self: Group, callback: Callback) -> () -> (),
	onExited: (self: Group, callback: Callback) -> () -> (),

	UID: UID,
}

local objects: { Geometry.BoundingVolume } = {}
local nextZoneId: number = 1
local nextGroupId: number = 1

local trackables: { [Trackable]: TrackableData } = setmetatable({}, { __mode = "k" }) :: any
local trackableCustomData: { [Trackable]: { [number]: any } } = setmetatable({}, { __mode = "k" }) :: any

local groupActiveMembers: { [number]: { [Trackable]: boolean } } = {}
local groupPriorityMap: { [number]: number } = {}
local groupEnteredCallbacks: { [number]: { any } } = {}
local groupExitedCallbacks: { [number]: { any } } = {}

local zoneWatchingGroups: { [number]: { number } } = {}
local zoneIndexToZoneObj: { [number]: Zone } = {}
local groupUIDToGroupObj: { [number]: Group } = {}

local rootNode: SpatialIndex.Node? = nil
local isDirty: boolean = false
local pendingRebuild: boolean = false
local frameBudget: number = 1 / 1000

local STRATEGY = { POS = 1, PRIM = 2, WORLD = 3, CFRAME = 4, PIVOT = 5 }

-- Zone Implementation --
local Zone = {}
Zone.__index = Zone

function Zone:bindToGroups(...)
	local watching = zoneWatchingGroups[self.index] or {}
	zoneWatchingGroups[self.index] = watching
	for _, g in { ... } do
		if not table.find(watching, g.UID) then
			table.insert(watching, g.UID)
		end
	end
	isDirty = true
end

function Zone:unbindToGroups(...)
	local watching = zoneWatchingGroups[self.index]
	if not watching then
		return
	end

	for _, g in { ... } do
		local idx = table.find(watching, g.UID)
		while idx do
			table.remove(watching, idx)
			idx = table.find(watching, g.UID)
		end
	end
	if #watching == 0 then
		zoneWatchingGroups[self.index] = nil
	end
	isDirty = true
end

function Zone:getGroups(): { Group }
	local watching = zoneWatchingGroups[self.index]
	if not watching then
		return {}
	end

	local result = {}
	for _, uid in watching do
		local group = groupUIDToGroupObj[uid]
		if group then
			table.insert(result, group)
		end
	end
	return result
end

function Zone:destroy()
	zoneWatchingGroups[self.index] = nil
	zoneIndexToZoneObj[self.index] = nil
	objects[self.index] = nil
	pendingRebuild = true
end

local function newZone(cframe: CFrame, size: Vector3, shape: Geometry.ShapeType, associatedPart: BasePart?): Zone
	local halfSize = size / 2
	local object: Geometry.BoundingVolume = {
		Position = cframe.Position,
		CFrame = cframe,
		HalfSize = halfSize,
		Shape = shape,
	}

	if shape == "Ball" then
		object.radius = halfSize.X
	elseif shape == "Cylinder" then
		local halfHeight = halfSize.X
		object.start = object.Position - object.CFrame.RightVector * halfHeight
		object.axis = object.CFrame.RightVector
		object.axisLength = halfHeight * 2
		object.radiusSquared = halfSize.Y * halfSize.Y
	end

	local index = nextZoneId
	nextZoneId += 1
	objects[index] = object
	pendingRebuild = true

	local self = setmetatable({ index = index, part = associatedPart }, Zone)
	zoneIndexToZoneObj[index] = (self :: any) :: Zone
	return (self :: any) :: Zone
end

local function newZoneFromPart(part: BasePart): Zone
	local shape: Geometry.ShapeType = "Block"
	if (part :: any).Shape == Enum.PartType.Ball then
		shape = "Ball"
	elseif (part :: any).Shape == Enum.PartType.Cylinder then
		shape = "Cylinder"
	end

	return newZone(part.CFrame, part.Size, shape, part)
end

-- Group Implementation --
local Group = {}
Group.__index = Group

function Group:trackItem(trackable: Trackable, customData: any?)
	local data = trackables[trackable]
	if not data then
		local strat
		if typeof(trackable) == "Instance" then
			if trackable:IsA("BasePart") then
				strat = STRATEGY.POS
			elseif trackable:IsA("Attachment") or trackable:IsA("Bone") then
				strat = STRATEGY.WORLD
			elseif trackable:IsA("Camera") then
				strat = STRATEGY.CFRAME
			elseif trackable:IsA("Model") then
				strat = trackable.PrimaryPart and STRATEGY.PRIM or STRATEGY.PIVOT
			end
		elseif typeof(trackable) == "table" then
			if trackable.Position then
				strat = STRATEGY.POS
			elseif trackable.CFrame then
				strat = STRATEGY.CFRAME
			elseif trackable.WorldPosition then
				strat = STRATEGY.WORLD
			elseif trackable.GetPivot then
				strat = STRATEGY.PIVOT
			end
		end

		if not strat then
			error("Invalid trackable")
			return
		end

		data = {
			activeGroupMemberships = {},
			memberOfGroups = {},
			lastPosition = Vector3.zero,
			strategy = strat,
			isDirty = true,
		}
		trackables[trackable] = data
	end

	if customData ~= nil then
		if not trackableCustomData[trackable] then
			trackableCustomData[trackable] = {}
		end
		trackableCustomData[trackable][self.UID] = customData
	end

	data.memberOfGroups[self.UID] = true
	data.isDirty = true
end

function Group:untrackItem(trackable: Trackable)
	local data = trackables[trackable]
	if not data then
		return
	end

	-- Exit logic
	local oldZoneIdx = data.activeGroupMemberships[self.UID]
	if oldZoneIdx then
		if groupActiveMembers[self.UID] then
			groupActiveMembers[self.UID][trackable] = nil
		end

		local cbs = groupExitedCallbacks[self.UID]
		if cbs then
			local z = zoneIndexToZoneObj[oldZoneIdx]
			local cd = trackableCustomData[trackable] and trackableCustomData[trackable][self.UID]
			for _, fn in cbs do
				task.spawn(fn, trackable, z, cd)
			end
		end
	end

	data.activeGroupMemberships[self.UID] = nil
	data.memberOfGroups[self.UID] = nil

	if trackableCustomData[trackable] then
		trackableCustomData[trackable][self.UID] = nil
		if next(trackableCustomData[trackable]) == nil then
			trackableCustomData[trackable] = nil
		end
	end

	if next(data.memberOfGroups) == nil then
		trackables[trackable] = nil
	end
end

function Group:setPriority(p: number)
	groupPriorityMap[self.UID] = p
	isDirty = true
end

function Group:isItemInside(trackable: Trackable): boolean
	local data = trackables[trackable]
	if not data then
		return false
	end
	return data.activeGroupMemberships[self.UID] ~= nil
end

function Group:isItemTracked(trackable: Trackable): boolean
	local data = trackables[trackable]
	if not data then
		return false
	end
	return data.memberOfGroups[self.UID] == true
end

function Group:getTrackedItems(): { Trackable }
	local results = {}
	for t, data in pairs(trackables) do
		if data.memberOfGroups[self.UID] then
			table.insert(results, t)
		end
	end
	return results
end

function Group:getItemsInside(): { Trackable }
	local members = groupActiveMembers[self.UID]
	if not members then
		return {}
	end

	local results = {}
	for t, _ in pairs(members) do
		table.insert(results, t)
	end
	return results
end

function Group:getZones(): { Zone }
	local results = {}
	for zoneIdx, watchingList in pairs(zoneWatchingGroups) do
		if table.find(watchingList, self.UID) then
			local zone = zoneIndexToZoneObj[zoneIdx]
			if zone then
				table.insert(results, zone)
			end
		end
	end
	return results
end

function Group:isPointInside(position: Vector3): boolean
	if not rootNode then
		return false
	end
	local isInside = false

	SpatialIndex.QueryPoint(rootNode, position, function(zoneId)
		if isInside then
			return
		end
		local groups = zoneWatchingGroups[zoneId]
		if groups and table.find(groups, self.UID) then
			if Geometry.IsPointInShape(position, objects[zoneId]) then
				isInside = true
			end
		end
	end)
	return isInside
end

function Group:onEntered(callback)
	table.insert(groupEnteredCallbacks[self.UID], callback)
	return function()
		local i = table.find(groupEnteredCallbacks[self.UID], callback)
		if i then
			table.remove(groupEnteredCallbacks[self.UID], i)
		end
	end
end

function Group:onExited(callback)
	table.insert(groupExitedCallbacks[self.UID], callback)
	return function()
		local i = table.find(groupExitedCallbacks[self.UID], callback)
		if i then
			table.remove(groupExitedCallbacks[self.UID], i)
		end
	end
end

function Group:destroy()
	local uid = self.UID

	for _, watchingList in pairs(zoneWatchingGroups) do
		local idx = table.find(watchingList, uid)
		while idx do
			table.remove(watchingList, idx)
			idx = table.find(watchingList, uid)
		end
	end

	for t, data in pairs(trackables) do
		if data.memberOfGroups[uid] then
			self:untrackItem(t)
		end
	end

	groupPriorityMap[uid] = nil
	groupEnteredCallbacks[uid] = nil
	groupExitedCallbacks[uid] = nil
	groupActiveMembers[uid] = nil
	groupUIDToGroupObj[uid] = nil

	isDirty = true
end

local function fireCallback(callbacks, trackable, zone, customData)
	if not callbacks then
		return
	end
	for _, cb in callbacks do
		task.spawn(cb, trackable, zone, customData)
	end
end

local candidatePriority = table.create(16)
local candidateIndex = table.create(16)
local candidateList = table.create(16)

RunService.Heartbeat:Connect(function()
	if pendingRebuild then
		debug.profilebegin("QuickBounds_Build")
		rootNode = SpatialIndex.Build(objects)
		pendingRebuild = false
		debug.profileend()
		isDirty = true
	end

	if not rootNode then
		return
	end

	debug.profilebegin("QuickBounds_Step")
	local start = os.clock()
	local processed = 0
	local forceRefresh = isDirty
	isDirty = false

	for trackable, data in trackables do
		local pos
		local strategy = data.strategy
		if strategy == STRATEGY.POS then
			pos = (trackable :: any).Position
		elseif strategy == STRATEGY.WORLD then
			pos = (trackable :: any).WorldPosition
		elseif strategy == STRATEGY.PRIM then
			pos = (trackable :: any).PrimaryPart.Position
		elseif strategy == STRATEGY.CFRAME then
			pos = (trackable :: any).CFrame.Position
		else
			pos = (trackable :: any):GetPivot().Position
		end

		if not forceRefresh and not data.isDirty and data.lastPosition == pos then
			continue
		end

		data.lastPosition = pos
		data.isDirty = false

		table.clear(candidatePriority)
		table.clear(candidateIndex)
		table.clear(candidateList)
		local cCount = 0
		local lowestWin = math.huge

		SpatialIndex.QueryPoint(rootNode, pos, function(zoneId)
			local groups = zoneWatchingGroups[zoneId]
			if not groups then
				return
			end

			if not Geometry.IsPointInShape(pos, objects[zoneId]) then
				return
			end

			for _, gUID in groups do
				if data.memberOfGroups[gUID] then
					local pri = groupPriorityMap[gUID] or 1e6
					local existPri = candidatePriority[gUID]

					if not existPri or pri < existPri then
						if not existPri then
							cCount += 1
							candidateList[cCount] = gUID
						end
						candidateIndex[gUID] = zoneId
						candidatePriority[gUID] = pri
						if pri < lowestWin then
							lowestWin = pri
						end
					end
				end
			end
		end)

		local current = data.activeGroupMemberships

		-- Check exits
		for gUID, oldZoneIdx in current do
			local newPri = candidatePriority[gUID]
			if not newPri or newPri > lowestWin then
				current[gUID] = nil

				if groupActiveMembers[gUID] then
					groupActiveMembers[gUID][trackable] = nil
				end

				local zone = zoneIndexToZoneObj[oldZoneIdx]
				local cd = trackableCustomData[trackable] and trackableCustomData[trackable][gUID]
				fireCallback(groupExitedCallbacks[gUID], trackable, zone, cd)
			end
		end

		-- Check entries
		for i = 1, cCount do
			local gUID = candidateList[i]
			local pri = candidatePriority[gUID]

			if pri <= lowestWin then
				if not current[gUID] then
					local newZoneIdx = candidateIndex[gUID]
					current[gUID] = newZoneIdx

					groupActiveMembers[gUID][trackable] = true

					local zone = zoneIndexToZoneObj[newZoneIdx]
					local cd = trackableCustomData[trackable] and trackableCustomData[trackable][gUID]
					fireCallback(groupEnteredCallbacks[gUID], trackable, zone, cd)
				end
			end
		end

		processed += 1
		if processed % 32 == 0 and (os.clock() - start) > frameBudget then
			break
		end
	end
	debug.profileend()
end)

return {
	-- Constructors
	newZone = newZone,
	newZoneFromPart = newZoneFromPart,

	newGroup = function(p: number?)
		local g = (setmetatable({ UID = nextGroupId }, Group) :: any) :: Group
		groupPriorityMap[g.UID] = p or 1e6
		groupEnteredCallbacks[g.UID] = {}
		groupExitedCallbacks[g.UID] = {}
		groupActiveMembers[g.UID] = setmetatable({}, { __mode = "k" }) :: any
		groupUIDToGroupObj[g.UID] = g
		nextGroupId += 1
		return g
	end,

	-- Queries
	isItemTracked = function(trackable: Trackable): boolean
		return trackables[trackable] ~= nil
	end,

	getGroupsForItem = function(trackable: Trackable): { Group }
		local data = trackables[trackable]
		if not data then
			return {}
		end
		local results = {}
		for gUID, _ in pairs(data.memberOfGroups) do
			local g = groupUIDToGroupObj[gUID]
			if g then
				table.insert(results, g)
			end
		end
		return results
	end,

	getGroupsAtItem = function(trackable: Trackable): { Group }
		local data = trackables[trackable]
		if not data then
			return {}
		end
		local results = {}
		for gUID, _ in pairs(data.activeGroupMemberships) do
			local g = groupUIDToGroupObj[gUID]
			if g then
				table.insert(results, g)
			end
		end
		return results
	end,

	getGroupsAtPoint = function(position: Vector3): { Group }
		local results = {}
		local foundUIDs = {}
		if rootNode then
			SpatialIndex.QueryPoint(rootNode, position, function(zoneId)
				if Geometry.IsPointInShape(position, objects[zoneId]) then
					local groups = zoneWatchingGroups[zoneId]
					if groups then
						for _, uid in groups do
							if not foundUIDs[uid] then
								foundUIDs[uid] = true
								local g = groupUIDToGroupObj[uid]
								if g then
									table.insert(results, g)
								end
							end
						end
					end
				end
			end)
		end
		return results
	end,

	-- Config
	setFrameBudget = function(n)
		frameBudget = n
	end,
}
