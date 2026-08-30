--- @since 25.5.28

local selected_or_hovered = ya.sync(function()
	local tab, paths = cx.active, {}
	for _, u in pairs(tab.selected) do
		paths[#paths + 1] = tostring(u)
	end
	if #paths == 0 and tab.current.hovered then
		paths[1] = tostring(tab.current.hovered.url)
	end
	return paths
end)

local function fail(s, ...)
	ya.notify {
		title = "localsend",
		content = string.format(s, ...),
		level = "error",
		timeout = 5,
	}
end

local function script_path()
	local config = os.getenv("YAZI_CONFIG_HOME")
	if not config or config == "" then
		config = (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/yazi"
	end
	return config .. "/plugins/localsend.yazi/send.rb"
end

return {
	entry = function()
		ya.emit("escape", { visual = true })

		local urls = selected_or_hovered()
		if #urls == 0 then
			return ya.notify {
				title = "localsend",
				content = "No file selected",
				level = "warn",
				timeout = 5,
			}
		end

		local args = { script_path() }
		for _, url in ipairs(urls) do
			args[#args + 1] = url
		end

		-- Hand the terminal over so fzf and the transfer progress are visible.
		local permit = ui.hide()

		local child, err = Command("ruby")
			:arg(args)
			:stdin(Command.INHERIT)
			:stdout(Command.INHERIT)
			:stderr(Command.INHERIT)
			:spawn()

		if not child then
			permit:drop()
			return fail("Failed to spawn ruby: %s", err)
		end

		local status, wait_err = child:wait()
		permit:drop()

		if not status then
			return fail("localsend exited abnormally: %s", wait_err)
		elseif not status.success then
			fail("localsend failed with exit code %d", status.code)
		end
	end,
}
