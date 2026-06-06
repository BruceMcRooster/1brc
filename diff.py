#!/usr/bin/python3

from pathlib import Path
import re
import subprocess
import sys

output_dir = Path("./test-run/")
output_dir.mkdir(parents=True, exist_ok=True)

def replace_commas(file_path: Path):
    with open(file_path, 'r') as f:
        content = f.read()

    updated_content = re.sub(r',\s', '\n', content)

    with open(file_path, 'w') as f:
        f.write(updated_content)

ref_file = output_dir / "ref.txt"
actual_file = output_dir / "actual.txt"

try:
    ref_file_index = sys.argv.index("--ref")
    ref_file_source = Path(sys.argv[ref_file_index + 1])
    ref_file.write_bytes(ref_file_source.read_bytes())
except ValueError: # flag doesn't exist
    with open(ref_file, 'w') as f:
        print("running refsol")
        subprocess.run(["java", "./src/main/java/dev/morling/onebrc/CalculateAverage_baseline.java"], stdout=f)

try:
    actual_file_index = sys.argv.index("--actual")
    actual_file_source = Path(sys.argv[actual_file_index + 1])
    actual_file.write_bytes(actual_file_source.read_bytes())
except ValueError:
    with open(actual_file, 'w') as f:
        print("running implementation")
        subprocess.run(["zig-out/bin/_1brc"], stdout=f)

replace_commas(ref_file)

replace_commas(actual_file)

subprocess.run(["git", "diff", "--no-index", "--color-words=.", "--color=always", ref_file, actual_file])
