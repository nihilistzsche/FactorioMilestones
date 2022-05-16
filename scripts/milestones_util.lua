local table = require("__flib__.table")

-- Each production graph bracket, from highest to lowest, with associated frame count
-- Used in find_higher_bound_production_tick()
local FLOW_PRECISION_BRACKETS = {
    {defines.flow_precision_index.one_thousand_hours,      1000*60*60*60},
    {defines.flow_precision_index.two_hundred_fifty_hours, 250*60*60*60},
    {defines.flow_precision_index.fifty_hours,             50*60*60*60},
    {defines.flow_precision_index.ten_hours,               10*60*60*60},
    {defines.flow_precision_index.one_hour,                1*60*60*60},
    {defines.flow_precision_index.ten_minutes,             10*60*60},
    {defines.flow_precision_index.one_minute,              1*60*60},
    {defines.flow_precision_index.five_seconds,            5*60},
}

local function find_possible_existing_completion_time(global_force, new_milestone)
    for _, complete_milestone in pairs(global_force.complete_milestones) do
        if complete_milestone.type == new_milestone.type and
           complete_milestone.name == new_milestone.name and
           complete_milestone.quantity == new_milestone.quantity then
            return complete_milestone.completion_tick, complete_milestone.lower_bound_tick
        end
    end
    return nil, nil
end

function merge_new_milestones(force_name, new_milestones)
    local new_complete = {}
    local new_incomplete = {}
    local global_force = global.forces[force_name]

    for _, new_milestone in pairs(new_milestones) do
        local completion_tick, lower_bound_tick = find_possible_existing_completion_time(global_force, new_milestone)
        if completion_tick == nil then
            table.insert(new_incomplete, new_milestone)
        else
            if new_milestone.next then
                local next_milestone = create_next_milestone(force_name, new_milestone)
                table.insert(new_milestones, next_milestone)
            end
            new_milestone.completion_tick = completion_tick
            new_milestone.lower_bound_tick = lower_bound_tick
            table.insert(new_complete, new_milestone)
        end
    end

    global_force.complete_milestones = table.deep_copy(new_complete)
    global_force.incomplete_milestones = table.deep_copy(new_incomplete)
end

function mark_milestone_reached(force, milestone, tick, milestone_index, lower_bound_tick) -- lower_bound_tick is optional
    milestone.completion_tick = tick
    if lower_bound_tick then milestone.lower_bound_tick = lower_bound_tick end
    local global_force = global.forces[force.name]
    table.insert(global_force.complete_milestones, milestone)
    table.remove(global_force.incomplete_milestones, milestone_index)
    sort_milestones(global_force.milestones_by_group[milestone.group])
end

function parse_next_formula(next_formula)
    if next_formula == nil or string.len(next_formula) < 2 then return nil, nil end
    local operator = string.sub(next_formula, 1, 1)
    local next_value = tonumber(string.sub(next_formula, 2))

    if next_value == nil then return nil, nil end
    if operator == '*' then operator = 'x' end

    if operator == 'x' then
        if next_value <= 1 then return nil, nil end
    elseif operator == '+' then
        if next_value <= 0 then return nil, nil end
    else
        return nil, nil
    end

    return operator, next_value
end

function create_next_milestone(force_name, milestone)
    local operator, next_value = parse_next_formula(milestone.next)
    if operator == nil then
        game.forces[force_name].print({"", {"milestones.message_invalid_next"}, milestone.next})
        return
    end

    local new_milestone = table.deep_copy(milestone)
    if operator == '+' then
        new_milestone.quantity = milestone.quantity + next_value
    elseif operator == 'x' then
        new_milestone.quantity = milestone.quantity * next_value
    end

    return new_milestone
end

function floor_to_nearest_minute(tick)
    return (tick - (tick % (60*60)))
end

function ceil_to_nearest_minute(tick)
    return (tick - (tick % (60*60))) + 60*60
end

-- Converts from "X ticks ago" to "X ticks since start of the game"
local function get_realtime_tick_bounds(lower_bound_ticks_ago, upper_bound_ticks_ago)
    return math.max(0, floor_to_nearest_minute(game.tick - lower_bound_ticks_ago)), ceil_to_nearest_minute(game.tick - upper_bound_ticks_ago)
end

local function find_production_tick_bounds(force, milestone, stats)
    local total_count = stats.get_input_count(milestone.name)
    local lower_bound_ticks_ago = game.tick
    for _, flow_precision_bracket in pairs(FLOW_PRECISION_BRACKETS) do
        local bracket, upper_bound_ticks_ago = flow_precision_bracket[1], flow_precision_bracket[2]
        log("up: " ..upper_bound_ticks_ago.. " - low: " ..lower_bound_ticks_ago)
        -- The first bracket that does NOT match the total count indicates the upper bound first production time
        -- e.g: if total_count = 4, 4 were created in the last 1000 hours, 4 were created in the last 500 hours, 3 were created in the last 250 hours
        -- then the first creation was before 250 hours ago
        if upper_bound_ticks_ago < game.tick then -- Skip brackets if the game is not long enough
            local bracket_count = stats.get_flow_count{name=milestone.name, input=true, precision_index=bracket, count=true}
            if bracket_count <= total_count - milestone.quantity then
                return get_realtime_tick_bounds(lower_bound_ticks_ago, upper_bound_ticks_ago)
            end
        end
        lower_bound_ticks_ago = upper_bound_ticks_ago
    end
    -- If we haven't found any count drop after going through all brackets
    -- then the item was produced within the last 5 seconds (improbable but could happen)
    return get_realtime_tick_bounds(lower_bound_ticks_ago, game.tick)
end


local function find_completion_tick_bounds(force, milestone, item_stats, fluid_stats, kill_stats)
    if milestone.type == "technology" then
        return 0, game.tick -- No way to know past research time
    elseif milestone.type == "item" then
        return find_production_tick_bounds(force, milestone, item_stats)
    elseif milestone.type == "fluid" then
        return find_production_tick_bounds(force, milestone, fluid_stats)
    elseif milestone.type == "kill" then
        return find_production_tick_bounds(force, milestone, kill_stats)
    end
end

function sort_milestones(milestones)
    table.sort(milestones, function(a,b)
        if a.completion_tick and not b.completion_tick then return true end -- a comes first
        if not a.completion_tick and b.completion_tick then return false end -- b comes first
        if not a.completion_tick and not b.completion_tick then return a.sort_index < b.sort_index end
        return a.completion_tick < b.completion_tick
    end)
end

function backfill_completion_times(force)
    log("Backfilling completion times for " .. force.name)
    local item_stats = force.item_production_statistics
    local fluid_stats = force.fluid_production_statistics
    local kill_stats = force.kill_count_statistics

    local item_counts = item_stats.input_counts
    local fluid_counts = fluid_stats.input_counts
    local kill_counts = kill_stats.input_counts

    local technologies = force.technologies

    local global_force = global.forces[force.name]
    local i = 1
    while i <= #global_force.incomplete_milestones do
        local milestone = global_force.incomplete_milestones[i]
        if is_milestone_reached(force, milestone, item_counts, fluid_counts, kill_counts, technologies) then
            local lower_bound, upper_bound = find_completion_tick_bounds(force, milestone, item_stats, fluid_stats, kill_stats)
            log("Tick bounds for " ..milestone.name.. " : " ..lower_bound.. " - " ..upper_bound)
            if milestone.next then
                local next_milestone = create_next_milestone(force.name, milestone)
                table.insert(global_force.incomplete_milestones, next_milestone)
            end
            mark_milestone_reached(force, milestone, upper_bound, i, lower_bound)
        else
            i = i + 1
        end
    end
    sort_milestones(global_force.complete_milestones)
    for _group_name, group_milestones in pairs(global_force.milestones_by_group) do
        sort_milestones(group_milestones)
    end
end

function is_production_milestone_reached(milestone, item_counts, fluid_counts, kill_counts)

    local type_count
    if milestone.type == "item" then
        type_count = item_counts
    elseif milestone.type == "fluid" then
        type_count = fluid_counts   
    elseif milestone.type == "kill" then
        type_count = kill_counts
    else
        error("Invalid milestone type! " .. milestone.type)
    end

    local milestone_count = type_count[milestone.name]
    if milestone_count ~= nil and milestone_count >= milestone.quantity then
        return true
    end
    return false
end

function is_tech_milestone_reached(force, milestone, technology)
    if milestone.type == "technology" and
       technology.name == milestone.name and
       -- strict > because the level we get is the current researchable level, not the researched level
       (technology.researched or technology.level > milestone.quantity) then
        return true
    end
    return false
end

function is_milestone_reached(force, milestone, item_counts, fluid_counts, kill_counts, technologies)
    if milestone.type == "technology" then
        local technology = technologies[milestone.name]
        return is_tech_milestone_reached(force, milestone, technology)
    else
        return is_production_milestone_reached(milestone, item_counts, fluid_counts, kill_counts)
    end
end
