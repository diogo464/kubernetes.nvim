import json

definitions = json.loads(open("definitions.json").read())
for resource, definition in definitions["definitions"].items():
    if "properties" not in definition:
        continue
    for key, val in definition["properties"].items():
        if key == "kind":
            if "enum" in val:
                break
            name = resource.split(".")[-1]
            val["enum"] = [name]
            break
print(json.dumps(definitions, indent=2))
