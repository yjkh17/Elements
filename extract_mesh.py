import re
import json

html_path = '14-cloth.html'
with open(html_path, 'r') as f:
    content = f.read()

# Extract vertices
v_match = re.search(r'vertices\s*:\s*\[([\s\S]*?)\]', content)
if v_match:
    v_str = v_match.group(1)
    vertices = [float(x) for x in v_str.replace(',', ' ').split()]
    print(f"Extracted {len(vertices)//3} vertices")

# Extract indices
i_match = re.search(r'faceTriIds\s*:\s*\[([\s\S]*?)\]', content)
if i_match:
    i_str = i_match.group(1)
    indices = [int(x) for x in i_str.replace(',', ' ').split()]
    print(f"Extracted {len(indices)//3} triangles")

data = {
    "vertices": vertices,
    "indices": indices
}

with open('Elements/ClothData.json', 'w') as f:
    json.dump(data, f)
    
print("Saved to Elements/ClothData.json")
