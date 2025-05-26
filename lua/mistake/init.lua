local M = {}

M.setup = function(opts)
	local default_opts = {}

	local script_path = debug.getinfo(1).source:match("@?(.*[\\/])")
	default_opts.dict_file = script_path .. "dict.lua"

	default_opts.custom_dict_file = vim.fn.stdpath("config") .. "/mistake_custom_dict.lua"
	default_opts.replace_after_addition = true

	opts = opts or {}
	opts = vim.tbl_extend("force", default_opts, opts)

	M.opts = opts

	M.current_dict = {}

	if not vim.uv.fs_stat(opts.custom_dict_file) then
		local file = io.open(opts.custom_dict_file, "w")
		if file then
			file:write('return {\n\t["teh"] = "the",\n}\n')
			file:close()
		else
			print("Error creating file: " .. opts.custom_dict_file)
		end
	end

	vim.api.nvim_create_user_command("MistakeEdit", function()
		M.edit_entries()
	end, {})

	vim.api.nvim_create_user_command("MistakeAdd", function()
		M.add_entry()
	end, {})

	vim.api.nvim_create_user_command("MistakeAddCurrentWord", function()
		M.add_entry_under_cursor()
	end, {})

	M.load_abbreviations = function()
		M.load_chunked_entries(opts.dict_file, 100)
		M.load_chunked_entries(opts.custom_dict_file, 100)
	end

	M.load_chunked_entries = function(dict_file, entries_per_chunk)
		local dict = loadfile(dict_file)()
		local entries = {}
		for typo, correction in pairs(dict) do
			table.insert(entries, { typo, correction })
		end

		local index = 1
		local initial_delay = 50
		local last_duration = initial_delay

		local function load_next_chunk()
			local start_time = vim.uv.hrtime()
			local limit = math.min(index + entries_per_chunk - 1, #entries)
			for i = index, limit do
				local typo = entries[i][1]
				local correction = entries[i][2]
				if not M.current_dict[typo] then
					vim.cmd(string.format("iabbrev %s %s", typo, correction))
					M.current_dict[typo] = correction
				end
			end
			local end_time = vim.uv.hrtime()
			last_duration = (end_time - start_time) / 1e6

			local new_delay = math.max(math.floor(last_duration * 2), 1)

			index = limit + 1
			if index <= #entries then
				vim.defer_fn(load_next_chunk, new_delay)
			end
		end

		load_next_chunk()
	end

	M.load_abbreviations()

	vim.api.nvim_create_autocmd("BufWritePost", {
		pattern = opts.custom_dict_file,
		callback = function()
			M.reload_custom_abbreviations()
		end,
	})

	M.reload_custom_abbreviations = function()
		local old_dict = vim.deepcopy(M.current_dict)
		local new_dict = {}

		local default_dict = loadfile(M.opts.dict_file)()
		for typo, correction in pairs(default_dict) do
			new_dict[typo] = correction
		end

		local custom_dict = loadfile(M.opts.custom_dict_file)()
		for typo, correction in pairs(custom_dict) do
			new_dict[typo] = correction
		end

		local to_add, to_update, to_remove = M.diff_dictionaries(old_dict, new_dict)

		for typo, _ in pairs(to_remove) do
			vim.cmd(string.format("silent! iunabbrev %s", typo))
			M.current_dict[typo] = nil
		end

		for typo, correction in pairs(to_add) do
			vim.cmd(string.format("iabbrev %s %s", typo, correction))
			M.current_dict[typo] = correction
		end

		for typo, correction in pairs(to_update) do
			vim.cmd(string.format("silent! iunabbrev %s", typo))
			vim.cmd(string.format("iabbrev %s %s", typo, correction))
			M.current_dict[typo] = correction
		end

		print("Custom abbreviations reloaded.")
	end

	M.replace_in_buffer = function(typo, correction)
		if opts.replace_after_addition then
			local original_position = vim.api.nvim_win_get_cursor(0)

			local vim_s_command = ':substitute/\\<' .. typo .. '\\>/' .. correction .. '/gIe'
			vim.cmd(vim_s_command)

			vim.api.nvim_win_set_cursor(0, original_position)
		end
	end

	M.diff_dictionaries = function(old_dict, new_dict)
		local to_add = {}
		local to_update = {}
		local to_remove = {}

		for typo, correction in pairs(new_dict) do
			if not old_dict[typo] then
				to_add[typo] = correction
			elseif old_dict[typo] ~= correction then
				to_update[typo] = correction
			end
		end

		for typo, _ in pairs(old_dict) do
			if not new_dict[typo] then
				to_remove[typo] = true
			end
		end

		return to_add, to_update, to_remove
	end
end

local function serialize_table(tbl)
	local result = "return {\n"
	for k, v in pairs(tbl) do
		result = result .. string.format('\t[%q] = %q,\n', k, v)
	end
	result = result .. "}\n"
	return result
end

local function add_typo(typo)
	local correction_icon = " "
	local info_icon = " "

	if not typo or typo == '' then
		print(info_icon .. " Typo cannot be empty.")
		return
	end
	vim.ui.input({ prompt = correction_icon .. 'Enter the correction: ' }, function(correction)
		if not correction or correction == '' then
			print(info_icon .. " Correction cannot be empty.")
			return
		end

		local custom_dict = {}
		if vim.uv.fs_stat(M.opts.custom_dict_file) then
			custom_dict = loadfile(M.opts.custom_dict_file)()
		end

		custom_dict[typo] = correction

		local serialized = serialize_table(custom_dict)

		local file = io.open(M.opts.custom_dict_file, 'w')
		if file then
			file:write(serialized)
			file:close()
			print(" Added to custom dictionary: '" .. typo .. "' -> '" .. correction .. "'")
			M.reload_custom_abbreviations()
			M.replace_in_buffer(typo, correction)
		else
			print("Error writing to file: " .. M.opts.custom_dict_file)
		end
	end)
end

M.add_entry = function()
	local typo_icon = " "

	vim.ui.input({ prompt = typo_icon .. 'Enter the typo: ' }, add_typo)
end

M.add_entry_under_cursor = function()
	add_typo(vim.fn.expand("<cword>"))
end

M.edit_entries = function()
	local custom_dict = {}
	if vim.uv.fs_stat(M.opts.custom_dict_file) then
		custom_dict = loadfile(M.opts.custom_dict_file)()
	end

	local lines = {}
	for typo, correction in pairs(custom_dict) do
		table.insert(lines, typo .. " -> " .. correction)
	end

	local buf = vim.api.nvim_create_buf(false, false)

	vim.api.nvim_buf_set_name(buf, '[MistakeEdit]')

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	local width = math.floor(vim.o.columns * 0.4)
	local height = math.floor(vim.o.lines * 0.4)
	local col = math.floor((vim.o.columns - width) / 2)
	local row = math.floor((vim.o.lines - height) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = width,
		height = height,
		col = col,
		row = row,
		style = 'minimal',
		border = 'single',
		title = 'Custom Dictionary',
	})

	vim.api.nvim_set_option_value('filetype', 'mistakeedit', {buf=buf})
	vim.api.nvim_set_option_value('buftype', 'acwrite', {buf=buf})
	vim.api.nvim_set_option_value('bufhidden', 'wipe', {buf=buf})
	vim.api.nvim_set_option_value('modifiable', true, {buf=buf})
	vim.api.nvim_set_option_value('modified', false, {buf=buf})
	vim.api.nvim_set_option_value('swapfile', false, {buf=buf})
	vim.api.nvim_set_option_value('readonly', false, {buf=buf})

	vim.cmd([[
		syntax match MistakeSeparator /->/
		highlight link MistakeSeparator Operator
	]])

	vim.api.nvim_create_autocmd('BufWriteCmd', {
		buffer = buf,
		callback = function()
			local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			local new_dict = {}
			for i, line in ipairs(new_lines) do
				if line == '' then
					goto continue
				end
				local parts = vim.split(line, '%s*->%s*')
				if #parts ~= 2 then
					vim.api.nvim_echo({{'Error on line ' .. i .. ': Each line must contain exactly one "->" separator.\n'}}, true, {err=true})
					return
				end
				local typo = vim.trim(parts[1])
				local correction = vim.trim(parts[2])
				if typo == '' or correction == '' then
					vim.api.nvim_echo({{'Error on line ' .. i .. ': Typo and correction cannot be empty.\n'}}, true, {err=true})
					return
				end
				new_dict[typo] = correction
				::continue::
			end

			local serialized = serialize_table(new_dict)

			local file = io.open(M.opts.custom_dict_file, 'w')
			if file then
				file:write(serialized)
				file:close()
				print('Custom dictionary saved.')
				M.reload_custom_abbreviations()
				vim.api.nvim_set_option_value('modified', false, {buf=buf})
			else
				print("Error writing to file: " .. M.opts.custom_dict_file)
			end
		end,
	})

	vim.api.nvim_buf_set_keymap(buf, 'n', 'q', '<cmd>wq<CR>', { noremap = true, silent = true })
end

return M
