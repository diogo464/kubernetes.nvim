# kubernetes.nvim

kubernetes.nvim fetches resource definitions from your cluster and feeds them
to yamlls.

# Requirements

This plugin requires the `kubectl` binary and the `yamlls` language server
installed through `mason.nvim`. The `kubectl` binary must be able to contact
the a kubernetes cluster to fetch the resource definitions.

# Installation and Setup

To install the plugin any of the package managers should work.
To install using `lazy.nvim` just add the following line next to the other
plugins.
```lua
	{ 'diogo464/kubernetes.nvim' }
```
When the plugin is imported it will automatically generate and patch yamlls.
The only configuration required is in setting up yamlls. To do that just
insert the schema like in the example below.
```lua
      yamlls = {
        yaml = {
          schemas = {
            kubernetes = require('kubernetes').yamlls_filetypes(),
            [require('kubernetes').yamlls_schema()] = { "*.yaml", "*.yml" }
          }
        }
      }
```

# API

`kubernetes.setup({opts})`

Generates the schema file and patches yamlls.
At the moment this function takes no options.

`kubernetes.generate_schema()`

Generates the schema file, replacing any existing one, and restarts yamlls.

`kubernetes.yamlls_schema()`

Returns the path to the schema file that should be given to yamlls.

# How it works

In here I will just briefly describe how this plugin works and write down any
notes that might be useful when I come back to this later.

`yamlls` uses a set of schemas to provide autocompletion and hover support for all fields in a yaml file.
For kubernetes, an example schema can be found here:
```
https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.20.5-standalone-strict/all.json
```

That json file is basically just a bunch of references to each of the kubernetes resources that goes on for hundreds of lines. Here is a snippet of that file:
```json
{
  "oneOf": [
    {
      "$ref": "_definitions.json#/definitions/io.k8s.api.admissionregistration.v1.MutatingWebhook"
    },
    {
      "$ref": "_definitions.json#/definitions/io.k8s.api.admissionregistration.v1.MutatingWebhookConfiguration"
    }
}
```
Each of those references points to objects in another file, in this case that is:
```
https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.20.5-standalone-strict/_definitions.json
```
That file contains all the actual resource definitions that are needed.

The problem is that it does not include any of the CRDs that you might have in your
cluster and at the time of writing I couldn't find any easy way to add support for
them.

So to add support here are the steps:

1. Fetch the all the resource definitions from the cluster.\ 
This can be achieved like so: `kubectl get --raw /openapi/v2 | jq '.definitions'`.

2. Generate a `definitions.json` and `schema.json`.\ 
The `schema.json` is that `all.json` file that has the `oneOf`.
To do this just get all iterate the `definitions.json` and add the appropriate entry into `schema.json`. To reference a local file use `file://<full path>#/definitions/...`.

3. Patch the yaml language server.

And thats it, now it works.
