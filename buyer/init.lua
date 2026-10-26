local mq = require('mq')
local ImGui = require('ImGui')

-- ============================================================
-- Point Merchant Buyer (ImGui Sidecar Edition)
-- ============================================================

local MERCHANT_WINDOW = 'NewPointMerchantWnd'
local ITEM_LIST = 'NewPointMerchant_ItemList'
local NAME_LABEL = 'NewPointMerchant_NameLabel'
local CURRENCY_NAME_LABEL = 'NewPointMerchant_PointsNameLabel'
local CURRENCY_VALUE_LABEL = 'NewPointMerchant_PointsAvailableValue'
local PURCHASE_BUTTON = 'NewPointMerchant_PurchaseButton'

local VERIFY_TIMEOUT = 3000
local VENDOR_RANGE = 25.0

-- Vendor configurations containing their currencies and items of interest
local vendors = {
    Walter = {
        currency = 'Tokens of Might',
        items = {
            { name = 'Token of Legendary Might', needsInventory = false },
            { name = 'Token of Epic Might', needsInventory = false },
        }
    },
    Cloe = {
        currency = 'Tokens of Epic Might',
        items = {
            { name = 'Token of Legendary Might', needsInventory = false },
        }
    },
    Wolfie = {
        currency = 'Tokens of the Wolf',
        items = {
            { name = 'Token of Epic Might', needsInventory = false },
        }
    },
    Adrienne = {
        currency = 'Tokens of Legendary Might',
        items = {
            { name = 'Grimoire of Otherworldly Experience', needsInventory = true },
            { name = 'Grimoire of Boundless Experience', needsInventory = true },
            { name = 'Voucher for 600 Tokens of Might', needsInventory = true },
        }
    },
}

local running = true
local purchaseInProgress = false

-- Deferred purchase request structure to prevent ImGui thread yielding errors
local pendingPurchase = nil

-- State tracking for ImGui quantity inputs per item
local inputQuantities = {}
local lastActiveVendor = nil

-- ============================================================
-- Utility Functions
-- ============================================================

local function trim(value)
    if not value then return '' end
    return tostring(value):gsub('^%s+', ''):gsub('%s+$', '')
end

local function numberFromText(value)
    if not value then return 0 end
    value = tostring(value):gsub(',', ''):gsub('%s+', '')
    return tonumber(value) or 0
end

local function window()
    return mq.TLO.Window(MERCHANT_WINDOW)
end

local function windowOpen()
    local wnd = window()
    return wnd and wnd.Open()
end

local function getItemList()
    local wnd = window()
    if not wnd then return nil end
    return wnd.Child(ITEM_LIST)
end

local function getVendorName()
    local wnd = window()
    if not wnd then return nil end
    local label = wnd.Child(NAME_LABEL)
    if not label then return nil end
    return trim(label.Text())
end

local function getCurrencyName()
    local wnd = window()
    if not wnd then return nil end
    local label = wnd.Child(CURRENCY_NAME_LABEL)
    if not label then return nil end
    return trim(label.Text())
end

local function getCurrencyAmount()
    local wnd = window()
    if not wnd then return 0 end
    local label = wnd.Child(CURRENCY_VALUE_LABEL)
    if not label then return 0 end
    return numberFromText(label.Text())
end

local function getItemRow(itemName)
    local list = getItemList()
    if not list then return nil end
    local row = list.List('=' .. itemName)
    if not row then return nil end
    row = row()
    if not row or row <= 0 then return nil end
    return row
end

local function getDisplayedPrice(row)
    local list = getItemList()
    if not list then return 0 end
    local priceData = list.List(row, 2)
    if not priceData then return 0 end
    return numberFromText(priceData())
end

local function getItemCount(itemName)
    local count = mq.TLO.FindItemCount('=' .. itemName)
    if not count then return 0 end
    return tonumber(count()) or 0
end

local function getFreeInventory()
    local free = mq.TLO.Me.FreeInventory()
    if not free then return 0 end
    return tonumber(free) or 0
end

local function checkCursorAndClear()
    if mq.TLO.Cursor() then
        mq.cmd('/autoinv')
        mq.delay(100)
    end
end

local function waitFor(condition, timeout)
    local start = os.clock()
    local timeoutSeconds = timeout / 1000
    while (os.clock() - start) < timeoutSeconds do
        if condition() then return true end
        mq.delay(25)
    end
    return false
end

-- ============================================================
-- Purchase Logic
-- ============================================================

local function purchaseOne(row, itemName, price, expectedCurrency, expectedItemCount)
    local list = getItemList()
    if not list then return false end

    list.Select(row)
    mq.delay(50)

    local wnd = window()
    if not wnd then return false end

    local purchaseButton = wnd.Child(PURCHASE_BUTTON)
    if not purchaseButton or not purchaseButton.Enabled() then
        return false
    end

    mq.cmdf('/notify %s %s leftmouseup', MERCHANT_WINDOW, PURCHASE_BUTTON)

    local verified = waitFor(function()
        return getCurrencyAmount() == expectedCurrency and getItemCount(itemName) == expectedItemCount
    end, VERIFY_TIMEOUT)

    -- Fucky bag protection: check cursor immediately
    checkCursorAndClear()

    return verified
end

local function executePurchase(itemConfig, quantity)
    if purchaseInProgress then return end
    local row = getItemRow(itemConfig.name)
    if not row then
        print('\ar[Buyer]\ax Item not found in merchant list: ' .. itemConfig.name)
        return
    end

    local price = getDisplayedPrice(row)
    if price <= 0 then return end

    local currency = getCurrencyAmount()
    local maxAffordable = math.floor(currency / price)
    local maxAllowed = maxAffordable
    if itemConfig.needsInventory then
        maxAllowed = math.min(maxAllowed, getFreeInventory())
    end

    if quantity > maxAllowed then
        print(string.format('\ar[Buyer]\ax Requested %d, but max available/affordable is %d.', quantity, maxAllowed))
        return
    end

    purchaseInProgress = true
    print(string.format('\ag[Buyer]\ax Purchasing %d x %s...', quantity, itemConfig.name))

    for i = 1, quantity do
        local curCurr = getCurrencyAmount()
        local curCount = getItemCount(itemConfig.name)
        if not purchaseOne(row, itemConfig.name, price, curCurr - price, curCount + 1) then
            print('\ar[Buyer]\ax Purchase verification failed or stopped mid-batch.')
            break
        end
        mq.delay(100)
    end

    checkCursorAndClear()
    purchaseInProgress = false
    print('\ag[Buyer]\ax Batch purchase complete!')
end

-- ============================================================
-- ImGui Overlay GUI
-- ============================================================

local function drawGui()
    if not windowOpen() then return end

    local merchantWnd = window()
    if merchantWnd then
        local wx = merchantWnd.X()
        local wy = merchantWnd.Y()
        local ww = merchantWnd.Width()
        -- Snap to the right side of the merchant window
        ImGui.SetNextWindowPos(wx + ww, wy, ImGuiCond.Always)
    end

    local open, show = ImGui.Begin('Point Merchant Buyer', true, ImGuiWindowFlags.AlwaysAutoResize)
    if not open then
        running = false
        return
    end

    local vendorName = getVendorName()
    
    -- Reset input quantities whenever the vendor changes
    if vendorName ~= lastActiveVendor then
        lastActiveVendor = vendorName
        inputQuantities = {}
    end

    local vendorConfig = vendorName and vendors[vendorName] or nil

    ImGui.TextColored(0.4, 0.8, 1.0, 1.0, 'Vendor: ' .. (vendorName or 'None / Unknown'))
    
    if vendorConfig then
        local currencyName = getCurrencyName()
        local currencyAmount = getCurrencyAmount()
        ImGui.Text(string.format('Currency: %s (%d Available)', currencyName, currencyAmount))
        ImGui.Separator()

        local freeSlots = getFreeInventory()

        for idx, itemCfg in ipairs(vendorConfig.items) do
            local row = getItemRow(itemCfg.name)
            local price = row and getDisplayedPrice(row) or 0
            local maxAffordable = price > 0 and math.floor(currencyAmount / price) or 0
            local maxPurchasable = itemCfg.needsInventory and math.min(maxAffordable, freeSlots) or maxAffordable

            if not inputQuantities[itemCfg.name] then
                inputQuantities[itemCfg.name] = 1
            end

            ImGui.TextWrapped(itemCfg.name)
            ImGui.Text(string.format('  Price: %d | Max: %d', price, maxPurchasable))

            -- Input quantity
            local qty = ImGui.InputInt('##qty_' .. idx, inputQuantities[itemCfg.name])
            if qty then
                inputQuantities[itemCfg.name] = math.max(1, qty)
            end

            ImGui.SameLine()
            if ImGui.Button('Buy##btn_' .. idx) then
                -- Queue the purchase instead of running it directly inside the ImGui render thread
                pendingPurchase = { config = itemCfg, qty = inputQuantities[itemCfg.name] }
            end

            ImGui.Separator()
        end
    else
        ImGui.Text('\ayOpen a supported vendor window\nto view quick-buy options.\ax')
    end

    ImGui.End()
end

mq.imgui.init('PointMerchantBuyer', drawGui)

-- ============================================================
-- Slash Command Bind (`/eqmbuy` support)
-- ============================================================

local function commandHandler(...)
    print('\ag[Buyer]\ax Open Walter, Cloe, Wolfie, or Adrienne to use the quick buyer window.')
end

mq.bind('/eqmbuy', commandHandler)
print('[Buyer] Loaded with ImGui Sidecar. Open a supported merchant window.')

-- ============================================================
-- Main Loop (Handles background tasks and safe deferred purchases)
-- ============================================================

while running do
    if pendingPurchase and not purchaseInProgress then
        local p = pendingPurchase
        pendingPurchase = nil
        executePurchase(p.config, p.qty)
    end

    mq.delay(100)
end

mq.unbind('/eqmbuy')