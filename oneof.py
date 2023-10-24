import json

definitions = json.loads(open("definitions.json").read())
keys = list(definitions.keys())

output = {"oneOf": [{"$ref": "file:///home/diogo464/dev/main/kubernetes.nvim/definitions.json#/definitions/" + key} for key in keys]}
print(json.dumps(output, indent=2))


"""
apps/planka/cluster.yaml|1 col 1-2 error| $ref '/definitions/us.containo.traefik.v1alpha1.TraefikServiceList' in 'file:///home/diogo464/dev/main/kubernetes.nvim/definitions.json' can not be resolved.
"""
