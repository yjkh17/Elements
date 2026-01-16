import json

with open('Elements/ClothData.json', 'r') as f:
    data = json.load(f)

verts = data['vertices']
inds = data['indices']

with open('Elements/ClothReferenceData.swift', 'w') as f:
    f.write("import Foundation\n\n")
    f.write("struct ClothReferenceData {\n")
    
    f.write("    static let vertices: [Float] = [\n")
    for i in range(0, len(verts), 12): # Chunk for readability
        chunk = verts[i:i+12]
        line = ", ".join(f"{x:.6f}" for x in chunk)
        f.write(f"        {line},\n")
    f.write("    ]\n\n")
    
    f.write("    static let indices: [UInt32] = [\n")
    for i in range(0, len(inds), 12):
        chunk = inds[i:i+12]
        line = ", ".join(str(x) for x in chunk)
        f.write(f"        {line},\n")
    f.write("    ]\n")
    f.write("}\n")
    
print("Generated Elements/ClothReferenceData.swift")
