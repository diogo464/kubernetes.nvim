local log = require("kubernetes.log")

local PATH_DATA = vim.fn.stdpath("data") .. "/kubernetes.nvim/"
local PATH_DEFINITIONS = PATH_DATA .. "definitions.json"
local PATH_SCHEMA = PATH_DATA .. "schema.json"
-- matches both the old (`isKubernetes`) and the current
-- (`suppressKubernetesMatchesMultiple`) guard variables used by yamlls
local YAMLLS_PATCH_PATTERN = "([%w_]+) && err%.message === this%.MATCHES_MULTIPLE"
local YAMLLS_PATH_REPLACEMENT = "err.message === this.MATCHES_MULTIPLE"

---@class Options
---@field schema_strict boolean
---@field schema_generate_always boolean
---@field patch boolean If false, don't try to patch yaml-language-server.
---@field yamlls_root function():string

---@type Options
local DEFAULT_OPTIONS = {
	schema_strict = true,
	schema_generate_always = true,
        patch = true,
	yamlls_root = function()
                return vim.fs.joinpath(vim.fn.stdpath("data"), "mason/packages/yaml-language-server")
        end
}

---@param tbl table
---@return Options
local function options_from_table(tbl)
	assert(tbl == nil or type(tbl) == "table", "options value should be nil or a table")
	local opts = vim.deepcopy(DEFAULT_OPTIONS, true)
	local function merge(lhs, rhs)
		assert(type(lhs) == "table")
		if rhs == nil then return lhs end
		for key, value in pairs(rhs) do
			if type(value) == "table" and type(lhs[key]) == "table" then
				merge(lhs[key], value)
			else
				lhs[key] = value
			end
		end
	end
	merge(opts, tbl)
	return opts
end

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

---@param opts Options
---@return string path yamlls validation js path
local function yamlls_validation_js_path(opts)
	local root = opts.yamlls_root()
	local paths = {
		-- yamlls < 2.0.0
		vim.fs.joinpath(root, "node_modules/yaml-language-server/out/server/src/languageservice/services/yamlValidation.js"),
		-- yamlls >= 2.0.0
		vim.fs.joinpath(root, "node_modules/yaml-language-server/out/src/languageservice/services/yamlValidation.js"),
	}
	for _, path in ipairs(paths) do
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end
	-- report the missing legacy path so a broken yamlls install errors like before
	return paths[1]
end

--- fetches the current cluster's schema using kubectl
---@param on_success function(table) definitions the definitions section of the schema
local function kubectl_fetch_definitions(on_success)
	log.debug("fetching cluster definitions")
	cmd_async({ "kubectl", "get", "--raw", "/openapi/v2" }, function(output)
		local schema = vim.json.decode(table.concat(output, ""))
		if schema == nil then error("failed to decode schema from json") end
		log.debug("cluster definitions fetched")
		on_success({ definitions = schema["definitions"] })
	end)
end

--- returns a list of kinds
---@return table
local function kubectl_kinds()
	return cmd_blocking({ "kubectl", "api-resources", "--no-headers" })
end

--- adds `value` to the `enum` of a property, if it isn't already there
---@param property table
---@param value string
local function add_enum_value(property, value)
	property.enum = property.enum or {}
	for _, v in ipairs(property.enum) do
		if v == value then
			return
		end
	end
	property.enum[#property.enum + 1] = value
end

--- patches the definitions to include `kind` and `apiVersion` enums on
--- top-level resources. these enums are derived from the
--- `x-kubernetes-group-version-kind` extension, which is only present on
--- resource definitions. nested types that also have a `kind` property (for
--- example `ObjectReference`) are left untouched.
--- the `apiVersion` enum also lets yamlls tell apart definitions of the same
--- kind served under different group versions, like autoscaling/v1 and
--- autoscaling/v2 HorizontalPodAutoscaler.
---@param definitions table
local function patch_definitions_gvk(definitions)
	for _, resource in pairs(definitions.definitions) do
		local gvks = resource["x-kubernetes-group-version-kind"]
		local properties = resource.properties
		if gvks ~= nil and properties ~= nil then
			for _, gvk in ipairs(gvks) do
				-- "__internal" versions are not served by the api server
				if gvk.version ~= nil and gvk.version ~= "__internal" then
					if properties.kind ~= nil and gvk.kind ~= nil then
						add_enum_value(properties.kind, gvk.kind)
					end
					if properties.apiVersion ~= nil then
						local api_version = gvk.version
						if gvk.group ~= nil and gvk.group ~= "" then
							api_version = gvk.group .. "/" .. gvk.version
						end
						add_enum_value(properties.apiVersion, api_version)
					end
				end
			end
		end
	end
end

--- patches the definitions to set the `additionalProperties` field to false if it is not present
---@param definitions table
local function patch_definitions_strict(definitions)
	for _, resource in pairs(definitions.definitions) do
		if resource.additionalProperties == nil then
			resource.additionalProperties = false
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

--- patches definitions that kubernetes accepts as either a number or a string
--- but that the openapi schema describes as plain strings. without this,
--- yamlls rejects valid values like `targetPort: 9376` and `cpu: 1`.
---@param definitions table
local function patch_definitions_number_or_string(definitions)
	for _, resource in pairs(definitions.definitions) do
		-- ex: io.k8s.apimachinery.pkg.util.intstr.IntOrString
		if resource.format == "int-or-string" then
			resource.type = { "string", "integer" }
			resource.format = nil
		end
	end
	-- quantities accept numbers as well, ex: requests.cpu: 1
	local quantity = definitions.definitions["io.k8s.apimachinery.pkg.api.resource.Quantity"]
	if quantity ~= nil and quantity.type == "string" then
		quantity.type = { "string", "number" }
	end
end

local function schema_exists()
	return vim.fn.filereadable(PATH_SCHEMA) and vim.fn.filereadable(PATH_DEFINITIONS)
end

---@param opts Options
---@param on_generate? function()
local function schema_generate(opts, on_generate)
	log.debug("starting schema generation")
	kubectl_fetch_definitions(function(definitions)
		patch_definitions_gvk(definitions)
		patch_definitions_number_or_string(definitions)
		if opts.schema_strict then
			patch_definitions_strict(definitions)
		end
		local schema = generate_oneof_schema(definitions)
		log.debug("writing schema files to disk")
		vim.fn.mkdir(PATH_DATA, "p")
		vim.fn.writefile({ vim.json.encode(schema) }, PATH_SCHEMA)
		vim.fn.writefile({ vim.json.encode(definitions) }, PATH_DEFINITIONS)
		if on_generate ~= nil then
			on_generate()
		end
	end)
end

---@param opts Options
local function yamlls_is_patched(opts)
	local yamlls_validation_js = yamlls_validation_js_path(opts)
	local lines = vim.fn.readfile(yamlls_validation_js)
	for _, line in ipairs(lines) do
		if string.match(line, YAMLLS_PATCH_PATTERN) then
			return false
		end
	end
	return true
end

---@param opts Options
local function yamlls_patch(opts)
	local yamlls_validation_js = yamlls_validation_js_path(opts)
	log.debug("patching yamlls file at ", yamlls_validation_js)
	local lines = vim.fn.readfile(yamlls_validation_js)
	for index, line in ipairs(lines) do
		if string.match(line, YAMLLS_PATCH_PATTERN) then
			lines[index] = string.gsub(line, YAMLLS_PATCH_PATTERN, YAMLLS_PATH_REPLACEMENT)
		end
	end
	vim.fn.writefile(lines, yamlls_validation_js)
end

local function yamlls_restart()
	log.debug("restarting yamlls")
	vim.fn.execute("LspRestart yamlls")
end

local M = {}

--- plugin setup, called by the package manager
---@param o table
function M.setup(o)
	M.opts = options_from_table(o)
	log.debug("setup with options = ", M.opts)

	if M.opts.schema_generate_always or not schema_exists() then
		schema_generate(M.opts, function()
			if M.opts.patch and not yamlls_is_patched(M.opts) then
				yamlls_patch(M.opts)
				yamlls_restart()
			end
		end)
	else
		log.debug("skipping schema generation, files already exist")
	end
end

function M.generate_schema()
	schema_generate(M.opts)
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
	return yamlls_patch(M.opts)
end

function M.yamlls_is_patched()
	return yamlls_is_patched(M.opts)
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
