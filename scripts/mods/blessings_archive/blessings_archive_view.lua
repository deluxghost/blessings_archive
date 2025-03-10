local mod = get_mod("blessings_archive")
local debug_mode = mod:get("debug_mode")

local Promise = require("scripts/foundation/utilities/promise")
local ItemUtils = require("scripts/utilities/items")
local MasterItems = require("scripts/backend/master_items")
local ScriptWorld = require("scripts/foundation/utilities/script_world")
local ViewElementInputLegend = require("scripts/ui/view_elements/view_element_input_legend/view_element_input_legend")
local UIWidget = require("scripts/managers/ui/ui_widget")
local UIRenderer = require("scripts/managers/ui/ui_renderer")
local UIWidgetGrid = require("scripts/ui/widget_logic/ui_widget_grid")

local definitions = mod:io_dofile("blessings_archive/scripts/mods/blessings_archive/blessings_archive_view_definitions")
local blueprints = mod:io_dofile("blessings_archive/scripts/mods/blessings_archive/blessings_archive_view_blueprints")

BlessingsArchiveView = class("BlessingsArchiveView", "BaseView")

BlessingsArchiveView.init = function(self, settings)
	self._settings = mod:io_dofile("blessings_archive/scripts/mods/blessings_archive/blessings_archive_view_settings")
    self._traits = {}
    self._trait_categories = {}
    self._blessing_widgets = {}
    self._blessing_grid = nil
    self._max_blessing_height = nil
    self._ready = false
    self._content_scenegraph_id = "canvas"
    self._grid_scenegraph_id = "grid"

    self._weapons = {}
    self._weapon_options = {}
    self._current_weapon_option_id = nil
    self._selected_weapon_category = nil
    self._weapon_dropdown = nil

    self._rarity_options = {}
    self._current_rarity_option_id = nil
    self._selected_rarity = nil
    self._rarity_dropdown = nil

    self._opened_dropdown = nil
    self._close_opened_dropdown = false

	BlessingsArchiveView.super.init(self, definitions, settings)
end

local make_weapons_options = function (weapons)
    local options = {}

    for i, category in pairs(weapons) do
        local option = {
            ignore_localization = true,
            display_name = mod:localize(category),
            id = "weapon_" .. i,
            value = category,
        }
        options[#options + 1] = option
    end

    -- Sort alphabetically.
    table.sort(options, function (a, b)
        return a.display_name < b.display_name
    end)

    -- Add default option.
    table.insert(options, 1, {display_name = "weapon_not_selected", value = nil, id = "weapon_not_selected", weapon_category = nil})

    if debug_mode then
        mod:dump_to_file(options, "weapon_options", 3)
    end

    return options
end

local make_rarity_options = function ()
    local options = {
        {id = "rarity_not_selected", display_name = "rarity_not_selected", value = nil}
    }

    for i = 1, 4 do
        options[#options + 1] = {
            id = "rarity_" .. i,
            display_name = "rarity_" .. i,
            value = i,
        }
    end

    return options
end

BlessingsArchiveView.on_enter = function(self)
	BlessingsArchiveView.super.on_enter(self)

	self:_setup_input_legend()
    self:_create_offscreen_renderer()
    self:_get_weapons()
    self._weapon_options = make_weapons_options(self._trait_categories)
    self._rarity_options = make_rarity_options()
    self:_update_traits()
    self._weapon_dropdown = self:_create_weapon_dropdown()
    self._rarity_dropdown = self:_create_rarity_dropdown()
end

BlessingsArchiveView._setup_input_legend = function(self)
	self._input_legend_element = self:_add_element(ViewElementInputLegend, "input_legend", 10)
	local legend_inputs = self._definitions.legend_inputs

	for i = 1, #legend_inputs do
		local legend_input = legend_inputs[i]
		local on_pressed_callback = legend_input.on_pressed_callback
			and callback(self, legend_input.on_pressed_callback)

		self._input_legend_element:add_entry(
			legend_input.display_name,
			legend_input.input_action,
			legend_input.visibility_function,
			on_pressed_callback,
			legend_input.alignment
		)
	end
end

BlessingsArchiveView._get_weapons = function (self)
    self._weapons = {}
    local items = Managers.backend.interfaces.master_data:items_cache():get_cached()
    -- Save raw weapons for debug purposes.
    local raw_weapons = {}

    for _, item in pairs(items) do
        local is_weapon = item.item_type == "WEAPON_RANGED" or item.item_type == "WEAPON_MELEE"
        local name = item.display_name
        local excluded = string.match(name, "npc") or string.match(name, "bot") or string.match(name, "empty") or name == ""

        if is_weapon and not excluded then
            raw_weapons[#raw_weapons + 1] = item
            local localized_name = Localize(name):match("^%s*(.-)%s*$") -- Strip possible whitespaces.

            if self._weapons[item.trait_category] ~= nil then
                local i = #self._weapons[item.trait_category] + 1
                self._weapons[item.trait_category][i] = {
                    name = name,
                    localized_name = localized_name
                }
            else
                self._weapons[item.trait_category] = {}
                self._weapons[item.trait_category][1] = {
                    name = name,
                    localized_name = localized_name
                }
            end
        end
    end

    if debug_mode then
        mod:dump_to_file(raw_weapons, "raw_weapons", 5)
        mod:dump_to_file(self._weapons, "weapons", 5)
    end

    for category, _ in pairs(self._weapons) do
        self._trait_categories[#self._trait_categories + 1] = category
    end
end

BlessingsArchiveView._update_traits = function(self)
    self._traits = {}
    -- Save raw traits for debug purposes.
    local raw_traits = {}

    local profile = Managers.player:local_player_backend_profile()
    local character_id = profile and profile.character_id

    local promises = {}

    local function process_category(traits)
        for trait_name, seen_status in pairs(traits) do
            for rank = 1, 4 do
                if seen_status[rank] == "seen" then
                    table.insert(raw_traits, #raw_traits + 1, trait)

                    local weapon = string.match(trait_name, "^content/items/traits/([%w_]+)/")
                    local fake_trait = {
                        count = 1,
                        characterId = character_id,
                        masterDataInstance = {
                            id = trait_name,
                            overrides = {
                                rarity = rank
                            }
                        },
                        trait_name = trait_name,
                        uuid = math.uuid(),
                        weapon = weapon
                    }

                    local trait = MasterItems.get_item_instance(fake_trait, fake_trait.uuid)
                    local desc = ItemUtils.trait_description(trait, trait.rarity, trait.value)
                    local name = ItemUtils.display_name(trait)

                    local fit_weapons = self._weapons[weapon] or {}

                    local trait_data = {
                        trait_id = trait.name,
                        desc = desc,
                        name = name,
                        rarity = trait.rarity,
                        weapons = fit_weapons,
                        value = trait.value,
                        weapon_restriction = weapon
                    }

                    self._traits[#self._traits + 1] = trait_data
                end
            end
        end
    end

    local function log_error(error)
        mod:warning("Error fetching traits data. Code: %s, msg: %s", error.status, error.body)
    end

    for _, category in pairs(self._trait_categories) do
        local promise = Managers.data_service.crafting:trait_sticker_book(category)
        promise:next(process_category)
        promise:catch(log_error)
        promises[#promises + 1] = promise
    end

    Promise.all(unpack(promises)):next(function ()
        if debug_mode then
            mod:dump_to_file(self._traits, "traits", 5)
            mod:dump_to_file(raw_traits, "raw_traits", 5)
        end

        self:_prepare_data()
    end):catch(function (error)
        mod:warning("Error fetching traits data")
        mod:dump_to_file(error, "error", 3)
    end)
end

BlessingsArchiveView._prepare_data = function (self)
    -- Sort traits by rarity, then name.
    table.sort(self._traits, function (a, b)
        return a.rarity < b.rarity or (a.rarity == b.rarity and a.name < b.name)
    end)

    self:_create_blessing_widgets()
    self:_create_grid()

    self._ready = true
end

BlessingsArchiveView._on_back_pressed = function(self)
	Managers.ui:close_view(self.view_name)
end

BlessingsArchiveView._destroy_renderer = function(self)
	if self._offscreen_ui_renderer then
		self._offscreen_ui_renderer = nil
	end

	local world_data = self._offscreen_world

	if world_data then
		Managers.ui:destroy_renderer(world_data.renderer_name)
		ScriptWorld.destroy_viewport(world_data.world, world_data.viewport_name)
		Managers.ui:destroy_world(world_data.world)

		world_data = nil
	end
end

BlessingsArchiveView.update = function(self, dt, t, input_service)
    if self._blessing_grid then
        self._blessing_grid:update(dt, t, input_service)
    end

    if self._weapon_dropdown then
        blueprints["dropdown"].update(self, self._weapon_dropdown, input_service, dt, t)
    end

    if self._rarity_dropdown then
        blueprints["dropdown"].update(self, self._rarity_dropdown, input_service, dt, t)
    end

    if self._opened_dropdown and self._close_opened_dropdown then
        self:_set_exclusive_focus_on_setting(nil)

        self._close_opened_dropdown = false
    end

    if self:has_widget("total_count") then
        self._widgets_by_name.total_count.content.text = mod:localize("total_count", #self._traits)
    end

    if self:has_widget("shown_count") then
        self._widgets_by_name.shown_count.content.text = mod:localize("shown_count", #self._blessing_widgets)
    end

    self:_handle_input(input_service, dt, t)

	return BlessingsArchiveView.super.update(self, dt, t, input_service)
end

BlessingsArchiveView._handle_input = function (self, input_service, dt, t)
	if self._opened_dropdown then
		local close_selected_setting = false

		if input_service:get("left_pressed") or input_service:get("confirm_pressed") or input_service:get("back") then
			close_selected_setting = true
		end

		self._close_opened_dropdown = close_selected_setting
    end
end

BlessingsArchiveView._create_blessing_widgets = function(self)
	local blueprint = blueprints.blessing
	local widgets = {}
	local definition = UIWidget.create_definition(blueprint.pass_template, self._grid_scenegraph_id, nil, blueprint.size)
    local max_height = 0

	for i = 1, #self._traits do
		local trait = self._traits[i]

        if self._selected_rarity and self._selected_rarity ~= trait.rarity then
            goto continue
        end

        if self._selected_weapon_category and self._selected_weapon_category ~= trait.weapon_restriction then
            goto continue
        end

		local widget = UIWidget.init("blessing_" .. i, definition)
		blueprint.init(self._offscreen_ui_renderer, widget, trait)

        max_height = math.max(max_height, widget.content.size[2])

		widgets[#widgets + 1] = widget

        ::continue::
	end

    if not self._max_blessing_height then
        self._max_blessing_height = max_height
    end

    for i = 1, #widgets do
        widgets[i].content.size[2] = self._max_blessing_height
    end

	self._blessing_widgets = widgets
end

BlessingsArchiveView._create_weapon_dropdown = function (self)
    local widget_options = {
        widget_type = "dropdown",
        on_activated = function (option_id, template)
            self._current_weapon_option_id = option_id

            for i = 1, #self._weapon_options do
                local option = self._weapon_options[i]

                if option.id == option_id then
                    self._selected_weapon_category = option.value
                end
            end

            self:_create_blessing_widgets()
            self:_create_grid()
        end,
        on_changed = function (value)
            self._current_weapon_option_id = value
        end,
        get_function = function (template)
            for i = 1, #self._weapon_options do
                local option = self._weapon_options[i]

                if option.id == self._current_weapon_option_id then
                    return option.id
                end
            end

            return "weapon_not_selected"
        end,
        options_function = function (...)
            return self._weapon_options
        end,
        display_name = "",
        id = "weapons_filter"
    }
    local callback_name = "cb_on_weapons_filter_pressed"
    local scenegraph_id = "weapons_filter"
    local widget_type = "dropdown"
    local widget = nil
    local template = blueprints[widget_type]
    local size = template.size
    local pass_template_function = template.pass_template_function
    local pass_template = pass_template_function and pass_template_function(widget_options) or template.pass_template
    local widget_definition = pass_template and UIWidget.create_definition(pass_template, scenegraph_id, nil, size)

    local name = "weapons_filter"
    widget = self:_create_widget(name, widget_definition)
    widget.type = widget_type
    local init = template.init

    if init then
        init(self, widget, widget_options, callback_name)
    end

    return widget
end

BlessingsArchiveView._create_rarity_dropdown = function (self)
    local widget_options = {
        widget_type = "dropdown",
        on_activated = function (option_id, template)
            self._current_rarity_option_id = option_id

            for i = 1, #self._rarity_options do
                local option = self._rarity_options[i]

                if option.id == option_id then
                    self._selected_rarity = option.value
                end
            end

            self:_create_blessing_widgets()
            self:_create_grid()
        end,
        on_changed = function (value)
            self._current_rarity_option_id = value
        end,
        validation_function = function (...)
            mod:warning("validation")
        end,
        get_function = function (template)
            for i = 1, #self._rarity_options do
                local option = self._rarity_options[i]

                if option.id == self._current_rarity_option_id then
                    return option.id
                end
            end

            return "rarity_not_selected"
        end,
        options_function = function (...)
            return self._rarity_options
        end,
        display_name = "",
        id = "rarity_filter"
    }
    local callback_name = "cb_on_rarity_filter_pressed"
    local scenegraph_id = "rarity_filter"
    local widget_type = "dropdown"
    local widget = nil
    local template = blueprints[widget_type]
    local size = template.size
    local pass_template_function = template.pass_template_function
    local pass_template = pass_template_function and pass_template_function(widget_options) or template.pass_template
    local widget_definition = pass_template and UIWidget.create_definition(pass_template, scenegraph_id, nil, size)

    local name = "rarity_filter"
    widget = self:_create_widget(name, widget_definition)
    widget.type = widget_type
    local init = template.init

    if init then
        init(self, widget, widget_options, callback_name)
    end

    return widget
end

BlessingsArchiveView.cb_on_weapons_filter_pressed = function (self, widget, entry)
	local pressed_function = entry.pressed_function

    self:_set_exclusive_focus_on_setting("weapons_filter")

	if pressed_function then
		pressed_function(self, widget, entry)
	end
end

BlessingsArchiveView.cb_on_rarity_filter_pressed = function (self, widget, entry)
	local pressed_function = entry.pressed_function

    self:_set_exclusive_focus_on_setting("rarity_filter")

	if pressed_function then
		pressed_function(self, widget, entry)
	end
end

BlessingsArchiveView._create_offscreen_renderer = function(self)
	local view_name = self.view_name
	local world_layer = 10
	local world_name = self.__class_name .. "_ui_offscreen_world"
	local world = Managers.ui:create_world(world_name, world_layer, nil, view_name)
	local viewport_name = "offscreen_viewport"
	local viewport_type = "overlay_offscreen"
	local viewport_layer = 1
	local viewport = Managers.ui:create_viewport(world, viewport_name, viewport_type, viewport_layer)
	local renderer_name = self.__class_name .. "offscreen_renderer"

	self._offscreen_ui_renderer = Managers.ui:create_renderer(renderer_name, world)
	self._offscreen_world = {
		name = world_name,
		world = world,
		viewport = viewport,
		viewport_name = viewport_name,
		renderer_name = renderer_name
	}
end


BlessingsArchiveView._create_grid = function (self)
    local grid_spacing = {20, 30}
    local direction = "down"
    local grid = UIWidgetGrid:new(
		self._blessing_widgets,
		self._blessing_widgets,
		self._ui_scenegraph,
		self._content_scenegraph_id,
		direction,
		grid_spacing,
		nil
	)

    grid:set_render_scale(self._render_scale)

    local scrollbar_widget = self._widgets_by_name["scrollbar"]
	scrollbar_widget.content.scroll_speed = 100
    grid:assign_scrollbar(scrollbar_widget, self._grid_scenegraph_id, self._content_scenegraph_id)
    grid:set_scrollbar_progress(0)

    self._blessing_grid = grid
end


BlessingsArchiveView._set_exclusive_focus_on_setting = function (self, widget_name)
    local widgets = {self._weapon_dropdown, self._rarity_dropdown}
	local selected_widget = nil

	for i = 1, #widgets do
		local widget = widgets[i]
		local selected = widget.name == widget_name
		local content = widget.content
		content.exclusive_focus = selected
		local hotspot = content.hotspot or content.button_hotspot

		if hotspot then
			hotspot.is_selected = selected

			if selected then
				selected_widget = widget
			end
		end
	end

	for i = 1, #widgets do
		local widget = widgets[i]

		if selected_widget and selected_widget ~= widget then
			if widget.content.hotspot then
				widget.content.hotspot.disabled = true
			end
		elseif widget.content.hotspot then
			widget.content.hotspot.disabled = false
		end
	end

	for i = 1, #widgets do
		local widget = widgets[i]

		if widget.content.hotspot then
			if selected_widget then
				widget.content.hotspot.disabled = widget ~= selected_widget
			else
				widget.content.hotspot.disabled = false
			end
		end
	end

	self._opened_dropdown = selected_widget
end

BlessingsArchiveView._draw_blessings = function(self, dt, input_service)
    local render_settings = self._render_settings
    local ui_renderer = self._offscreen_ui_renderer
    local ui_scenegraph = self._ui_scenegraph

    UIRenderer.begin_pass(ui_renderer, ui_scenegraph, input_service, dt, render_settings)

    for j = 1, #self._blessing_widgets do
        local widget = self._blessing_widgets[j]

		if self._blessing_grid:is_widget_visible(widget) then
			UIWidget.draw(widget, ui_renderer)
		end
    end

    UIRenderer.end_pass(ui_renderer)
end

BlessingsArchiveView.draw = function(self, dt, t, input_service, layer)
	self:_draw_elements(dt, t, self._ui_renderer, self._render_settings, input_service)

    --Draw filter dropdowns.
    UIRenderer.begin_pass(self._ui_renderer, self._ui_scenegraph, input_service, dt, self._render_settings)
    UIWidget.draw(self._weapon_dropdown, self._ui_renderer)
    UIWidget.draw(self._rarity_dropdown, self._ui_renderer)
    UIRenderer.end_pass(self._ui_renderer)

	if self._ready then
		self:_draw_blessings(dt, input_service)
	end

	BlessingsArchiveView.super.draw(self, dt, t, input_service, layer)
end


BlessingsArchiveView._draw_widgets = function(self, dt, t, input_service, ui_renderer, render_settings)
	BlessingsArchiveView.super._draw_widgets(self, dt, t, input_service, ui_renderer, render_settings)
end

BlessingsArchiveView.on_exit = function(self)
	BlessingsArchiveView.super.on_exit(self)

	self:_destroy_renderer()
end

return BlessingsArchiveView