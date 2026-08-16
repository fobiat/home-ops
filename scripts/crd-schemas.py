#!/usr/bin/env python3
"""Turn a chart's CRDs into kubeconform schemas.

The datreeio CRD catalog that scripts/kubeconform.sh falls back to lags upstream,
and its schemas are `additionalProperties: false`, so a field newer than the
catalog is reported as invalid rather than unknown. Schemas generated here come
from the chart version this repo actually pins, so they cannot disagree with the
cluster.

Descriptions are stripped: they are most of the bytes and none of the validation.

Reads one JSON CustomResourceDefinition per line, which is what `yq -o=json -I0`
emits. See the `schemas` task in .taskfiles/lint.yaml for the whole pipeline.
"""

import json
import pathlib
import sys


def convert(node):
    """Strip descriptions and close every object the API server would prune.

    A CRD's openAPIV3Schema does not say `additionalProperties: false`; the API
    server prunes unknown fields from a structural schema instead. Without this,
    a misspelled field validates happily and is then silently dropped on apply,
    which is the failure this whole gate exists to catch.
    """
    if isinstance(node, list):
        return [convert(v) for v in node]
    if not isinstance(node, dict):
        return node

    out = {k: convert(v) for k, v in node.items() if k != "description"}

    closed = (
        "properties" in out
        and "additionalProperties" not in out
        and not out.get("x-kubernetes-preserve-unknown-fields")
    )
    if closed:
        out["additionalProperties"] = False
    return out


def main() -> int:
    out_root = pathlib.Path(sys.argv[1])
    written = 0

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        doc = json.loads(line)

        group = doc["spec"]["group"]
        kind = doc["spec"]["names"]["kind"].lower()

        for version in doc["spec"]["versions"]:
            schema = version.get("schema", {}).get("openAPIV3Schema")
            if not schema:
                continue

            schema = convert(schema)
            schema["$schema"] = "http://json-schema.org/draft-07/schema#"

            out_dir = out_root / group
            out_dir.mkdir(parents=True, exist_ok=True)
            out = out_dir / f"{kind}_{version['name']}.json"
            out.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
            print(f"wrote {out}")
            written += 1

    if written == 0:
        print("no CustomResourceDefinition on stdin", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
