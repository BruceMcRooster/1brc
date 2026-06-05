#!/usr/bin/python3

from pathlib import Path
import re
import subprocess
import sys

output_dir = Path("./test-run/")
output_dir.mkdir(parents=True, exist_ok=True)

ref_file = output_dir / "ref.txt"
actual_file = output_dir / "actual.txt"

def replace_commas(file_path: Path):
    with open(file_path, 'r') as f:
        content = f.read()

    updated_content = re.sub(r',\s', '\n', content)

    with open(file_path, 'w') as f:
        f.write(updated_content)

with open(ref_file, 'w') as f:
    subprocess.run(["java", "./src/main/java/dev/morling/onebrc/CreateMeasurementsFast.java"], stdout=f)

replace_commas(ref_file)

with open(actual_file, 'w') as f:
    subprocess.run(["zig-out/bin/_1brc"], stdout=f)

replace_commas(actual_file)

subprocess.run(["git", "diff", "--no-index", "--color-words=.", "--color=always", ref_file, actual_file])
