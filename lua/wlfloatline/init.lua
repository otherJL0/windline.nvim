-----------------------------------------------------------------------------
-- Copyright (c) 2020-2021 windwp
-- License: MIT
-- make a floating window statusline
-----------------------------------------------------------------------------
local M = {}
local utils = require('windline.utils')
local mode = utils.mode
local Comp = require('windline.component')
local windline = require('windline')
local Animation = require('wlanimation.animation')
local cache_utils = require('windline.cache_utils')
local api = vim.api
local namespace = api.nvim_create_namespace('WindLine.floatline_status')
local floor = math.floor
local max = math.max

_G.WindLine = _G.WindLine or M
local state = WindLine.state

local default_config = {
    interval = 300,
    ui = {
        active_char = '▁',
        active_color = 'blue',
        active_hl = nil,
    },
    close_on_cmdline = false,
    skip_filetypes = {
        'fern',
        'NvimTree',
        'lir',
    },
}

local close_float_win = function()
    if
        state.floatline
        and state.floatline.winid
        and api.nvim_win_is_valid(state.floatline.winid)
    then
        api.nvim_buf_clear_namespace(state.floatline.bufnr, namespace, 1, 2)
        api.nvim_win_close(state.floatline.winid, true)
        state.floatline.winid = nil
        state.floatline.bufnr = nil
    end
end

local create_floating_win = function()
    local cur_winid = api.nvim_get_current_win()
    close_float_win()
    local status_bufnr = api.nvim_create_buf(false, true)
    local content_opts = {
        relative = 'editor',
        width = vim.o.columns,
        height = 1,
        col = 0,
        row = vim.o.lines - vim.o.cmdheight - 1,
        focusable = false,
        style = 'minimal',
    }
    local status_winid = api.nvim_open_win(status_bufnr, true, content_opts)
    api.nvim_buf_set_option(status_bufnr, 'ft', 'windline')
    api.nvim_buf_set_option(status_bufnr, 'buftype', 'nofile')
    api.nvim_win_set_option(status_winid, 'wrap', false)
    api.nvim_win_set_option(status_winid, 'number', false)
    api.nvim_win_set_option(status_winid, 'relativenumber', false)
    api.nvim_win_set_option(status_winid, 'cursorline', false)
    api.nvim_win_set_option(status_winid, 'winblend', 0)
    api.nvim_win_set_option(status_winid, 'signcolumn', 'no')
    api.nvim_win_set_option(
        status_winid,
        'winhighlight',
        'NormalNC:Normal,Search:None'
    )
    state.floatline.winid = status_winid
    state.floatline.bufnr = status_bufnr
    api.nvim_win_set_cursor(status_winid, { 1, 1 })
    api.nvim_set_current_win(cur_winid)
end

local function render_comp(comp, bufnr, winid, width, th_id)
    local hl_data = comp.hl_data or {}
    local childs = comp.text(bufnr, winid, width, true)
    if th_id ~= state.thread_id then
        -- when text running too long and another loop change thread_id
        return false
    end
    local result = {}
    if type(childs) == 'table' then
        for _, child in pairs(childs) do
            local text, hl = child[1], child[2]
            if type(text) == 'function' then
                text = child[1](bufnr, winid, width, true)
            end
            if type(hl) == 'string' then
                hl = hl_data[hl] or hl
            end
            if text and text ~= '' then
                table.insert(result, {
                    text = text:gsub('%%%%', '%%'),
                    hl = comp:make_hl(hl, hl_data.default),
                })
            end
        end
        return result
    end
    if childs and childs ~= '' then
        table.insert(result, {
            text = childs:gsub('%%%%', '%%'),
            hl = comp:make_hl(comp.hl, hl_data.default),
        })
    end

    return result
end

local function render_float_status(bufnr, winid, items)
    state.comp = {}
    state.mode = mode()
    Comp.reset()
    local total_width = vim.o.columns
    local status = ''
    local cur_position = 0
    state.text_groups = {}
    state.thread_id = state.thread_id + 1
    for _, comp in pairs(items) do
        if comp.width == nil or comp.width < total_width then
            local hl = render_comp(comp, bufnr, winid, total_width, state.thread_id)
            if hl then
                for _, item in pairs(hl) do
                    table.insert(state.text_groups, item)
                end
            end
        end
    end
    local full_status_width = 0
    -- calculate first to get statusline width
    for _, group in ipairs(state.text_groups) do
        full_status_width = full_status_width
            + vim.api.nvim_strwidth(group.text or '')
    end
    local last_group = nil
    for _, group in ipairs(state.text_groups) do
        local next_position = cur_position
        -- replace by space
        if group.text == '%=' then
            local space_width = max(total_width - full_status_width + 2, 2)
            status = status .. string.rep(' ', space_width)
            next_position = cur_position + space_width
        else
            status = status .. group.text
            next_position = cur_position + #group.text
        end

        -- convert highlight to extmark point
        if
            last_group
            and last_group.range
            and (group.hl == '' or group.hl == last_group.hl)
        then
            last_group.range = { last_group.range[1], next_position }
        elseif group.hl ~= '' then
            group.range = { cur_position, next_position }
            last_group = group
        else
            last_group = group
        end
        cur_position = next_position
    end

    state.floatline.status = status
end

M.update_status = function()
    if state.floatline.is_hide then
        return
    end
    if
        not state.floatline.bufnr or not api.nvim_win_is_valid(state.floatline.winid)
    then
        create_floating_win()
        return
    end
    if vim.api.nvim_get_mode().mode == 'no' then
        --that mode is textlock can't change buffer
        return
    end
    local bufnr = api.nvim_get_current_buf()
    local winid = api.nvim_get_current_win()
    windline.check_autocmd_component(bufnr)
    local ft = api.nvim_buf_get_option(bufnr, 'filetype')
    local check_line = windline.get_statusline_ft(ft) or {}
    if
        utils.is_in_table(state.config.skip_filetypes, ft)
        or (
            api.nvim_win_get_config(winid).relative ~= ''
            and not check_line.floatline_show_float
        )
    then
        bufnr = state.last_bufnr
        winid = state.last_winid
    end
    if not api.nvim_win_is_valid(winid) or not api.nvim_buf_is_valid(bufnr) then
        return
    end

    local line = windline.get_statusline(bufnr) or WindLine.default_line
    render_float_status(bufnr, winid, line.active)
    state.last_bufnr = bufnr
    state.last_winid = winid
    vim.api.nvim_buf_set_lines(
        state.floatline.bufnr,
        0,
        1,
        false,
        { state.floatline.status }
    )
end

M.floatline_show = function(bufnr, winid)
    if not state.floatline then
        return ''
    end
    bufnr = bufnr or api.nvim_get_current_buf()
    local cur_win = api.nvim_get_current_win()
    local line = windline.get_statusline(bufnr) or WindLine.default_line
    if line.floatline_show_both then
        return windline.show(bufnr, winid)
    end
    if vim.g.statusline_winid == cur_win then
        return windline.render_status(bufnr, winid, state.floatline.active)
    else
        return windline.render_status(bufnr, winid, state.floatline.inactive)
    end
end

M.floatline_on_win_enter = function(bufnr, winid)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    winid = winid or vim.api.nvim_get_current_win()
    if not vim.api.nvim_win_is_valid(winid) then
        return false
    end
    vim.api.nvim_win_set_option(
        winid,
        'statusline',
        string.format(
            '%%!v:lua.WindLine.floatline_show(%s,%s)',
            bufnr or vim.api.nvim_win_get_buf(winid),
            winid
        )
    )
end

local function check_tab_have_floatline_window()
    local tabnr = api.nvim_get_current_tabpage()
    local windows = vim.api.nvim_tabpage_list_wins(tabnr)
    local count = 0
    for _, winid in pairs(windows) do
        if api.nvim_win_get_config(winid).relative == '' then
            count = count + 1
        end
    end
    return count == 1
end

M.floatline_fix_command = function(cmd)
    cmd = cmd or 'quit'
    if api.nvim_win_get_config(0).relative ~= '' then
        pcall(api.nvim_command, cmd)
        return
    end
    if check_tab_have_floatline_window() and vim.fn.tabpagenr('$') > 1 then
        close_float_win()
    end
    pcall(api.nvim_command, cmd)
end

M.floatline_on_tabenter = function()
    create_floating_win()
    M.update_status()
end

local function get_layout_height(tree_layout, height)
    if tree_layout[1] == 'row' then
        --if it is row we only get the first window
        return get_layout_height(tree_layout[2][1], height)
    elseif tree_layout[1] == 'col' then
        --need to sum all window layout
        for _, value in pairs(tree_layout[2]) do
            -- +1 because the size for statusline
            height = get_layout_height(value, height + 1)
        end
        return height - 1
    elseif tree_layout[1] == 'leaf' then
        -- get window height
        if api.nvim_win_is_valid(tree_layout[2]) then
            return api.nvim_win_get_height(tree_layout[2]) + height
        end
        return height
    end
end

local function check_tree_node(node, winid)
    if node[1] == 'col' then
        -- only check last node
        return check_tree_node(node[2][#node[2]], winid)
    elseif node[1] == 'row' then
        for _, v in ipairs(node[2]) do
            if check_tree_node(v, winid) then
                return true
            end
        end
        return false
    elseif node[1] == 'leaf' then
        return node[2] == winid
    end
end

local check_is_bottom_win = function(winid)
    winid = winid or api.nvim_get_current_win()
    local layout = vim.fn.winlayout(api.nvim_get_current_tabpage())
    return check_tree_node(layout, winid)
end

M.floatline_on_resize = function(sub_height)
    if api.nvim_win_is_valid(state.floatline.winid) then
        sub_height = sub_height or 0
        local layout = vim.fn.winlayout(api.nvim_get_current_tabpage())
        local tabline = vim.o.showtabline > 0 and 1 or 0
        if vim.o.showtabline == 1 then
            tabline = #vim.api.nvim_list_tabpages() > 1 and 1 or 0
        end
        local height = get_layout_height(layout, tabline)
            or vim.o.lines - vim.o.cmdheight - 1
        api.nvim_win_set_config(state.floatline.winid, {
            relative = 'editor',
            width = vim.o.columns,
            height = 1,
            col = 0,
            row = height - sub_height,
            style = 'minimal',
        })
        api.nvim_win_set_option(state.floatline.winid, 'winblend', 0)
    else
        create_floating_win()
    end
end

M.floatline_hide = function(close)
    vim.g.statusline_winid = vim.api.nvim_get_current_win()
    vim.wo.statusline = windline.show(
        vim.api.nvim_get_current_buf(),
        vim.api.nvim_get_current_win()
    )
    if vim.o.cmdheight ~= 0 then
        vim.cmd('redrawstatus')
    end

    if close then
        vim.api.nvim_win_close(state.floatline.winid, true)
    else
        api.nvim_win_set_config(state.floatline.winid, {
            relative = 'editor',
            width = 1,
            height = 1,
            col = 0,
            row = 0,
            style = 'minimal',
        })
        api.nvim_win_set_option(state.floatline.winid, 'winblend', 100)
    end
end

M.floatline_on_cmd_leave = function()
    if state.floatline.is_hide then
        state.floatline.is_hide = false
        if vim.v.event.cmdtype:match('[%:%-]') or vim.o.cmdheight == 0 then
            M.floatline_on_win_enter()
            M.floatline_on_resize()
        end
    end
end

M.floatline_on_cmd_enter = function()
    if vim.o.cmdheight == 0 then
        state.floatline.is_hide = true
        M.floatline_on_resize(1)
        return
    end
    if vim.v.event.cmdtype:match('[%:%-]') then
        state.floatline.is_hide = true
        vim.defer_fn(function()
            if state.floatline and state.floatline.is_hide then
                M.floatline_hide(state.config.close_on_cmdline)
            end
        end, 500)
    end
end

M.setup = function(opts)
    opts = opts or {}
    opts = vim.tbl_deep_extend('force', default_config, opts)
    opts.statuslines = nil
    -- overide default WindLine event
    WindLine.floatline_disable = M.disable
    WindLine.floatline_on_resize = M.floatline_on_resize
    WindLine.floatline_show = M.floatline_show
    WindLine.floatline_on_win_enter = M.floatline_on_win_enter
    WindLine.floatline_fix_command = M.floatline_fix_command
    WindLine.floatline_on_tabenter = M.floatline_on_tabenter
    WindLine.floatline_on_cmd_enter = M.floatline_on_cmd_enter
    WindLine.floatline_on_cmd_leave = M.floatline_on_cmd_leave

    vim.cmd([[set statusline=%!v:lua.WindLine.floatline_show()]])

    state.thread_id = 0
    api.nvim_exec(
        [[augroup WindLine
            au!
            au BufWinEnter,WinEnter * lua WindLine.floatline_on_win_enter()
            au TabEnter * lua WindLine.floatline_on_tabenter()
            au CmdlineEnter * lua WindLine.floatline_on_cmd_enter()
            au CmdlineLeave * lua WindLine.floatline_on_cmd_leave()
            au VimResized * lua WindLine.floatline_on_resize()
            au VimEnter * lua WindLine.on_vimenter()
            au ColorScheme * lua WindLine.on_colorscheme()
        augroup END]],
        false
    )

    -- remove this when this issue is fixed
    -- https://github.com/neovim/neovim/issues/11440
    api.nvim_exec(
        'command! -nargs=* Wquit call v:lua.WindLine.floatline_fix_command("quit")',
        false
    )
    api.nvim_exec(
        'command! -nargs=* Wbdelete call v:lua.WindLine.floatline_fix_command("bdelete")',
        false
    )
    vim.g.wl_quit_command = 'Wquit'
    vim.g.wl_delete_command = 'Wbdelete'
    --
    -- extend windline config with floatline config
    state.config = vim.tbl_extend('force', opts, state.config)
    state.floatline = state.floatline or {}
    local floatline = windline.get_statusline_ft('floatline')
    local check_bottom = cache_utils.cache_on_buffer(
        'BufEnter,WinEnter',
        'windline_dash',
        check_is_bottom_win
    )

    local default_floatline = {
        filetypes = { 'floatline' },
        active = {
            {
                hl_colors = {
                    line = { state.config.ui.active_color, 'NormalBg' },
                },
                text = function(_, winid, width)
                    if check_bottom(winid) then
                        return { { ' ', 'Normal' } }
                    end
                    return {
                        {
                            string.rep(
                                state.config.ui.active_char,
                                floor(width - 1),
                                ''
                            ),
                            'line',
                        },
                        {
                            state.config.ui.active_char,
                            'line',
                        },
                    }
                end,
            },
        },
    }
    if floatline then
        if not floatline.active then
            floatline.active = default_floatline.active
        end
        windline.setup_hightlight()
    else
        windline.add_status(default_floatline)
    end

    state.text_groups = {}
    state.floatline.active = windline.get_statusline_ft('floatline').active
    state.floatline.inactive = windline.get_statusline_ft('floatline').inactive
        or windline.default_line.inactive

    create_floating_win()
    M.start_runner()
    if not WindLine.floatline_set_decoration then
        -- only set it one time
        vim.api.nvim_set_decoration_provider(namespace, {
            on_start = function()
                return state.floatline ~= nil
            end,
            on_win = function(_, winid)
                return state.floatline and winid == state.floatline.winid
            end,
            on_line = function(_, winid, bufnr, row)
                if row == 0 and winid == state.floatline.winid then
                    for _, group in pairs(state.text_groups) do
                        if group.range and group.hl ~= '' then
                            vim.api.nvim_buf_set_extmark(
                                bufnr,
                                namespace,
                                0,
                                group.range[1],
                                {
                                    end_line = 0,
                                    end_col = group.range[2],
                                    hl_group = group.hl,
                                    hl_mode = 'combine',
                                    ephemeral = true,
                                }
                            )
                        end
                    end
                end
            end,
        })
        WindLine.floatline_set_decoration = true
    end
end

M.start_runner = function()
    M.stop_runner()
    -- a wrapper of vim.loop
    local runner = Animation.new({
        timeout = nil,
        delay = 200,
        type = 'blank',
        interval = state.config.interval,
        tick = M.update_status,
        manage = false,
    })
    runner:run()
    state.floatline.runner = runner
end

M.stop_runner = function()
    if state.floatline and state.floatline.runner then
        state.floatline.runner:stop()
        state.floatline.runner = nil
    end
end

M.disable = function()
    M.stop_runner()
    close_float_win()
    state.floatline = nil
end

-- toggle floatline
M.toggle = function()
    if state.floatline then
        M.disable()
        windline.setup_event()
    else
        M.setup()
    end
end

return M
