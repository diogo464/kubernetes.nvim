import sys
import json

definitions = json.loads(open(sys.argv[1]).read())
print(json.dumps({"definitions": definitions}, indent=2))

