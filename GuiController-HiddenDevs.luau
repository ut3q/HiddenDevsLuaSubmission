-- Discord: aquamizualt | Roblox: aquaisaquafina
--[[
	GuiController
	
	Handles the HUD, in game leaderboards, server browser (currently disabled), menu opening and closing,
	and the inventory with its various stacking modes.

	For hidden dev reviewer: this code is pretty old but is still used in my game, though it doesn't
	follow all of the conventions in my style guide on my portfolio if you decide to look at that.
]]--

--[[ Services ]]--

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

--[[ Types ]]--

-- Assuming you know but types are basically just enforcing shapes data must take,
-- I mainly use it for the intellisense aspect of it though.
type ItemData = {
	Id: string,
	Name: string,
	Count: number,
	Crafter: string?,
}
type PlayerData = {
	Level: number,
	Exp: number,
	Items: { [any]: ItemData },
}
type ServerData = {
	ServerId: string,
	Players: number,
	IsShuttingDown: boolean,
	CountryCode: string,
}
type LeaderboardEntry = {
	key: string,
	value: number,
}

--[[ Private Variables ]]--

local Data: PlayerData
local VersionNumber = 0.301
local DisplayMode = "None"
local MaxLevel = 200
local ServerCapacity = 2

-- This handles the EXP curve: totalExp(level) = (level / LevelScale) ^ LevelExponent.
-- Literally makes it so as you level up, each proceeding level takes more and more exp.
-- Also means we get a set level with a set exp amount, and can inverse to get the remaining exp.
local LevelScale = 0.075
local LevelExponent = 1.65

-- This was an older value that was used to help the abbreviation logic,
-- not used anymore but the old abbreviater that make it like 1.2k would,
-- sometimes cut off numbers prematurely under 1000, 500 was a quick fix lol.
local AbbreviateThreshold = 500

-- We declare a simple, but clean tween here and basically reuse it across most if not all ui,
-- this ofc saves memory and computation time.
local UiTweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Cubic, Enum.EasingDirection.Out)
local BlurOpenSize = 12
local UnderlayOpenTransparency = 0.6

local SelectedColor = Color3.fromRGB(5, 255, 34)
local UnselectedColor = Color3.fromRGB(231, 231, 231)

local Player = Players.LocalPlayer
local GuiBlur = Lighting.GuiBlur

local PlayerGui = Player.PlayerGui

-- We use wait for child in case things aren't there when the client script starts,
-- though this was mitigated with a custom framework, and then completely removed with declaritive ui.
local Hud = PlayerGui:WaitForChild("Hud")
local Ui = PlayerGui:WaitForChild("Ui")

local _Packages = ReplicatedStorage.Packages

local _Bars = Hud.Bars
local _Displays = Hud.Displays

local DarkUiUnderlay = Ui.DarkUiUnderlay

local ServerListGroup = Ui.ServerList
local InventoryGroup = Ui.Inventory

local ExpBar = _Bars.ExpBar
local ExpDisplay = ExpBar.Display
local ExpBarFiller = ExpBar.BarFiller

local LevelDisplay = _Displays.Level
local BuildDisplay = _Displays.Build
local VersionDisplay = _Displays.Version
local ServerUptimeDisplay = _Displays.ServerUptime

local ServerList = ServerListGroup.List
local ServerListingTemplate = ServerList.Template
local ServerListSearchBox = ServerListGroup.SearchBox

local InventoryGrid = InventoryGroup.Grid
local InventorySearchBox = InventoryGroup.SearchBox
local InventoryItemDisplayTemplate = InventoryGroup.ItemTemplate
local InventoryItemInfo = InventoryGroup.ItemInfo
local InventoryItemNameDisplay = InventoryItemInfo.ItemName
local InventoryDisplayOptions = InventoryGroup.DisplayOptions
local InventoryDisplayModeButton = InventoryGroup.DisplayMode

--[[ Tables ]]--

-- We use this to both preload image assets, as well as keep it here so we don't need to
-- access the gamespace and then search for an id/cache it, it's defined here
-- (though it was ofc moved to it's own module for better structure, this is just for the submission.)
local T_InventoryItems = {
	["Fists"] = {
		["ImageId"] = "rbxassetid://13618542955",
	},
}

local T_StackFieldByMode = {
	["Name"] = "Name",
	["Crafter"] = "Crafter",
}

-- We have each item stored in a cache so we can rerender under different modes without needing
-- to get the data again and again etc.
local T_ItemCache: { [Instance]: ItemData } = {}

-- This is simply a userid to username lookup that we cache specifically for leaderboards. 
local T_NameCache: { [number]: string } = {}

--[[ Modules ]]--

local Knit = require(_Packages.Knit)
local Gui = require(_Packages.Gui)

--[[ Private Functions ]]--

-- Strips whitespace and lowercases so "fi sts" still finds "Fists".
local function NormalizeSearch(inputString: string): string
	return string.lower((string.gsub(inputString, "%s+", "")))
end

-- Added checks to ensure a search is valid and doesn't waste our precious cpu resources.
local function ReturnValidityForSearch(normalizedQuery: string, name: string): boolean
	return normalizedQuery == "" or string.find(NormalizeSearch(name), normalizedQuery, 1, true) ~= nil
end

local function FilterSearch(inputString: string, container: Instance, exclusions: { string })
	local normalizedQuery = NormalizeSearch(inputString)
	for _, itemInstance in container:GetChildren() do
	   -- To describe IsA as something, it's checking whether something is a frame, that halfway
		-- we don't accidentally edit a grid layout, or some other thing thats not meant to be
		-- touched.
		if itemInstance:IsA("Frame") and not table.find(exclusions, itemInstance.Name) then
			itemInstance.Visible = ReturnValidityForSearch(normalizedQuery, itemInstance.Name)
		end
	end
end

-- This function is reused anywhere a search box exists
local function BindSearchBox(searchBox: TextBox, container: ScrollingFrame, exclusions: { string })
   -- The GetPropertyChanged... detects when text is changed, which of course we then
   -- filter the search results. Obviously :)
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		FilterSearch(searchBox.Text, container, exclusions)
		-- This simply scrolls back up so its not left in a blank area.
		-- Are you still reading thissssssss I know what I'm doing :(
		container.CanvasPosition = Vector2.zero
	end)
end

local function CalculateExp(levelToCalculate: number): number
	return (levelToCalculate / LevelScale) ^ LevelExponent
end

-- Remember how I mentioned we can inverse that exp math, here it is!
-- We basically take the exp for the next level, subtract that from your current exp
-- which then gives us how much you need before leveling up, simple and it works.
local function CalculateRemainingExp(levelToCalculate: number, expToCalculate: number): (number, number)
	local expForCurrentLevel = CalculateExp(levelToCalculate)
	return expToCalculate - expForCurrentLevel, CalculateExp(levelToCalculate + 1) - expForCurrentLevel
end

local function SetExpBar()
	local remainingExp, expDifference = CalculateRemainingExp(Data.Level, Data.Exp)

	-- This adjust bar functionality is just a tween that adjusts a uigradient visibility numer sequence and tweens it neatly.
	-- It's used in a lot of places which is why its in my gui module.
	Gui.AdjustBar(expDifference, remainingExp, 0.15, 0.035, ExpBarFiller, ExpDisplay, 0.035)
	LevelDisplay.Text = tostring(Data.Level)

   -- Obviously if they are max level we say their exp is "Max/Max" duh
	if Data.Level >= MaxLevel then
		ExpDisplay.Text = "Max/Max"
		return
	end

	-- We always floor values so we dont get 1829.000000000034
	remainingExp = math.floor(remainingExp)
	local remainingText = if remainingExp >= AbbreviateThreshold then Gui.AbbreviateNumber(remainingExp) else tostring(remainingExp)
	ExpDisplay.Text = remainingText .. "/" .. Gui.AbbreviateNumber(math.floor(expDifference))
end

local function GetUsername(userId: number): string?
	local cachedName = T_NameCache[userId]
	if cachedName then
		return cachedName
	end

   -- Onto pcallsss we wrap this async function because roblox's api can fail,
   -- no suprise given they have an outage every other day I stg,
   -- but basically we check if it returns what we asked it, or it fails,
   -- so instead of erroring and breaking the function, we know that it failed,
   -- and can tell the user, retry, etc, whatever fits.
	local success, username = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	if success then
		T_NameCache[userId] = username
		return username
	end
	return nil
end

local function CreateLeaderboardListing(username: string, rank: number, data: number, list: ScrollingFrame, displayType: string)
	local template = list.Template:Clone()
	-- We format time and regular numbers differently, time goes 6 months, 14 days while numbers go 1.27M simple!
	template.Data.Text = if displayType == "Time" then Gui.FormatTime(data) else Gui.AbbreviateNumber(data)
	template.Player.Text = username
	template.Rank.Text = tostring(rank)
	-- We use a set name rather than specifics for the Gui.CleanList function, which ofc cleans the list.
	-- Yes caching these or editing them would have been better, don't judge me >:(
	template.Name = "PlayerRanking"
	template.Visible = true
	-- Now to parenting, we always parent a gui item last, that way all the properties
	-- already are loaded, instead of appearing blank then being edited
	-- which is worse in practice and waste performance (in theory at least)
	template.Parent = list
end

local function UpdateLeaderboardTimers(message: string, leaderboards: { any })
	for _, leaderboard in leaderboards do
		leaderboard.Model.LeaderboardGui.Footer.RefreshTimer.Text = message
	end
end

local function LoadLeaderboardListing(leaderboardPage: { LeaderboardEntry }, leaderboardList: ScrollingFrame, displayType: string)
	local listings = {}
	for rank, playerData in ipairs(leaderboardPage) do
		local playerKey = playerData.key and Gui.ExtractNumbersFromString(playerData.key)
		local dataValue = playerData.value
		if not (playerKey and dataValue) or playerKey <= 0 or dataValue <= 0 then
			continue
		end

		local username = GetUsername(playerKey)
		if username then
			table.insert(listings, { Rank = rank, Username = username, Data = dataValue })
		end
	end

   -- Still a stupid implementation :(
	Gui.CleanList(leaderboardList, {}, {}, { "PlayerRanking" })
	for _, listing in listings do
		CreateLeaderboardListing(listing.Username, listing.Rank, listing.Data, leaderboardList, displayType)
	end
end

local function UpdateServerListing(data: ServerData)
	local nameDisplayString = data.CountryCode .. "-" .. data.ServerId
	local serverListing = ServerList:FindFirstChild(nameDisplayString)

   -- For the server selection screen, we first check if the server is shutting down, if so
   -- we destroy it, that way a player doesn't join and get pulled out or kicked lol.
	if data.IsShuttingDown then
		if serverListing then
			serverListing:Destroy()
		end
		return
	end

	if not serverListing then
		serverListing = ServerListingTemplate:Clone()
		serverListing.Name = nameDisplayString
		serverListing.ServerName.Text = nameDisplayString

      -- We match the ids to see if the server is the server you are in, then we bring that one in the top.
		if data.ServerId == game.JobId then
			serverListing.LayoutOrder = -1
			serverListing.TeleportButton.Text = "This is you!"
		else
		   -- All other servers get a join button/teleport connection, yours doesn't cause yk... you're already in your own server.
			serverListing.TeleportButton.MouseButton1Click:Connect(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, data.ServerId)
			end)
		end

      -- See its the search function again, told ya we use it in multiple areas!
		serverListing.Visible = ReturnValidityForSearch(NormalizeSearch(ServerListSearchBox.Text), nameDisplayString)
		serverListing.Parent = ServerList
	end

	serverListing.PlayerCount.Text = data.Players .. "/" .. ServerCapacity .. " Players"
end

-- This handles the blur/dim overlays that are/were in some of the ui, I thought it looked good at the time at least...
local function SetInterfaceEffects(isEnabled: boolean): Tween
	local blurTween = TweenService:Create(GuiBlur, UiTweenInfo, { Size = if isEnabled then BlurOpenSize else 0 })
	TweenService:Create(DarkUiUnderlay, UiTweenInfo, {
		BackgroundTransparency = if isEnabled then UnderlayOpenTransparency else 1,
	}):Play()
	blurTween:Play()
	return blurTween
end

local function UpdateServerUptime()
	-- We spawn a new thread here so it doesn't halt the other functions since yk, infinite loop.
	task.spawn(function()
		while true do
		   -- Simply displays uptime of the server, though the time isn't accurate it was simplified for the submission.
			ServerUptimeDisplay.Text = "Server Uptime - " .. Gui.FormatTime(workspace.DistributedGameTime)
			task.wait(1)
		end
	end)
end

local function DisplayGameBuildVersion()
	-- PlaceVersion is the published version the server is on, useful for updates/debugging.
	BuildDisplay.Text = "[Beta - " .. game.PlaceVersion .. "]"
	VersionDisplay.Text = "Server Version - " .. VersionNumber
end

local function GetStackField(displayMode: string): string?
	if displayMode == "None" then
		return nil
	end
	return T_StackFieldByMode[displayMode] or "Id"
end

-- Both Id and the mode's field need to match to load, this allows for some complex
-- sorting/order etc. I know it was overcomplicated but it did teach me a lot at the time.
local function LoadItemFromCacheBasedOffSetting(itemData: ItemData, setting: string): Instance?
	for itemDisplay, itemCache in T_ItemCache do
		if itemCache.Id == itemData.Id and itemCache[setting] == itemData[setting] then
			return itemDisplay
		end
	end
	return nil
end

local function CreateItemInstance(itemData: ItemData, itemImageId: string)
	local itemDisplay = InventoryItemDisplayTemplate:Clone()

	-- We copy the item data since the real data is inside the datamodule, which we don't want to touch directly.
	T_ItemCache[itemDisplay] = table.clone(itemData)

	itemDisplay.Name = itemData.Id
	itemDisplay.ItemCount.Text = itemData.Count .. "x"
	itemDisplay.ItemImage.Image = itemImageId
	-- Here it is again. It's 3AM and I am tired so do ignore the bad humor.
	itemDisplay.Visible = ReturnValidityForSearch(NormalizeSearch(InventorySearchBox.Text), itemData.Id)

   -- This just shows the item count when hovering over items.
	itemDisplay.MouseEnter:Connect(function()
		itemDisplay.ItemCount.Visible = true
	end)
	itemDisplay.MouseLeave:Connect(function()
		itemDisplay.ItemCount.Visible = false
	end)
	itemDisplay.ItemImage.MouseButton1Click:Connect(function()
		InventoryItemNameDisplay.Text = itemData.Name
		InventoryItemInfo.Visible = true
	end)

	itemDisplay.Parent = InventoryGrid
end

local function LoadItemInstances(itemData: ItemData)
	local inventoryItem = T_InventoryItems[itemData.Id]
	if not inventoryItem then
		return
	end

	local setting = GetStackField(DisplayMode)
	if setting then
		local itemDisplay = LoadItemFromCacheBasedOffSetting(itemData, setting)
		if itemDisplay then
			local itemCache = T_ItemCache[itemDisplay]
			itemCache.Count += itemData.Count
			itemDisplay.ItemCount.Text = itemCache.Count .. "x"
		else
			CreateItemInstance(itemData, inventoryItem.ImageId)
		end
		return
	end

   -- This is used to basically stack no items, so if you have 1000 theres 1000 frames to render.
   -- Byebye mobile players
	local singleItemData = table.clone(itemData)
	singleItemData.Count = 1
	for _ = 1, itemData.Count do
		CreateItemInstance(singleItemData, inventoryItem.ImageId)
	end
end

local function LoadItemsFromDisplaySetting(newDisplaySetting: string)
	DisplayMode = newDisplaySetting

   -- We store the cached items first since it acts as the source and the place to be cleared.
	local cachedItems = {}
	for itemDisplay, itemData in T_ItemCache do
		table.insert(cachedItems, itemData)
		itemDisplay:Destroy()
	end
	table.clear(T_ItemCache)

   -- We now rebuild the item instances through a loop based on the settings the player chose.
   -- Didn't have a yield or any limit at the time which people managed to break ofc.
	for _, itemData in cachedItems do
		LoadItemInstances(itemData)
	end
end

local function HandleExpUpdating()
	local DataService = Knit.GetService("DataService")
	local DataController = Knit.GetController("DataController")

	Data = DataController:GrabCachedData()
	SetExpBar()
   
	-- The server sends the full data table to the client,
	-- which replaces the data value, this ofc was retired due
	-- to it being a horrible implementation but it did work.
	DataService.ExpChanged:Connect(function(data: PlayerData)
		Data = data
		SetExpBar()
	end)
end

local function HandleLeaderboardUpdates()
	local LeaderboardService = Knit.GetService("LeaderboardService")

	-- We connect the functions directly so its clean and saves
	-- that lil bit of performance.
	LeaderboardService.UpdateTimer:Connect(UpdateLeaderboardTimers)
	LeaderboardService.UpdateList:Connect(LoadLeaderboardListing)
end

local function ListenForServerData()
	local GlobalService = Knit.GetService("GlobalService")
	GlobalService.SendServerData:Connect(UpdateServerListing)
end

local function HandleAllInterfaceSearchBoxes()
	BindSearchBox(ServerListSearchBox, ServerList, { "Template" })
	BindSearchBox(InventorySearchBox, InventoryGrid, {})
end

local function HandleInventory()
	local DataService = Knit.GetService("DataService")
	local previousDisplayButtonClicked = InventoryDisplayOptions.None.SettingButton
	previousDisplayButtonClicked.TextColor3 = SelectedColor

	for _, itemData in Data.Items do
		LoadItemInstances(itemData)
	end

	InventoryDisplayModeButton.MouseButton1Down:Connect(function()
		InventoryDisplayOptions.Visible = not InventoryDisplayOptions.Visible
		InventoryDisplayModeButton.Text = if InventoryDisplayOptions.Visible then "Display Mode ▲" else "Display Mode ▼"
	end)

	for _, objectInstance in InventoryDisplayOptions:GetChildren() do
		local settingButton = objectInstance:FindFirstChild("SettingButton")
		if not settingButton then
			continue
		end

		settingButton.MouseButton1Down:Connect(function()
			-- This is hear to stop all the items from being rebuilt if the settings don't change/are the same.
			if settingButton == previousDisplayButtonClicked then
				return
			end
			previousDisplayButtonClicked.TextColor3 = UnselectedColor
			settingButton.TextColor3 = SelectedColor
			previousDisplayButtonClicked = settingButton
			LoadItemsFromDisplaySetting(objectInstance.Name)
		end)
	end

	DataService.InventoryItemAdded:Connect(LoadItemInstances)
end

-- This script used the framework knit, thus requiring us to initialize it as a knit controller.
-- It allows us to use the features of knit, though I believe it's not really necessary anymore.
local GuiController = Knit.CreateController({ Name = "GuiController" })

-- Thse functions are public so other controllers can interact with the menus
-- via a centralized place, making code follow DRY principles.
function GuiController:DisableAndTweenAllGuiInterfaces()
	local closingInterfaces = {}
	for _, objectInstance in Ui:GetChildren() do
	   -- We used canvas groups here for the group transparency feature and cause I wanted to try it,
	   -- though it botched the resolution and was evnetually removed
		-- Not sure if it does it anymore but I haven't used them since at least.
		if objectInstance:IsA("CanvasGroup") and objectInstance.Visible then
			TweenService:Create(objectInstance, UiTweenInfo, { GroupTransparency = 1 }):Play()
			table.insert(closingInterfaces, objectInstance)
		end
	end

	local mainTween = SetInterfaceEffects(false)
	-- We ensure that all interfaces are closed before making the visible property false,
	-- that way it doesn't break the loop/make uis un openable/closeable.
	if #closingInterfaces > 0 then
		mainTween.Completed:Wait()
	end
	for _, guiInterface in closingInterfaces do
		guiInterface.Visible = false
	end
end

function GuiController:OpenGuiInterface(guiInterface: CanvasGroup)
	self:DisableAndTweenAllGuiInterfaces()
	guiInterface.Visible = true
	TweenService:Create(guiInterface, UiTweenInfo, { GroupTransparency = 0 }):Play()
	SetInterfaceEffects(true)
end

-- Use for setup, initiation with knit happens before other controllers can start/access the module.
-- It should be used to setup any values/make it ready for modules outside to access public functions/variables.
function GuiController:KnitInit()
	DisplayGameBuildVersion()
end

-- Runs when every service and controller has initialised, this way we can ensure
-- public functions/values etc are modifiable and don't need a wait or yield of any sort.
function GuiController:KnitStart()
	ListenForServerData()
	HandleAllInterfaceSearchBoxes()
	HandleExpUpdating()
	HandleLeaderboardUpdates()
	UpdateServerUptime()
	HandleInventory()
end

return GuiController
