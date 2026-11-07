local M = {}
local api = vim.api

M.ns = api.nvim_create_namespace("inlinediff")
M.cursor_ns = api.nvim_create_namespace("inlinediff_cursor")
M.enabled = false
M.last_diff_output = nil
M.last_diff_buf = nil

M.default_config = {
	debounce_time = 200,
	enabled = false,
	show_staged = false,
	cursor_highlight = true,
	colors = {},
	ignored_buftype = { "terminal", "nofile" },
	ignored_filetype = { "TelescopePrompt", "NvimTree", "dap-repl", "neo-tree" },
}
M.config = vim.deepcopy(M.default_config)

-- Extmark priorities
local PRIORITY_CONTEXT = 100
local PRIORITY_CHANGE = 120
local PRIORITY_STAGED_CONTEXT = 10
local PRIORITY_STAGED_CHANGE = 30
local MIN_PADDING_LENGTH = 40
local MAX_PADDING_LENGTH = 300

local DIFF_PREFIX = { UNCHANGED = " ", DELETED = "-", ADDED = "+" }

local NORMAL_PALETTE = {
	add_ctx = "InlineDiffAddContext",
	add_chg = "InlineDiffAddChange",
	del_ctx = "InlineDiffDeleteContext",
	del_chg = "InlineDiffDeleteChange",
	ctx_priority = PRIORITY_CONTEXT,
	chg_priority = PRIORITY_CHANGE,
}
local STAGED_PALETTE = {
	add_ctx = "InlineDiffStagedAddContext",
	add_chg = "InlineDiffStagedAddChange",
	del_ctx = "InlineDiffStagedDeleteContext",
	del_chg = "InlineDiffStagedDeleteChange",
	ctx_priority = PRIORITY_STAGED_CONTEXT,
	chg_priority = PRIORITY_STAGED_CHANGE,
}

-- Every base highlight group has a cursor-variant: "<group>Cursor".
local function cursor_hl(hl)
	return hl and (hl .. "Cursor")
end

-- Tracks the virt_lines extmark we temporarily re-tinted for the cursor.
local cursor_virt_state = {}

local function theme_color(group, field)
	-- link=false resolves colorscheme links (e.g. Added = { link = "String" }).
	local color = api.nvim_get_hl(0, { name = group, link = false })[field]
	return color and string.format("#%06x", color)
end

-- Mix `fg` over `bg`; alpha 0 returns bg, alpha 1 returns fg.
local function blend(fg, bg, alpha)
	local function channel(hex, i)
		return tonumber(hex:sub(i, i + 1), 16)
	end
	local r = math.floor(alpha * channel(fg, 2) + (1 - alpha) * channel(bg, 2) + 0.5)
	local g = math.floor(alpha * channel(fg, 4) + (1 - alpha) * channel(bg, 4) + 0.5)
	local b = math.floor(alpha * channel(fg, 6) + (1 - alpha) * channel(bg, 6) + 0.5)
	return string.format("#%02x%02x%02x", r, g, b)
end

local function theme_colors()
	local bg = theme_color("Normal", "bg") or (vim.o.background == "light" and "#ffffff" or "#000000")
	local add = theme_color("Added", "fg") or "#4ade80"
	local del = theme_color("Removed", "fg") or "#f87171"
	local info = theme_color("DiagnosticInfo", "fg") or "#60a5fa"
	local warn = theme_color("DiagnosticWarn", "fg") or "#facc15"

	return {
		InlineDiffAddContext = blend(add, bg, 0.18),
		InlineDiffAddChange = blend(add, bg, 0.30),
		InlineDiffDeleteContext = blend(del, bg, 0.18),
		InlineDiffDeleteChange = blend(del, bg, 0.30),
		InlineDiffStagedAddContext = blend(info, bg, 0.14),
		InlineDiffStagedAddChange = blend(info, bg, 0.26),
		InlineDiffStagedDeleteContext = blend(warn, bg, 0.14),
		InlineDiffStagedDeleteChange = blend(warn, bg, 0.26),

		-- Cursor-variant colors: one step above the base tint, kept dark enough to read text.
		InlineDiffAddContextCursor = blend(add, bg, 0.28),
		InlineDiffAddChangeCursor = blend(add, bg, 0.42),
		InlineDiffDeleteContextCursor = blend(del, bg, 0.28),
		InlineDiffDeleteChangeCursor = blend(del, bg, 0.42),
		InlineDiffStagedAddContextCursor = blend(info, bg, 0.22),
		InlineDiffStagedAddChangeCursor = blend(info, bg, 0.36),
		InlineDiffStagedDeleteContextCursor = blend(warn, bg, 0.22),
		InlineDiffStagedDeleteChangeCursor = blend(warn, bg, 0.36),
	}
end

local function setup_highlights()
	local c = vim.tbl_extend("force", theme_colors(), M.config.colors or {})
	for name, color in pairs(c) do
		api.nvim_set_hl(0, name, { bg = color, default = false })
	end
end

local function update_cursor_highlight()
	-- 1) Restore any virt_lines we re-tinted previously (may be a different buffer).
	if cursor_virt_state.bufnr and cursor_virt_state.id then
		local b = cursor_virt_state.bufnr
		if api.nvim_buf_is_valid(b) then
			pcall(api.nvim_buf_set_extmark, b, M.ns, cursor_virt_state.row, 0, {
				id = cursor_virt_state.id,
				virt_lines = cursor_virt_state.original,
				virt_lines_above = true,
			})
		end
		cursor_virt_state = {}
	end

	local bufnr = api.nvim_get_current_buf()
	if not api.nvim_buf_is_valid(bufnr) then
		return
	end

	-- 2) Drop any previous overlay.
	api.nvim_buf_clear_namespace(bufnr, M.cursor_ns, 0, -1)

	if not M.enabled or not M.config.cursor_highlight then
		return
	end

	local row = api.nvim_win_get_cursor(0)[1] - 1
	local marks = api.nvim_buf_get_extmarks(bufnr, M.ns, { row, 0 }, { row + 1, 0 }, { details = true })

	for _, mark in ipairs(marks) do
		-- nvim_buf_get_extmarks returns { id, row, col, details }, not a { row, col } pos.
		local id, mark_row, mark_col, details = mark[1], mark[2], mark[3], mark[4]
		if mark_row == row then
			if details.virt_lines then
				-- Re-tint deleted lines that sit above this row.
				local new_virts, changed = {}, false
				for i, chunks in ipairs(details.virt_lines) do
					local new_chunks = {}
					for j, chunk in ipairs(chunks) do
						local text, chl = chunk[1], chunk[2]
						local mapped = cursor_hl(chl)
						if mapped then
							changed = true
						end
						new_chunks[j] = { text, mapped or chl }
					end
					new_virts[i] = new_chunks
				end
				if changed then
					cursor_virt_state = {
						bufnr = bufnr,
						row = mark_row,
						id = id,
						original = details.virt_lines,
					}
					api.nvim_buf_set_extmark(bufnr, M.ns, mark_row, 0, {
						id = id,
						virt_lines = new_virts,
						virt_lines_above = true,
					})
				end
			else
				local hl = details.hl_group
				local mapped = cursor_hl(hl)
				if mapped then
					if details.end_row and details.end_row > mark_row then
						-- Whole-line background (add_ctx / del_ctx)
						api.nvim_buf_set_extmark(bufnr, M.cursor_ns, row, 0, {
							end_line = details.end_row,
							hl_group = mapped,
							hl_eol = true,
							priority = (details.priority or 100) + 5,
						})
					elseif details.end_col then
						-- Character-range (add_chg / del_chg)
						api.nvim_buf_set_extmark(bufnr, M.cursor_ns, row, mark_col, {
							end_col = details.end_col,
							hl_group = mapped,
							priority = (details.priority or 120) + 5,
						})
					end
				end
			end
		end
	end
end

local function build_char_array(s)
	local chars = {}
	local n = vim.str_utfindex(s, "utf-8") or 0
	for i = 0, n - 1 do
		table.insert(chars, vim.fn.strcharpart(s, i, 1))
	end
	return chars
end

local function byte_map_for(s)
	local map = {}
	local n = vim.str_utfindex(s, "utf-8") or 0
	for i = 0, n - 1 do
		local start = vim.str_byteindex(s, "utf-8", i, false)
		local finish = vim.str_byteindex(s, "utf-8", i + 1, false)
		table.insert(map, { byte = start, char_len = finish - start })
	end
	return map
end

local function is_ignored(value, list)
	for _, v in ipairs(list or {}) do
		if value == v then
			return true
		end
	end
	return false
end

local function is_buffer_valid(bufnr)
	if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
		return false
	end

	local ok, buftype = pcall(api.nvim_buf_get_option, bufnr, "buftype")
	if ok and buftype ~= "" and is_ignored(buftype, M.config.ignored_buftype) then
		return false
	end

	local ok2, ft = pcall(api.nvim_buf_get_option, bufnr, "filetype")
	if ok2 and ft ~= "" and is_ignored(ft, M.config.ignored_filetype) then
		return false
	end

	local ok3, listed = pcall(api.nvim_buf_get_option, bufnr, "buflisted")
	if not ok3 or not listed then
		return false
	end

	if api.nvim_buf_get_name(bufnr) == "" then
		local ok4, mod = pcall(api.nvim_buf_get_option, bufnr, "modifiable")
		return ok4 and mod
	end

	return true
end

local function compute_unified_diff(old_content, new_content)
	local diff_out = vim.diff(old_content, new_content, {
		algorithm = "minimal",
		result_type = "unified",
		ctxlen = 3,
		interhunkctxlen = 4,
	})

	return (diff_out and diff_out ~= "") and diff_out or nil
end

-- Tracks .git/index mtime so staging outside the buffer (git add, gitsigns, ...)
-- triggers a refresh on the next cursor move/focus.
local index_path, index_mtime = nil, nil

local function read_index_mtime()
	if not index_path then
		return nil
	end
	local stat = vim.loop.fs_stat(index_path)
	return stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or 0
end

local function git_index_changed()
	if not index_path then
		return false
	end
	local mtime = read_index_mtime()
	if mtime ~= index_mtime then
		index_mtime = mtime
		return true
	end
	return false
end

local function run_git_diff(bufnr, cb)
	local path = api.nvim_buf_get_name(bufnr)
	if path == "" then
		return
	end

	local fullpath = vim.fn.fnamemodify(path, ":p")
	local buf_content = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n"

	vim.system(
		{ "git", "rev-parse", "--show-toplevel", "--absolute-git-dir" },
		{ cwd = vim.fn.fnamemodify(fullpath, ":h"), text = true },
		function(root_obj)
			if not root_obj or root_obj.code ~= 0 then
				index_path, index_mtime = nil, nil
				return cb({ unstaged = compute_unified_diff("", buf_content), buffer_content = buf_content })
			end

			local rev = vim.split(root_obj.stdout, "\n", { trimempty = true })
			local repo_root, git_dir = rev[1], rev[2]
			index_path, index_mtime = git_dir and (git_dir .. "/index") or nil, nil
			index_mtime = read_index_mtime()
			local real_fullpath = vim.loop.fs_realpath(fullpath) or fullpath
			local real_repo_root = vim.loop.fs_realpath(repo_root) or repo_root

			local relpath = real_fullpath:sub(1, #real_repo_root) == real_repo_root
					and real_fullpath:sub(#real_repo_root + 1):gsub("^/", "")
				or vim.fn.fnamemodify(fullpath, ":t")

			vim.system({ "git", "show", ":./" .. (relpath or "") }, { cwd = repo_root, text = true }, function(obj)
				local index_content = (obj and obj.code == 0 and obj.stdout) or ""
				local result = {
					unstaged = compute_unified_diff(index_content, buf_content),
					index_content = index_content,
					buffer_content = buf_content,
				}

				if not M.config.show_staged then
					return cb(result)
				end

				vim.system(
					{ "git", "show", "HEAD:./" .. (relpath or "") },
					{ cwd = repo_root, text = true },
					function(head_obj)
						local head_content = (head_obj and head_obj.code == 0 and head_obj.stdout) or ""
						result.staged = compute_unified_diff(head_content, index_content)
						cb(result)
					end
				)
			end)
		end
	)
end

local function split_lines(content)
	if content == "" then
		return {}
	end
	local lines = vim.split(content, "\n", { plain = true })
	if content:sub(-1) == "\n" then
		table.remove(lines)
	end
	return lines
end

local function build_index_map(index_lines, buffer_lines)
	local map, anchor = {}, {}
	local diffs = vim.diff(table.concat(index_lines, "\n"), table.concat(buffer_lines, "\n"), {
		algorithm = "minimal",
		result_type = "indices",
		ctxlen = 0,
		interhunkctxlen = 0,
	}) or {}

	local i, j = 1, 1
	for _, d in ipairs(diffs) do
		local a_start, a_count, b_start, b_count = d[1], d[2], d[3], d[4]

		local before = a_count == 0 and a_start or (a_start - 1)
		while i <= before do
			map[i] = j
			i, j = i + 1, j + 1
		end

		if a_count == 0 then
			i, j = a_start + 1, b_start + b_count
		else
			local paired = math.min(a_count, b_count)
			for k = 0, paired - 1 do
				map[a_start + k] = b_start + k
			end
			local del_anchor = b_count == 0 and (b_start + 1) or (b_start + b_count)
			for k = paired, a_count - 1 do
				anchor[a_start + k] = del_anchor
			end
			i, j = a_start + a_count, del_anchor
		end
	end

	while i <= #index_lines do
		map[i] = j
		i, j = i + 1, j + 1
	end

	return map, anchor
end

local function index_to_buffer(map, anchor, i, index_count, buffer_count)
	if i < 1 then
		return 1
	end
	if i > index_count then
		return buffer_count + 1
	end
	return map[i] or anchor[i] or (buffer_count + 1)
end

local function parse_hunks(output)
	local hunks = {}
	local lines = vim.split(output, "\n", { trimempty = true })
	local i = 1

	while i <= #lines do
		local line = lines[i]
		if line:match("^@@") then
			local ns = line:match("@@ .* %+(%d+),?%d* @@")
			if ns then
				local hunk = { new_start = tonumber(ns), lines = {} }
				i = i + 1
				while i <= #lines do
					local l = lines[i]
					if l:match("^diff") or l:match("^index") or l:match("^@@") then
						i = i - 1
						break
					end
					local prefix = l:sub(1, 1)
					if prefix == " " or prefix == "+" or prefix == "-" then
						table.insert(hunk.lines, l)
					end
					i = i + 1
				end
				table.insert(hunks, hunk)
			else
				i = i + 1
			end
		else
			i = i + 1
		end
	end
	return hunks
end

local function compute_char_diff(old_chars, new_chars)
	if #old_chars == 0 or #new_chars == 0 then
		return nil
	end
	return vim.diff(table.concat(old_chars, "\n"), table.concat(new_chars, "\n"), {
		algorithm = "minimal",
		result_type = "indices",
		ctxlen = 0,
		interhunkctxlen = 4,
		indent_heuristic = false,
		linematch = 0,
	})
end

local function build_change_mask(diffs, idx)
	local mask, count = {}, 0
	for _, d in ipairs(diffs) do
		for k = 0, d[idx + 1] - 1 do
			mask[d[idx] + k] = true
			count = count + 1
		end
	end
	return mask, count
end

local function build_highlight_chunks(chars, mask, ctx_hl, chg_hl)
	local chunks, cur_hl, cur_txt = {}, nil, {}
	for k, char in ipairs(chars) do
		local hl = mask[k] and chg_hl or ctx_hl
		if hl ~= cur_hl then
			if #cur_txt > 0 then
				table.insert(chunks, { table.concat(cur_txt), cur_hl })
			end
			cur_txt, cur_hl = { char }, hl
		else
			table.insert(cur_txt, char)
		end
	end
	if #cur_txt > 0 then
		table.insert(chunks, { table.concat(cur_txt), cur_hl })
	end
	return chunks
end

local function apply_char_highlights(bufnr, virts_old, old_lines, new_lines, rows, new_texts, pal)
	for i = 1, math.min(#old_lines, #new_lines) do
		local s_old, s_new = old_lines[i], new_texts[i] or new_lines[i]
		local c_old, c_new = build_char_array(s_old), build_char_array(s_new)
		local diffs = compute_char_diff(c_old, c_new)

		if diffs then
			local old_mask, chgd_old = build_change_mask(diffs, 1)
			if chgd_old < #c_old then
				virts_old[i] = build_highlight_chunks(c_old, old_mask, pal.del_ctx, pal.del_chg)
			end

			local new_mask, chgd_new = build_change_mask(diffs, 3)
			local row = rows[i]
			if row and chgd_new < #c_new then
				local map = byte_map_for(s_new)
				for k = 1, #c_new do
					if new_mask[k] then
						local info = map[k]
						api.nvim_buf_set_extmark(bufnr, M.ns, row, info.byte, {
							end_col = info.byte + info.char_len,
							hl_group = pal.add_chg,
							priority = pal.chg_priority,
						})
					end
				end
			end
		end
	end
end

local function get_padding_text()
	local win_width = vim.api.nvim_win_get_width(0)
	local padding_length = math.min(math.max(win_width, MIN_PADDING_LENGTH), MAX_PADDING_LENGTH)
	return string.rep(" ", padding_length)
end

local function flush_diff_group(bufnr, idx, old, new, padding, pal)
	if #old == 0 and #new == 0 then
		return idx
	end

	local virts = {}
	for i, line in ipairs(old) do
		virts[i] = { { line, pal.del_ctx } }
	end

	for j = 0, #new - 1 do
		api.nvim_buf_set_extmark(bufnr, M.ns, idx + j, 0, {
			end_line = idx + j + 1,
			hl_group = pal.add_ctx,
			hl_eol = true,
			priority = pal.ctx_priority,
		})
	end

	local buf_lines = #new > 0 and api.nvim_buf_get_lines(bufnr, idx, idx + #new, false) or {}
	local rows, new_texts = {}, {}
	for i = 1, #new do
		rows[i] = idx + i - 1
		new_texts[i] = buf_lines[i] or new[i]
	end
	apply_char_highlights(bufnr, virts, old, new, rows, new_texts, pal)

	if #virts > 0 then
		local final = {}
		for _, chunks in ipairs(virts) do
			table.insert(chunks, { padding, pal.del_ctx })
			table.insert(final, chunks)
		end
		api.nvim_buf_set_extmark(bufnr, M.ns, idx, 0, {
			virt_lines = final,
			virt_lines_above = true,
		})
	end

	return idx + #new
end

local function render_hunk(bufnr, hunk, padding, pal)
	local idx, old, new = hunk.new_start - 1, {}, {}

	for _, l in ipairs(hunk.lines) do
		local prefix, content = l:sub(1, 1), l:sub(2)
		if prefix == DIFF_PREFIX.UNCHANGED then
			idx = flush_diff_group(bufnr, idx, old, new, padding, pal) + 1
			old, new = {}, {}
		elseif prefix == DIFF_PREFIX.DELETED then
			table.insert(old, content)
		elseif prefix == DIFF_PREFIX.ADDED then
			table.insert(new, content)
		end
	end
	flush_diff_group(bufnr, idx, old, new, padding, pal)
end

local function render_staged_hunk(bufnr, hunk, map, anchor, index_count, buffer_count, padding)
	local ipos, group_ipos = hunk.new_start, hunk.new_start
	local old, new = {}, {}

	local function flush()
		if #old == 0 and #new == 0 then
			return
		end

		local start_line = index_to_buffer(map, anchor, group_ipos, index_count, buffer_count)
		local virts = {}
		for i, line in ipairs(old) do
			virts[i] = { { line, STAGED_PALETTE.del_ctx } }
		end

		local rows, new_texts = {}, {}
		for k = 1, #new do
			local bl = map[group_ipos + k - 1]
			if bl then
				rows[k] = bl - 1
				new_texts[k] = api.nvim_buf_get_lines(bufnr, bl - 1, bl, false)[1] or new[k]
			else
				new_texts[k] = new[k]
			end
		end

		for k, row in pairs(rows) do
			api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
				end_line = row + 1,
				hl_group = STAGED_PALETTE.add_ctx,
				hl_eol = true,
				priority = STAGED_PALETTE.ctx_priority,
			})
		end

		apply_char_highlights(bufnr, virts, old, new, rows, new_texts, STAGED_PALETTE)

		if #virts > 0 then
			local final = {}
			for _, chunks in ipairs(virts) do
				table.insert(chunks, { padding, STAGED_PALETTE.del_ctx })
				table.insert(final, chunks)
			end
			api.nvim_buf_set_extmark(bufnr, M.ns, start_line - 1, 0, {
				virt_lines = final,
				virt_lines_above = true,
			})
		end

		old, new = {}, {}
	end

	for _, l in ipairs(hunk.lines) do
		local prefix, content = l:sub(1, 1), l:sub(2)
		if prefix == DIFF_PREFIX.UNCHANGED then
			flush()
			ipos = ipos + 1
			group_ipos = ipos
		elseif prefix == DIFF_PREFIX.DELETED then
			if #old == 0 and #new == 0 then
				group_ipos = ipos
			end
			table.insert(old, content)
		elseif prefix == DIFF_PREFIX.ADDED then
			if #old == 0 and #new == 0 then
				group_ipos = ipos
			end
			table.insert(new, content)
			ipos = ipos + 1
		end
	end
	flush()
end

M.refresh = function(bufnr)
	bufnr = bufnr or api.nvim_get_current_buf()
	if not M.enabled or not is_buffer_valid(bufnr) then
		return
	end

	run_git_diff(
		bufnr,
		vim.schedule_wrap(function(result)
			if not api.nvim_buf_is_valid(bufnr) then
				return
			end

			local key = (result.staged or "") .. "\0" .. (result.unstaged or "")
			if M.last_diff_buf == bufnr and key == M.last_diff_output then
				return
			end

			M.last_diff_output, M.last_diff_buf = key, bufnr
			api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
			-- Re-rendering drops the extmark; don't let the cursor overlay restore a stale one.
			if cursor_virt_state.bufnr == bufnr then
				cursor_virt_state = {}
			end
			local padding = get_padding_text()

			if result.staged then
				local index_lines = split_lines(result.index_content or "")
				local buffer_lines = split_lines(result.buffer_content or "")
				local map, anchor = build_index_map(index_lines, buffer_lines)
				for _, h in ipairs(parse_hunks(result.staged)) do
					render_staged_hunk(bufnr, h, map, anchor, #index_lines, #buffer_lines, padding)
				end
			end

			if result.unstaged then
				for _, h in ipairs(parse_hunks(result.unstaged)) do
					render_hunk(bufnr, h, padding, NORMAL_PALETTE)
				end
			end

			-- All base highlights are in place; now repaint the cursor overlay.
			api.nvim_buf_clear_namespace(bufnr, M.cursor_ns, 0, -1)
			update_cursor_highlight()
		end)
	)
end

local debounce_timer, augroup = nil, nil

local function clear_cache(bufnr)
	if not bufnr or M.last_diff_buf == bufnr then
		M.last_diff_buf, M.last_diff_output = nil, nil
	end
end

local function stop_timer()
	if debounce_timer then
		pcall(function()
			debounce_timer:stop()
			if not debounce_timer:is_closing() then
				debounce_timer:close()
			end
		end)
		debounce_timer = nil
	end
end

local function start_timer(ms, cb)
	stop_timer()
	if not ms or ms == 0 then
		return
	end
	debounce_timer = vim.loop.new_timer()
	debounce_timer:start(
		ms,
		0,
		vim.schedule_wrap(function()
			stop_timer()
			if cb then
				cb()
			end
		end)
	)
end

local function setup_autocmds()
	if augroup then
		api.nvim_del_augroup_by_id(augroup)
	end
	augroup = api.nvim_create_augroup("InlineDiffAuto", { clear = true })

	api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "WinEnter", "FocusGained" }, {
		group = augroup,
		callback = function()
			if not M.enabled then
				return
			end
			-- Staging happens in the index, not the buffer, so it fires no TextChanged.
			if git_index_changed() then
				M.refresh()
			end
			update_cursor_highlight()
		end,
	})

	api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
		group = augroup,
		callback = function()
			local bufnr = api.nvim_get_current_buf()
			if not is_buffer_valid(bufnr) then
				return
			end

			if not M.enabled or (M.config.debounce_time or 0) == 0 then
				M.refresh(bufnr)
			else
				start_timer(M.config.debounce_time, function()
					if M.enabled then
						M.refresh(bufnr)
					end
				end)
			end
		end,
	})

	api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
		group = augroup,
		callback = function()
			if M.enabled then
				M.refresh()
			end
		end,
	})

	api.nvim_create_autocmd({ "BufUnload", "BufDelete" }, {
		group = augroup,
		callback = function(ctx)
			local b = ctx.buf or ctx.bufnr
			clear_cache(b)
			if cursor_virt_state.bufnr == b then
				cursor_virt_state = {}
			end
		end,
	})
end

function M.toggle()
	M.enabled = not M.enabled
	clear_cache()

	if M.enabled then
		if vim.fn.hlexists("InlineDiffAddContext") == 0 then
			setup_highlights()
		end
		setup_autocmds()
		M.refresh()
	else
		if augroup then
			api.nvim_del_augroup_by_id(augroup)
			augroup = nil
		end
		stop_timer()
		cursor_virt_state = {}
		for _, b in ipairs(api.nvim_list_bufs()) do
			if api.nvim_buf_is_loaded(b) then
				pcall(api.nvim_buf_clear_namespace, b, M.ns, 0, -1)
				pcall(api.nvim_buf_clear_namespace, b, M.cursor_ns, 0, -1)
			end
		end
	end
end

function M.toggle_staged()
	M.config.show_staged = not M.config.show_staged
	clear_cache()
	M.refresh()
	print("InlineDiff: staged changes " .. (M.config.show_staged and "shown" or "hidden"))
end

M.setup = function(opts)
	M.config = vim.tbl_deep_extend("force", M.default_config, opts or {})
	setup_highlights()
	api.nvim_create_autocmd("ColorScheme", {
		group = api.nvim_create_augroup("InlineDiffColors", { clear = true }),
		callback = setup_highlights,
	})

	if M.config.enabled and not M.enabled then
		M.toggle()
	end

	if not api.nvim_get_commands({})["InlineDiff"] then
		pcall(api.nvim_create_user_command, "InlineDiff", function(cmd)
			local arg = (cmd.args or ""):match("^%s*(%S*)") or ""
			if arg == "" or arg == "toggle" then
				M.toggle()
			elseif arg == "refresh" then
				M.refresh()
			elseif arg == "staged" then
				M.toggle_staged()
			else
				print('InlineDiff: unknown arg "' .. arg .. '". Use "toggle", "refresh" or "staged"')
			end
		end, {
			nargs = "?",
			complete = function(lead)
				local res = {}
				for _, v in ipairs({ "toggle", "refresh", "staged" }) do
					if v:sub(1, #lead) == lead then
						table.insert(res, v)
					end
				end
				return res
			end,
			desc = "InlineDiff commands: toggle, refresh or staged",
		})
	end
end

return M
