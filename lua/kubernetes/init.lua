local PATH_DATA = vim.fn.stdpath("data") .. "/kubernetes.nvim/"
local PATH_DEFINITIONS = PATH_DATA .. "definitions.json"
local PATH_SCHEMA = PATH_DATA .. "schema.json"
local PATH_YAMLLS_VALIDATION_JS = vim.fn.stdpath("data") ..
	"/mason/packages/yaml-language-server/node_modules/yaml-language-server/out/server/src/languageservice/services/yamlValidation.js"
local YAMLLS_PATCH_PATTERN = "isKubernetes && err.message === this.MATCHES_MULTIPLE"
local YAMLLS_PATH_REPLACEMENT = "err.message === this.MATCHES_MULTIPLE"

--- run a job and return the lines from stdout.
--- errors if the job fails to start or the exit code is not 0.
---@param args string[]
---@return string[] stdout stdout lines
local function cmd_blocking(args)
	local stdout = {}
	local stderr = ""
	local chan = vim.fn.jobstart(args, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data, _)
			for i = 1, #data do
				stdout[#stdout + 1] = data[i]
			end
		end,
		on_stderr = function(_, data, _)
			stderr = table.concat(data, "\n")
		end,
	})
	if chan <= 0 then
		error("failed to spawn job for '" .. table.concat(args, " ") .. "'")
	end
	local exit_codes = vim.fn.jobwait({ chan })
	local exit_code = exit_codes[1]
	if exit_code ~= 0 then
		error("failed to execute '" ..
			table.concat(args, " ") .. "'. exit code: " .. tostring(exit_code) .. "\n" .. stderr)
	end
	return stdout
end

--- run a job and return the lines from stdout.
--- errors if the job fails to start or the exit code is not 0.
---@param args string[]
---@param on_success function(string[])
---@param on_error? function(number)
local function cmd_async(args, on_success, on_error)
	local stdout = {}
	local stderr = ""
	local chan = vim.fn.jobstart(args, {
		stdout_buffered = true,
		stderr_buffered = true,
		on_stdout = function(_, data, _)
			for i = 1, #data do
				stdout[#stdout + 1] = data[i]
			end
		end,
		on_stderr = function(_, data, _)
			stderr = table.concat(data, "\n")
		end,
		on_exit = function(_, exit_code, _)
			if exit_code == 0 then
				if on_success ~= nil then
					on_success(stdout)
				end
			else
				if on_error ~= nil then
					on_error(exit_code)
				else
					error("failed to execute '" ..
						table.concat(args, " ") .. "'. exit code: " .. tostring(exit_code) .. "\n" .. stderr)
				end
			end
		end
	})
	if chan <= 0 then
		error("failed to spawn job for '" .. table.concat(args, " ") .. "'")
	end
end

--- fetches the current cluster's schema using kubectl
---@param on_success function(table) definitions the definitions section of the schema
local function kubectl_fetch_definitions(on_success)
	cmd_async({ "kubectl", "get", "--raw", "/openapi/v2" }, function(output)
		local schema = vim.json.decode(table.concat(output, ""))
		if schema == nil then error("failed to decode schema from json") end
		on_success({ definitions = schema["definitions"] })
	end)
end

--- returns a list of kinds
---@return table
local function kubectl_kinds()
	return cmd_blocking({ "kubectl", "api-resources", "--no-headers" })
end

--- patches the definitions to include an enum in the `kind` it exists
---@param definitions table
local function patch_definitions_kind(definitions)
	for key, resource in pairs(definitions.definitions) do
		if resource.properties ~= nil and resource.properties.kind ~= nil then
			local kind = resource.properties.kind
			local parts = vim.split(key, ".", { plain = true })
			local name = parts[#parts]
			local insert = true
			if kind.enum ~= nil then
				for _, v in ipairs(kind.enum) do
					if v == name then
						insert = false
						break
					end
				end
			end
			if insert then
				kind.enum = kind.enum or {}
				kind.enum[#kind.enum + 1] = name
			end
		end
	end
end

local function generate_oneof_schema(definitions)
	local oneOf = {}
	for key, _ in pairs(definitions.definitions) do
		oneOf[#oneOf + 1] = {
			["$ref"] = PATH_DEFINITIONS .. "#/definitions/" .. key
		}
	end
	return { oneOf = oneOf }
end


---@param on_generate? function()
local function schema_generate(on_generate)
	kubectl_fetch_definitions(function(definitions)
		patch_definitions_kind(definitions)
		local schema = generate_oneof_schema(definitions)
		vim.fn.mkdir(PATH_DATA, "p")
		vim.fn.writefile({ vim.json.encode(schema) }, PATH_SCHEMA)
		vim.fn.writefile({ vim.json.encode(definitions) }, PATH_DEFINITIONS)
		if on_generate ~= nil then
			on_generate()
		end
	end)
end

local function yamlls_is_patched()
	local lines = vim.fn.readfile(PATH_YAMLLS_VALIDATION_JS)
	for _, line in ipairs(lines) do
		if string.match(line, YAMLLS_PATCH_PATTERN) then
			return false
		end
	end
	return true
end

local function yamlls_patch()
	local lines = vim.fn.readfile(PATH_YAMLLS_VALIDATION_JS)
	for index, line in ipairs(lines) do
		if string.match(line, YAMLLS_PATCH_PATTERN) then
			lines[index] = string.gsub(line, YAMLLS_PATCH_PATTERN, YAMLLS_PATH_REPLACEMENT)
		end
	end
	vim.fn.writefile(lines, PATH_YAMLLS_VALIDATION_JS)
end

local function yamlls_restart()
	vim.fn.execute("LspRestart yamlls")
end

local M = {}

function M.setup()
	schema_generate(function()
		if not yamlls_is_patched() then
			yamlls_patch()
			yamlls_restart()
		end
	end)
end

function M.generate_schema()
	schema_generate()
	yamlls_restart()
end

function M.yamlls_schema()
	return "file://" .. PATH_SCHEMA
end

---@return table containing all valid kube filetypes
function M.yamlls_filetypes()
	local filetypes = {}
	local kinds = kubectl_kinds()
	for _, k in ipairs(kinds) do
		-- Grab last column
		local kind = k:gsub(".* (%w+)$", "%1"):lower()
		if kind ~= "" then
			table.insert(filetypes, "*." .. kind .. ".yml")
			table.insert(filetypes, "*." .. kind .. ".yaml")
		end
	end
	return filetypes
end

function M.yamlls_patch()
	return yamlls_patch()
end

function M.yamlls_is_patched()
	return yamlls_is_patched()
end

vim.api.nvim_create_user_command("KubernetesGenerateSchema", function()
	require('kubernetes').generate_schema()
end, { desc = "Generate the schema from the current kubernetes cluster and restart yamlls" })

vim.api.nvim_create_user_command("KubernetesPatchYamlls", function()
	require('kubernetes').yamlls_patch()
end, { desc = "Patch the yamlls server" })

vim.api.nvim_create_user_command("KubernetesIsYamllsPatched", function()
	print(require('kubernetes').yamlls_is_patched())
end, { desc = "Check if the yamlls server is patched" })

return M
