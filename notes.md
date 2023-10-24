the kubernetes schema used by yamlls is just one big json file.
that file has the following format:
```json
{
  "oneOf": [
    {
      "$ref": "_definitions.json#/definitions/io.k8s.api.admissionregistration.v1.MutatingWebhook"
    },
    {
      "$ref": "_definitions.json#/definitions/io.k8s.api.admissionregistration.v1.MutatingWebhookConfiguration"
    },
    {
      "$ref": "_definitions.json#/definitions/io.k8s.api.admissionregistration.v1.MutatingWebhookConfigurationList"
    },
    ... (and so one for hundreds of lines)
}
```
This file should be generated by our plugin.
The original file can be found here `https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.20.5-standalone-strict/all.json`.
The values for the keys `$ref` should point to another file that contains the definitions.
Instead of the `_definitions.json` we would use `file://<full path to our definitions.json>`.
We also have to generate this definitions.json file.

To get the definitions from our cluster we start by fetching it wit
We can fetch the definitions from our cluster using something like:
```sh
$ kubectl proxy random
# if the proxy started on 8001 then
$ curl localhost:8001/openapi/v2 | jq '.definitions' | bat --language json
```
Now we might still need to patch this definitions file
```json
"$ref": "#/definitions/io.k8s.apimachinery.pkg.apis.meta.v1.ListMeta"
```
That is an example of one of the refs in that file but since all referencences
are to the file itself I don't think we need to patch it.
But I did notice that on 
```
https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master/v1.20.5-standalone-strict/_definitions.json
```
They seem to have an `enum` in all the `kind` items of each definition.
...
Okay, after trying to use the schema without putting the enum's I go the following
error from yamlls `■ Matches multiple schemas when only one must validate.`.
So now I will try to use the enum.
Also, using the above curl + jq to get the definitions we still need to put that
output as the value of a definitions key like so:
```json
{
    "definitions": <output here>
}
```
...
That error seems to be showing up even after adding the enum field.
Not sure what it is right now.
...
Just found out the proxy is not needed.
`https://github.com/redhat-developer/yaml-language-server/issues/132#issuecomment-1403851309`
and instead you can just use `kubectl get --raw /openapi/v2`
From that issue it seems like this repo is already doing what we
want `https://github.com/instrumenta/openapi2jsonschema/blob/master/openapi2jsonschema/command.py`
...
ok, it seems like that error is actually just ignored when file schema
is kubernetes
```
https://github.com/redhat-developer/yaml-language-server/blob/ed03cbf71ade29ea62b4bcac0d8952195fd6969d/src/languageservice/services/yamlValidation.ts#L122
```
And to be a kubernetes file you need it to be at the url like below.
```
https://github.com/redhat-developer/yaml-language-server/blob/main/src/languageservice/utils/schemaUrls.ts#L8
```

And with that I think the only option we have left is to use the
http proxy configuration of yamlls ls and intercept any requests to that
file and replace it with our own. probably easier said than done.
....
It seems like an HTTP proxy is not able to intercept traffic as it proxies
the actual byte stream and not individual requests and because of https
there is not much we can do.

...
Okay just tried a new idea that worked.
Mason downloads the language server to 
~/.local/share/nvim/mason/packages/yaml-language-server
and if we just remove the `isKubernetes &&` from the file
~/.local/share/nvim/mason/packages/yaml-language-server/node_modules/yaml-language-server/out/server/src/languageservice/services/yamlValidation.js
then this all works out fine.